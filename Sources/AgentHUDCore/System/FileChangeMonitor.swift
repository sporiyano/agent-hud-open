import Foundation

#if canImport(CoreServices)
import CoreServices
import os

/// Tells what changed under a set of directories since the previous check, using FSEvents.
/// Directories created later are watched after the next `update()`.
final class FileChangeMonitor {
    /// Shared with the FSEvents callback, which can run while the monitor is being released.
    private final class Changes: Sendable {
        struct State {
            var changed = true
            /// Files reported since the last check; nil when events were dropped or not yet seen, so everything must be scanned.
            var paths: Set<String>? = nil
        }
        static let pathLimit = 10_000
        let state = OSAllocatedUnfairLock(initialState: State())
        /// Called on the monitor's queue after every batch of events, so a waiting reader can wake at once.
        let onChange: (@Sendable () -> Void)?
        init(onChange: (@Sendable () -> Void)?) { self.onChange = onChange }
    }

    private let directories: [String]
    private let changes: Changes
    private let queue = DispatchQueue(label: "app.agenthud.file-changes", qos: .utility)
    private var stream: FSEventStreamRef?
    private var watched: [String]?

    /// - onChange: called after each batch of file events, on the monitor's queue.
    init(directories: [URL], onChange: (@Sendable () -> Void)? = nil) {
        // FSEvents streams are recursive, so a directory inside another one adds nothing.
        let paths = Set(directories.map { $0.standardizedFileURL.path })
        self.directories = paths.filter { path in !paths.contains { $0 != path && path.hasPrefix($0 + "/") } }.sorted()
        changes = Changes(onChange: onChange)
        update()
    }

    /// False when no watched directory exists or the stream could not be created, so sources must be read on a schedule.
    var isWatching: Bool { watched.map { !$0.isEmpty } ?? false }

    deinit { stopStream() }

    /// Watches the directories that exist now; a change in the watched set counts as a change of everything.
    func update() {
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != watched else { return }
        stopStream()
        watched = existing
        changes.state.withLock { $0 = .init() }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(changes).toOpaque(), retain: { info in
            guard let info else { return nil }
            _ = Unmanaged<Changes>.fromOpaque(info).retain()
            return info
        }, release: { info in
            guard let info else { return }
            Unmanaged<Changes>.fromOpaque(info).release()
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                                 | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let dropped = (0..<count).contains { flags[$0] & rescan != 0 } || paths.count != count
            let changes = Unmanaged<Changes>.fromOpaque(info).takeUnretainedValue()
            changes.state.withLock { state in
                state.changed = true
                guard !dropped, var known = state.paths else { state.paths = nil; return }
                known.formUnion(paths)
                state.paths = known.count > Changes.pathLimit ? nil : known
            }
            changes.onChange?()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, existing as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags) else {
            watched = nil
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            watched = nil
            return
        }
        stream = created
    }

    /// Whether anything changed since the previous call. Without a working stream every call reports a change.
    func consumeChanges() -> Bool {
        let changed = changes.state.withLock { state in
            let changed = state.changed
            state.changed = false
            state.paths = []
            return changed
        }
        return changed || !isWatching
    }

    /// Files reported since the previous call, or nil when a full scan is needed: the first call, dropped events,
    /// a newly watched directory, or no working stream.
    func consumePaths() -> Set<String>? {
        let paths = changes.state.withLock { state in
            let paths = state.paths
            state.changed = false
            state.paths = []
            return paths
        }
        return isWatching ? paths : nil
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

#elseif os(Windows)
import WinSDK

/// Tells what changed under a set of directories since the previous check, using `ReadDirectoryChangesW`: one thread
/// per watched directory blocks in the call and records the files it names. Directories created later are watched
/// after the next `update()`.
final class FileChangeMonitor {
    private final class Changes: @unchecked Sendable {
        static let pathLimit = 10_000
        private let lock = NSLock()
        private var changed = true
        /// Files reported since the last check; nil when events were lost or not yet seen, so everything must be scanned.
        private var paths: Set<String>? = nil
        let onChange: (@Sendable () -> Void)?
        init(onChange: (@Sendable () -> Void)?) { self.onChange = onChange }

        func reset() { lock.withLock { changed = true; paths = nil } }

        func record(_ reported: [String]?) {
            lock.withLock {
                changed = true
                guard let reported, var known = paths else { paths = nil; return }
                known.formUnion(reported)
                paths = known.count > Self.pathLimit ? nil : known
            }
            onChange?()
        }

        func take() -> (changed: Bool, paths: Set<String>?) {
            lock.withLock {
                defer { changed = false; paths = [] }
                return (changed, paths)
            }
        }
    }

    /// One directory's handle and the thread reading it. Stopping cancels the pending read; the thread closes the handle.
    private final class Watch: @unchecked Sendable {
        private let handle: HANDLE
        private let lock = NSLock()
        private var stopped = false

        init?(directory: String, changes: Changes) {
            let opened = directory.withCString(encodedAs: UTF16.self) { name in
                CreateFileW(name, DWORD(FILE_LIST_DIRECTORY), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                            nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
            }
            guard let opened, opened != INVALID_HANDLE_VALUE else { return nil }
            handle = opened
            Thread.detachNewThread { [self] in read(directory: directory, changes: changes) }
        }

        func stop() {
            lock.withLock { stopped = true }
            CancelIoEx(handle, nil)
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        private func read(directory: String, changes: Changes) {
            let size = 64 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer {
                buffer.deallocate()
                CloseHandle(handle)
            }
            let filter = DWORD(FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE
                               | FILE_NOTIFY_CHANGE_LAST_WRITE)
            while !isStopped {
                var returned: DWORD = 0
                let succeeded = Bool(ReadDirectoryChangesW(handle, buffer, DWORD(size), true, filter, &returned, nil, nil))
                if isStopped { return }
                guard succeeded else {
                    // The directory went away or the handle failed: everything is read again, and `update()` reopens it.
                    changes.record(nil)
                    return
                }
                // Zero bytes means the system's buffer overflowed and the names were lost.
                changes.record(returned == 0 ? nil : Self.paths(in: buffer, count: Int(returned), directory: directory))
            }
        }

        /// The full paths the `FILE_NOTIFY_INFORMATION` records in `buffer` name, written with forward slashes as
        /// Foundation writes paths.
        static func paths(in buffer: UnsafeMutableRawPointer, count: Int, directory: String) -> [String] {
            var result: [String] = [], offset = 0
            while offset + 12 <= count {
                let next = Int(buffer.load(fromByteOffset: offset, as: UInt32.self))
                let length = Int(buffer.load(fromByteOffset: offset + 8, as: UInt32.self))
                guard offset + 12 + length <= count else { break }
                let name = UnsafeBufferPointer(start: (buffer + offset + 12).assumingMemoryBound(to: UInt16.self),
                                               count: length / 2)
                let relative = String(decoding: name, as: UTF16.self).replacingOccurrences(of: "\\", with: "/")
                result.append(directory + "/" + relative)
                guard next > 0 else { break }
                offset += next
            }
            return result
        }
    }

    private let directories: [String]
    private let changes: Changes
    private var watches: [String: Watch] = [:]
    private var watched: [String]?

    /// - onChange: called after each batch of file events, on the directory's reading thread.
    init(directories: [URL], onChange: (@Sendable () -> Void)? = nil) {
        // Reads are recursive, so a directory inside another one adds nothing.
        let paths = Set(directories.map { $0.standardizedFileURL.path })
        self.directories = paths.filter { path in !paths.contains { $0 != path && path.hasPrefix($0 + "/") } }.sorted()
        changes = Changes(onChange: onChange)
        update()
    }

    /// False when no watched directory exists or none could be opened, so sources must be read on a schedule.
    var isWatching: Bool { !watches.isEmpty }

    deinit { watches.values.forEach { $0.stop() } }

    /// Watches the directories that exist now; a change in the watched set counts as a change of everything.
    func update() {
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != watched else { return }
        watches.values.forEach { $0.stop() }
        watches = [:]
        watched = existing
        changes.reset()
        for directory in existing {
            if let watch = Watch(directory: directory, changes: changes) { watches[directory] = watch }
        }
    }

    /// Whether anything changed since the previous call. Without a working watch every call reports a change.
    func consumeChanges() -> Bool {
        changes.take().changed || !isWatching
    }

    /// Files reported since the previous call, or nil when a full scan is needed.
    func consumePaths() -> Set<String>? {
        let paths = changes.take().paths
        return isWatching ? paths : nil
    }
}
#else
/// Without FSEvents nothing is watched yet: every check reports a change, so sources are read on their schedule.
final class FileChangeMonitor {
    init(directories: [URL], onChange: (@Sendable () -> Void)? = nil) {}

    var isWatching: Bool { false }

    func update() {}

    func consumeChanges() -> Bool { true }

    func consumePaths() -> Set<String>? { nil }
}
#endif
