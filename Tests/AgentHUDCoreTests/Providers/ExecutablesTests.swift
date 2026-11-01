import XCTest
@testable import AgentHUDCore

final class ExecutablesTests: XCTestCase {
    func testAPosixPathIsSplitOnColonsAndTheNameTakenAsItIs() {
        XCTAssertEqual(Executables.onPath("codex", path: "/a:/b/c", convention: .posix).map(\.path), ["/a/codex", "/b/c/codex"])
    }

    func testAWindowsPathIsSplitOnSemicolonsAndEachProgramTriedWithItsExtensions() {
        let found = Executables.onPath("codex", path: #"/a;"/b c";"#, convention: .windows).map(\.lastPathComponent)
        XCTAssertEqual(found, ["codex.exe", "codex.com", "codex.exe", "codex.com"])
        XCTAssertEqual(Executables.onPath("codex", path: #""/b c""#, convention: .windows).first?.deletingLastPathComponent().lastPathComponent,
                       "b c", "a quoted directory loses its quotes")
    }

    func testTheWindowsCodexAppsNewestBuildComesFirst() throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let bin = local.appendingPathComponent("OpenAI/Codex/bin", isDirectory: true)
        for (name, age) in [("old", 3600.0), ("new", 0.0)] {
            let build = bin.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: build.path)
        }
        let found = CodexLocator.windowsDesktop(home: local, environment: ["LOCALAPPDATA": local.path])
        XCTAssertEqual(found.map { $0.deletingLastPathComponent().lastPathComponent }, ["new", "old"])
        XCTAssertTrue(found.allSatisfy { $0.lastPathComponent == "codex.exe" })
        XCTAssertTrue(CodexLocator.windowsDesktop(home: local, environment: [:]).isEmpty, "no AppData under this home")
    }
}
