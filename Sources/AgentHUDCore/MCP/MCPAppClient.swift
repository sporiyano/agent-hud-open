#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// The `--mcp` process's side of the channel to the running application: one connection per tool call, which sends
/// the request, closes its writing side so the application sees it whole, and reads the reply until the application
/// closes. It never starts the application: with none running the call says so and the agent tells its user.
enum MCPAppClient {
    enum Answer: Equatable, Sendable {
        case reply(MCPToolReply)
        /// No socket in the data directory, or nothing accepts on it.
        case notRunning
        /// The application runs and serves no socket: its agent tools are switched off in Settings → Experimental.
        case off
        /// The application took the call and gave no reply that can be read in time.
        case unanswered
    }

    /// How long a call may take from connecting to the end of the reply.
    static let timeout: TimeInterval = 10
    /// The largest reply read; a longer one counts as none. A picture of the panel travels in the reply, and a PNG of
    /// 1,080 by 2,400 pixels does not reach it even stored uncompressed and written in base64, about 14 MB.
    static let replyLimit = 16 * 1024 * 1024

    /// `call(_:socket:timeout:)` with a socket nobody serves told apart: `off` when a copy of the application runs that
    /// keeps its data in the directory named `dataDirectoryName`, as the instance lock at `lock` says without being
    /// taken, and `notRunning` when none does. A copy of another application built on these libraries, which keeps its
    /// data elsewhere, does not count.
    static func call(_ request: MCPToolRequest, socket path: String, lock: URL, dataDirectoryName: String,
                     timeout: TimeInterval = timeout) -> Answer {
        let answer = call(request, socket: path, timeout: timeout)
        guard answer == .notRunning, applicationRuns(lock: lock, dataDirectoryName: dataDirectoryName) else { return answer }
        return .off
    }

    /// Whether the application holding the lock at `lock` keeps its data in the directory named `dataDirectoryName`.
    static func applicationRuns(lock: URL, dataDirectoryName: String) -> Bool {
        guard let holder = InstanceLock.runningApplication(at: lock) else { return false }
        let bundle = holder.pathExtension == "app" ? Bundle(url: holder) : nil
        return AppSupport.directoryName(of: bundle) == dataDirectoryName
    }

    static func call(_ request: MCPToolRequest, socket path: String, timeout: TimeInterval = timeout) -> Answer {
        #if !canImport(Darwin)
        return .notRunning
        #else
        guard let descriptor = UnixSocket.connect(to: path) else { return .notRunning }
        defer { close(descriptor) }
        let message = request.message
        // The application lets go of a longer request without a word, which would read as its not answering.
        guard message.count <= MCPToolRequest.sizeLimit else {
            return .reply(.failure("The call is larger than Agent HUD reads. Send less in one call."))
        }
        let deadline = Date().addingTimeInterval(timeout)
        // An application that stopped reading must not hold the process in the middle of a request. A wait of zero
        // would mean no limit to the socket.
        let wait = max(timeout, 0.001)
        var patience = timeval(tv_sec: Int(wait), tv_usec: Int32((wait - wait.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        guard UnixSocket.send(descriptor, message) else { return .unanswered }
        shutdown(descriptor, SHUT_WR)
        guard let data = read(descriptor, until: deadline), let reply = MCPToolReply.read(data) else { return .unanswered }
        return .reply(reply)
        #endif
    }

    #if canImport(Darwin)

    /// Everything the other side wrote before it closed; nil when it has not closed by `deadline` or wrote more than
    /// `replyLimit`.
    private static func read(_ descriptor: Int32, until deadline: Date) -> Data? {
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return reply }
            reply.append(contentsOf: buffer[..<count])
            guard reply.count <= replyLimit else { return nil }
        }
    }
    #endif
}
