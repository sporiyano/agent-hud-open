import Foundation
#if canImport(Network)
import Network
import os.log
#endif

/// One request's connection to the process that sent it, which waits on it for an answer.
@MainActor
public final class LocalConnection {
    #if canImport(Network)
    private let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    /// Whether the sender went away or the connection was let go.
    public var isClosed: Bool {
        switch connection.state {
        case .cancelled, .failed: true
        default: false
        }
    }

    /// Called once the sender goes away or the connection is let go; replaces any handler set before.
    public func onClose(_ handler: @escaping @MainActor () -> Void) {
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed: handler()
                default: break
                }
            }
        }
    }

    /// Writes the answer, then lets the connection go.
    public func reply(_ data: Data) {
        let connection = connection
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Lets the connection go without an answer.
    public func cancel() { connection.cancel() }
    #else
    public var isClosed: Bool { true }

    public func onClose(_ handler: @escaping @MainActor () -> Void) {}

    public func reply(_ data: Data) {}

    public func cancel() {}
    #endif
}

/// The application's side of a `UnixSocket`: it listens at `path` and hands each request, once its sender stopped
/// writing, to `onRequest` with the connection, which answers it or lets it go. One process serves a path: a lock beside
/// the socket keeps a second copy of the application from replacing it, and a process removes only the socket it made.
#if canImport(Network)
@MainActor
public final class UnixSocketListener {
    public let path: String
    /// The largest request read; a longer one closes its connection.
    public let requestLimit: Int
    private let onRequest: @MainActor (Data, LocalConnection) -> Void
    private let log: Logger
    private var listener: NWListener?
    /// The lock that makes this process the one serving the path, and the socket file it made, by device and inode.
    private var lock: Int32 = -1
    private var socket: [Int]?
    /// This listener's hold on the file mode mask, from its start until its socket is made or will not be.
    private var mask: SocketMask?

    /// - category: names the socket in the application's log.
    public init(path: String, requestLimit: Int, category: String, onRequest: @escaping @MainActor (Data, LocalConnection) -> Void) {
        self.path = path
        self.requestLimit = requestLimit
        self.onRequest = onRequest
        log = Logger(subsystem: "app.agenthud", category: category)
    }

    public var isListening: Bool { listener != nil }

    /// Starts listening; false when the path does not fit a socket address, another process serves it or the socket
    /// cannot be made.
    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        let path = path
        guard UnixSocket.fits(path) else {
            log.error("Socket path is too long for a unix socket: \(path, privacy: .public)")
            return false
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Another copy of the app opened beside this one, which shares its data directory, leaves the socket to the one
        // that serves it rather than replacing it; the lock goes with the process that holds it.
        let lock = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            log.info("Another instance serves \(path, privacy: .public)")
            return false
        }
        unlink(path)
        // The socket must never be readable by anyone else, not even for the moment between bind and chmod.
        let mask = SocketMask()
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else {
            mask.release()
            close(lock)
            log.error("Could not listen on \(path, privacy: .public)")
            return false
        }
        self.lock = lock
        self.listener = listener
        self.mask = mask
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    mask.release()
                    chmod(path, 0o700)
                    self?.socket = Self.identity(path)
                case .failed, .cancelled:
                    mask.release()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                self?.receive(connection, accumulated: Data())
            }
        }
        listener.start(queue: .main)
        return true
    }

    /// Stops listening. Only the socket this process made is removed.
    public func stop() {
        listener?.cancel()
        listener = nil
        mask?.release()
        mask = nil
        if let socket, Self.identity(path) == socket { unlink(path) }
        socket = nil
        if lock >= 0 { close(lock) }
        lock = -1
    }

    private static func identity(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino)]
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                var data = accumulated
                if let content { data.append(content) }
                guard let self, data.count <= self.requestLimit else { return connection.cancel() }
                if isComplete || error != nil {
                    self.onRequest(data, LocalConnection(connection))
                } else {
                    self.receive(connection, accumulated: data)
                }
            }
        }
    }
}

/// One listener's hold on the process's file mode mask, kept tight while its socket is made. A process has one mask,
/// so the listeners that are coming up share it: the first tightens it, and it returns to what that one found when
/// the last of them lets go. Each putting back what it found itself would leave the mask tight for good once two
/// start in the same turn, and with it every file the application and its child processes write afterwards.
@MainActor
private final class SocketMask {
    private static var holds = 0
    private static var found: mode_t = 0
    private var held = true

    init() {
        if Self.holds == 0 { Self.found = umask(0o077) }
        Self.holds += 1
    }

    /// Lets go of the mask; letting go twice is letting go once.
    func release() {
        guard held else { return }
        held = false
        Self.holds -= 1
        if Self.holds == 0 { umask(Self.found) }
    }
}

#else
/// Off macOS nothing listens yet: `start()` reports that the channel could not be opened.
@MainActor
public final class UnixSocketListener {
    public let path: String
    public let requestLimit: Int

    public init(path: String, requestLimit: Int, category: String, onRequest: @escaping @MainActor (Data, LocalConnection) -> Void) {
        self.path = path
        self.requestLimit = requestLimit
    }

    public var isListening: Bool { false }

    @discardableResult
    public func start() -> Bool { false }

    public func stop() {}
}
#endif
