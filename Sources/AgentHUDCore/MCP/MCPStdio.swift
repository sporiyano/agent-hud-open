#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// The `--mcp` command: the process an agent's client starts to reach Agent HUD's tools, and keeps for as long as it
/// wants them. It reads one JSON-RPC message per line from standard input and writes one per line to standard output,
/// which carries nothing else, and it ends when its input does. Messages are answered one at a time, in the order
/// they arrived.
///
/// Like a hook command it starts no interface, takes no instance lock and queries no account, and it never starts
/// the application: a tool call made while none runs comes back saying so, and one made while the application runs
/// with its agent tools switched off says that instead.
enum MCPStdio {
    static let argument = "--mcp"

    /// Whether a process started with `arguments`, its executable first, is this command: the switch alone.
    static func isRequested(by arguments: [String]) -> Bool {
        arguments.count == 2 && arguments[1] == argument
    }

    /// Serves standard input until it ends and returns the process's exit status.
    static func run() -> Int32 {
        #if canImport(Darwin)
        // A client that went away must end the process through a failed write, not a signal.
        signal(SIGPIPE, SIG_IGN)
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let socket = MCPAppChannel.socketPath()
        let directoryName = AppSupport.directoryName(of: .main)
        let server = MCPServer(version: version) {
            MCPAppClient.call($0, socket: socket, lock: InstanceLock.sharedURL, dataDirectoryName: directoryName)
        }
        #if canImport(Darwin)
        return run(server, input: STDIN_FILENO, output: STDOUT_FILENO)
        #else
        return run(server, input: .standardInput, output: .standardOutput)
        #endif
    }

    #if !canImport(Darwin)
    /// Answers the lines read from `input` on `output` until `input` ends, as the descriptor version does.
    static func run(_ server: MCPServer, input: FileHandle, output: FileHandle) -> Int32 {
        var lines = MCPLineBuffer()
        while true {
            let data = input.availableData
            if data.isEmpty { break }
            for line in lines.take(data) {
                guard write(server.lines(for: line), to: output) else { return 0 }
            }
        }
        if let last = lines.rest() { _ = write(server.lines(for: last), to: output) }
        return 0
    }

    private static func write(_ lines: [String], to output: FileHandle) -> Bool {
        for line in lines {
            do { try output.write(contentsOf: Data((line + "\n").utf8)) } catch { return false }
        }
        return true
    }
    #else

    /// Answers the lines read from `input` on `output` until `input` ends: 0 then, and also once nobody reads
    /// `output` any more; 1 when `input` cannot be read.
    static func run(_ server: MCPServer, input: Int32, output: Int32) -> Int32 {
        var lines = MCPLineBuffer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN, becomesReady(input, for: POLLIN) { continue }
                FileHandle.standardError.write(Data("agent-hud mcp: standard input failed: \(String(cString: strerror(errno)))\n".utf8))
                return 1
            }
            if count == 0 { break }
            for line in lines.take(buffer[..<count]) {
                guard write(server.lines(for: line), to: output) else { return 0 }
            }
        }
        // Input that ends without a line end still ended a message.
        if let last = lines.rest() { _ = write(server.lines(for: last), to: output) }
        return 0
    }

    /// Writes each line whole, with its line end; false when the reader is gone.
    private static func write(_ lines: [String], to output: Int32) -> Bool {
        for line in lines {
            var bytes = Array(line.utf8)
            bytes.append(0x0A)
            var written = 0
            while written < bytes.count {
                let count = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + written, bytes.count - written) }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN, becomesReady(output, for: POLLOUT) { continue }
                    return false
                }
                written += count
            }
        }
        return true
    }

    /// Waits until a descriptor a client left non-blocking can be read or written again.
    private static func becomesReady(_ descriptor: Int32, for event: Int32) -> Bool {
        var waiting = pollfd(fd: descriptor, events: Int16(event), revents: 0)
        while true {
            let ready = poll(&waiting, 1, -1)
            if ready > 0 { return true }
            if ready < 0, errno == EINTR { continue }
            return false
        }
    }
    #endif
}

/// Cuts the bytes a stream delivers into its lines, however the reads fall. A line longer than `limit` keeps its
/// first `limit` bytes, which then read as the broken message they are; the rest of it is dropped.
struct MCPLineBuffer {
    /// Far above any message a client sends, and a bound on what one line can make the process hold.
    var limit = 4 * 1024 * 1024
    private var pending = Data()

    /// Adds `bytes` and returns the lines they complete, without their line ends.
    mutating func take(_ bytes: some Sequence<UInt8>) -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 0x0A {
                lines.append(trimmed(pending))
                pending.removeAll(keepingCapacity: true)
            } else if pending.count < limit {
                pending.append(byte)
            }
        }
        return lines
    }

    /// What was read after the last line end, when the stream stops there; nil when nothing was.
    mutating func rest() -> Data? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : trimmed(pending)
    }

    /// A line as it was sent, without the carriage return some senders put before the line end.
    private func trimmed(_ line: Data) -> Data {
        line.last == 0x0D ? Data(line.dropLast()) : Data(line)
    }
}
