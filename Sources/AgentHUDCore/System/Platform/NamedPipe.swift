#if os(Windows)
import Foundation
import WinSDK

/// The Windows channel between the running application and the short-lived processes a client's hooks start, in place
/// of the unix socket at the same path. A pipe cannot half-close, so a request is framed: its length as four
/// little-endian bytes, then its bytes. The answer is everything the server writes before it closes the pipe.
/// Remote clients are refused, and the pipe's default security lets only this user and the system in.
enum NamedPipe {
    /// The pipe that stands for the socket at `path`.
    static func name(for path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let safe = String(normalized.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
        })
        return "\\\\.\\pipe\\agenthud-" + String(safe.suffix(200))
    }

    static func frame(_ data: Data) -> Data {
        var length = UInt32(data.count).littleEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(data)
        return framed
    }

    // MARK: Client

    /// Sends `request` to the server at the socket path `path` and returns its answer, at most `limit` bytes; nil when
    /// nobody serves the pipe. `waitForAnswer` false leaves after sending.
    static func exchange(_ path: String, _ request: Data, limit: Int, waitForAnswer: Bool = true) -> Data? {
        guard let pipe = open(name(for: path)) else { return nil }
        defer { CloseHandle(pipe) }
        guard write(pipe, frame(request)) else { return nil }
        guard waitForAnswer else { return Data() }
        return readToEnd(pipe, limit: limit)
    }

    /// `exchange` bounded by `timeout`; nil when the answer did not come in time. A read that never returns is left to
    /// its thread.
    static func exchange(_ path: String, _ request: Data, limit: Int, timeout: TimeInterval) -> Data?? {
        final class Box: @unchecked Sendable { var answer: Data?? = .none }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.answer = .some(exchange(path, request, limit: limit))
            done.signal()
        }
        guard done.wait(timeout: .now() + max(timeout, 0.001)) == .success else { return .none }
        return box.answer
    }

    private static func open(_ name: String) -> HANDLE? {
        for attempt in 0..<2 {
            let handle = name.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            if let handle, handle != INVALID_HANDLE_VALUE { return handle }
            // Every instance is busy with another hook: wait a moment for one to come free.
            guard attempt == 0, GetLastError() == DWORD(ERROR_PIPE_BUSY),
                  Bool(name.withCString(encodedAs: UTF16.self) { WaitNamedPipeW($0, 2000) }) else { return nil }
        }
        return nil
    }

    static func write(_ pipe: HANDLE, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var sent = 0
            while sent < buffer.count {
                var written: DWORD = 0
                guard Bool(WriteFile(pipe, base + sent, DWORD(buffer.count - sent), &written, nil)), written > 0 else {
                    return false
                }
                sent += Int(written)
            }
            return true
        }
    }

    /// Reads until the other side closes, or until more than `limit` bytes arrived.
    static func readToEnd(_ pipe: HANDLE, limit: Int) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count <= limit {
            var read: DWORD = 0
            guard Bool(ReadFile(pipe, &buffer, DWORD(buffer.count), &read, nil)), read > 0 else { break }
            result.append(contentsOf: buffer[..<Int(read)])
        }
        return result
    }

    /// Reads exactly `count` bytes; nil when the other side closed first.
    static func read(_ pipe: HANDLE, count: Int) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 64 * 1024))
        while result.count < count {
            var read: DWORD = 0
            let wanted = min(buffer.count, count - result.count)
            guard Bool(ReadFile(pipe, &buffer, DWORD(wanted), &read, nil)), read > 0 else { return nil }
            result.append(contentsOf: buffer[..<Int(read)])
        }
        return result
    }

    // MARK: Server

    /// A new instance of the pipe, waiting for a client. `first` fails when another process already serves the name.
    static func instance(_ name: String, first: Bool) -> HANDLE? {
        let mode = DWORD(PIPE_ACCESS_DUPLEX) | (first ? DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE) : 0)
        let type = DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_READMODE_BYTE) | DWORD(PIPE_WAIT) | DWORD(PIPE_REJECT_REMOTE_CLIENTS)
        let handle = name.withCString(encodedAs: UTF16.self) {
            CreateNamedPipeW($0, mode, type, DWORD(PIPE_UNLIMITED_INSTANCES), 64 * 1024, 64 * 1024, 0, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        return handle
    }

    /// Whether the client at the other end is still there. It does not wait or take any bytes.
    static func isConnected(_ pipe: HANDLE) -> Bool {
        var available: DWORD = 0
        return Bool(PeekNamedPipe(pipe, nil, 0, nil, &available, nil))
    }
}
#endif
