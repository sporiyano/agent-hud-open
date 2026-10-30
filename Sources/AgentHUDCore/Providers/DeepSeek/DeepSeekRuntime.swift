import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum DeepSeekRuntime {
    /// Inspect the Harness processes holding this Harness home's profile files, without reading credentials.
    static func processStarts(directory: URL) async -> [Date] {
        #if !canImport(Darwin)
        return []
        #else
        await Task.detached(priority: .utility) {
            let profiles = directory.appendingPathComponent("profiles")
            let files = ((try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [])
                .map { $0.appendingPathComponent("cordis.yml") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty,
                  let output = try? await ProviderCommand.run("/usr/sbin/lsof",
                    ["-nP", "-a", "-u", String(getuid()), "-Fp", "--"] + files.map(\.path)) else { return [] }
            return processIDs(output).compactMap { pid in
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                      info.pbi_uid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
                let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard isHarness(executable: executable) else { return nil }
                return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
            }
        }.value
        #endif
    }

    /// A command-line Harness runs on Node. The desktop app runs its Host, which holds `profiles/desktop/cordis.yml`, and
    /// the `dsh` command it installs on its own Electron in Node mode, whose executable is named after the app.
    static func isHarness(executable: String) -> Bool {
        ["node", DeepSeekScriptRuntime.desktopName].contains(URL(fileURLWithPath: executable).lastPathComponent)
    }

    static func processIDs(_ output: String) -> Set<Int32> {
        Set(output.split(separator: "\n").compactMap { line in
            guard line.first == "p", let pid = Int32(line.dropFirst()), pid > 0 else { return nil }
            return pid
        })
    }
}
