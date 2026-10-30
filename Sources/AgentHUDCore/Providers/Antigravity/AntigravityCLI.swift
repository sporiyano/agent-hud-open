#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// The quota a running `agy` prints for `agy -p /usage`. agy's own language server answers only requests carrying a CSRF
/// token that no command line shows, so a terminal-only setup has no server this app can ask. agy's print mode answers
/// its read-only slash commands without starting a turn, spending quota or leaving a conversation behind.
struct AntigravityCLI: Sendable {
    var printUsage: @Sendable (URL) async throws -> Data = Self.printUsage

    /// The program of the first running `agy` among the candidates, as the system names it, so the client that runs is
    /// the one asked rather than any program of that name.
    static func executable(of candidates: [AntigravityService.Candidate]) -> URL? {
        #if !canImport(Darwin)
        return nil
        #else
        candidates.lazy.compactMap { candidate -> URL? in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(Int32(candidate.pid), &path, UInt32(path.count)) > 0 else { return nil }
            let url = URL(fileURLWithPath: String(cString: path))
            return url.lastPathComponent == "agy" ? url : nil
        }.first
        #endif
    }

    func quota(executable: URL) async throws -> ProviderQuota {
        try Self.usage(try ProviderJSON.read(try await printUsage(executable)))
    }

    /// The same groups and buckets as the language server's quota summary, in snake case.
    static func usage(_ json: ProviderJSON) throws -> ProviderQuota {
        guard json["status"].stringValue == "SUCCESS", json["command"]["name"].stringValue == "usage",
              let groups = json["command"]["data"]["groups"].arrayValue else { throw ProviderFailure.format }
        return try AntigravityClient.summary(.object(["groups": .array(groups.map { group in
            .object(["displayName": group["name"], "buckets": group["buckets"].arrayValue.map { buckets in
                .array(buckets.map { bucket in
                    .object(["bucketId": bucket["id"], "displayName": bucket["name"],
                             "remainingFraction": bucket["remaining_fraction"], "resetTime": bucket["reset_time"]])
                })
            } ?? .null])
        })]))
    }

    private static func printUsage(_ executable: URL) async throws -> Data {
        let output = try await ChildProcess.run(executable, ["-p", "/usage", "--output-format", "json"],
                                                timeout: 30, stdoutLimit: 1024 * 1024)
        guard output.status == 0, !output.truncated else { throw ProviderFailure.format }
        return output.stdout
    }
}
