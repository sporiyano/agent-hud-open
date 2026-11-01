import Foundation

/// How a client's executable is found: at the places its installers use first, since an application started from
/// Finder gets a minimal `PATH`, then in the directories of `PATH`.
enum Executables {
    /// How `PATH` is written here: `:` between directories, or on Windows `;`, where a program also carries an extension.
    struct Convention: Sendable {
        let separator: Character
        let extensions: [String]

        static let posix = Convention(separator: ":", extensions: [""])
        static let windows = Convention(separator: ";", extensions: [".exe", ".com"])

        #if os(Windows)
        static let current = windows
        #else
        static let current = posix
        #endif
    }

    /// `name` in each directory of `path`, in order, with each of the convention's extensions.
    static func onPath(_ name: String, path: String, convention: Convention = .current) -> [URL] {
        path.split(separator: convention.separator).flatMap { directory -> [URL] in
            let folder = URL(fileURLWithPath: String(directory).trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                             isDirectory: true)
            return convention.extensions.map { folder.appendingPathComponent(name + $0) }
        }
    }

    /// The first of `candidates` that can run.
    static func first(_ candidates: [URL], fileManager: FileManager = .default) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
