import Foundation

// Stand-ins for the few Darwin names that Core uses in shared code, so that code builds where Darwin is not there.
// Windows has one user per session and no POSIX process ids or user ids; the features that need the real ones are
// switched off there until each has a Windows implementation.

#if os(Windows)
typealias pid_t = Int32
typealias uid_t = UInt32
typealias mode_t = UInt16

/// The session's user; ownership checks compare it with itself.
func getuid() -> uid_t { 0 }

/// The path with its links resolved, as `realpath(3)` returns it: a string the caller frees, or nil when nothing is
/// at `path`.
func realpath(_ path: String, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return _strdup(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
}
#endif

#if !canImport(os)
/// The lock `os` offers on Apple platforms, built on `NSLock`.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) { state = initialState }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
