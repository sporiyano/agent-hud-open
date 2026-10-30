import Foundation

/// The application's side of the channel MCP tool calls arrive on: a socket named `mcp.sock` in the data directory,
/// which the `--mcp` process a client started connects to once per call. Each request is handed to `handler` on the
/// main actor and its reply written back; a message that is no request is answered with the reason.
///
/// The handler answers from what the application already holds. It runs for any process of this user that reaches
/// the socket, so it must never start a provider read or keep anything a person did not confirm.
@MainActor
public final class MCPAppChannel {
    public let path: String
    private let handler: @MainActor (MCPToolRequest) -> MCPToolReply
    private var listener: UnixSocketListener?

    /// Where the process and the application meet in `directory`. The name is short on purpose: a unix socket path
    /// has about a hundred bytes.
    public nonisolated static func socketPath(in directory: URL = AppSupport.directory) -> String {
        directory.appendingPathComponent("mcp.sock").path
    }

    public init(directory: URL = AppSupport.directory, handler: @escaping @MainActor (MCPToolRequest) -> MCPToolReply) {
        path = Self.socketPath(in: directory)
        self.handler = handler
    }

    public var isListening: Bool { listener != nil }

    /// Opens the channel; false when another copy of the application already serves it or the socket cannot be made.
    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        let handler = handler
        let listener = UnixSocketListener(path: path, requestLimit: MCPToolRequest.sizeLimit, category: "mcp") { data, connection in
            let reply: MCPToolReply
            do {
                reply = handler(try MCPToolRequest.read(data))
            } catch let unreadable as MCPToolRequest.Unreadable {
                reply = .failure(unreadable.reason)
            } catch {
                reply = .failure("The request could not be read.")
            }
            connection.reply(reply.message)
        }
        guard listener.start() else { return false }
        self.listener = listener
        return true
    }

    /// Closes the channel. Only the socket this process made is removed.
    public func stop() {
        listener?.stop()
        listener = nil
    }
}
