import Foundation
#if os(Windows)
import WinSDK
#endif

/// The lock that lets only one Agent HUD run at a time.
///
/// The copy that runs points every client hook at itself and serves the sockets those hooks reach, so a second copy
/// would take them from under the first. Every application built on these libraries claims the same file, whatever
/// its data directory or bundle identifier, and holds it for as long as it keeps the lock: the system lets go of it
/// when the process ends, also when it crashes, so a copy that is gone never keeps another from starting. Hook
/// commands, probes and snapshots take no lock.
public final class InstanceLock: Sendable {
    public enum Claim: Sendable {
        /// This process holds the lock for as long as it keeps the value.
        case acquired(InstanceLock)
        /// Another process holds it: the application it runs, its bundle when it runs in one, if the lock names it.
        case held(by: URL?)
        /// No lock could be taken here; the application runs without one rather than not at all.
        case unavailable
    }

    /// `~/Library/Caches/app.agenthud/instance.lock`: outside every application's own data directory, so they all
    /// meet there.
    public static var sharedURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("app.agenthud", isDirectory: true).appendingPathComponent("instance.lock")
    }

    #if os(Windows)
    /// The lock file's handle, as its bits: closing it lets go of the lock.
    private let handle: Int

    private init(handle: HANDLE) { self.handle = Int(bitPattern: handle) }

    deinit { CloseHandle(HANDLE(bitPattern: handle)) }

    /// The one byte that is locked, past anything the file holds, so the name written in it can be read meanwhile.
    private static func lockedRange() -> OVERLAPPED {
        var range = OVERLAPPED()
        range.OffsetHigh = 1
        return range
    }
    #else
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        #if canImport(Darwin)
        close(descriptor)
        #endif
    }
    #endif

    /// Takes the lock at `url` and writes `executable` into it, so that a launch it turns away can say which copy runs.
    public static func claim(at url: URL = sharedURL, executable: URL? = Bundle.main.executableURL) -> Claim {
        #if os(Windows)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, error.localizedDescription)
            return .unavailable
        }
        // Not inherited: a client's engine this app starts must not hold the lock after the app is gone.
        let opened = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil,
                        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else {
            NSLog("[AgentHUD] No instance lock at %@: error %u", url.path, GetLastError())
            return .unavailable
        }
        var range = lockedRange()
        guard Bool(LockFileEx(opened, DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &range)) else {
            let failure = GetLastError()
            CloseHandle(opened)
            if failure == DWORD(ERROR_LOCK_VIOLATION) || failure == DWORD(ERROR_IO_PENDING) { return .held(by: holder(at: url)) }
            NSLog("[AgentHUD] No instance lock at %@: error %u", url.path, failure)
            return .unavailable
        }
        let path = Array((executable?.path ?? "").utf8)
        var written: DWORD = 0
        let named = Bool(SetEndOfFile(opened)) && Bool(WriteFile(opened, path, DWORD(path.count), &written, nil))
            && Int(written) == path.count
        if !named { NSLog("[AgentHUD] Could not name this copy in the instance lock: error %u", GetLastError()) }
        return .acquired(InstanceLock(handle: opened))
        #elseif !canImport(Darwin)
        return .unavailable
        #else
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, error.localizedDescription)
            return .unavailable
        }
        // Closed on exec: a client's engine this app starts must not inherit the lock and hold it after the app is gone.
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, String(cString: strerror(errno)))
            return .unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK { return .held(by: holder(at: url)) }
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, String(cString: strerror(failure)))
            return .unavailable
        }
        let path = Array((executable?.path ?? "").utf8)
        let written = ftruncate(descriptor, 0) == 0
            && path.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } == path.count
        if !written { NSLog("[AgentHUD] Could not name this copy in the instance lock: %@", String(cString: strerror(errno))) }
        return .acquired(InstanceLock(descriptor: descriptor))
        #endif
    }

    /// The application that holds the lock at `url` now, named as a refused claim names it; nil when no copy holds it
    /// or the holder has not written its name yet. It only asks: the lock is never taken, not even for a moment, so a
    /// copy that starts meanwhile is not turned away. A process that must not start the application, such as `--mcp`,
    /// learns from it whether one runs.
    static func runningApplication(at url: URL = sharedURL) -> URL? {
        #if os(Windows)
        // Windows reports a lock only to a request for it, so this asks for a shared one, and lets go at once.
        let opened = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(opened) }
        var range = lockedRange()
        if Bool(LockFileEx(opened, DWORD(LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &range)) {
            var unlocking = lockedRange()
            UnlockFileEx(opened, 0, 1, 0, &unlocking)
            return nil
        }
        return holder(at: url)
        #elseif !canImport(Darwin)
        return nil
        #else
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // flock(2) and fcntl(2) keep one table of locks on macOS, so F_GETLK sees the holder's whole-file lock, from
        // another process or this one, and reports it without taking any.
        var probe = flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &probe) == 0, probe.l_type != Int16(F_UNLCK) else { return nil }
        return holder(at: url)
        #endif
    }

    /// The application whose executable the holder wrote: `…/Name.app` for one that runs in a bundle. Nil while the
    /// holder has not written it yet.
    static func holder(at url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(Windows)
        // `C:\…`, `C:/…` or Foundation's `/C:/…`.
        let drive = Array((path.hasPrefix("/") ? path.dropFirst() : Substring(path)).utf8)
        guard drive.count > 2, drive[1] == UInt8(ascii: ":") else { return nil }
        #else
        guard path.hasPrefix("/") else { return nil }
        #endif
        let executable = URL(fileURLWithPath: path)
        let folder = executable.deletingLastPathComponent()
        let bundle = folder.deletingLastPathComponent().deletingLastPathComponent()
        let inBundle = folder.lastPathComponent == "MacOS" && folder.deletingLastPathComponent().lastPathComponent == "Contents"
            && bundle.pathExtension == "app"
        return inBundle ? bundle : executable
    }
}
