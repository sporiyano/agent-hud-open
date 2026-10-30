import XCTest
@testable import AgentHUDCore

final class WindowsCommandLineTests: XCTestCase {
    func testTheProgramNameEndsAtItsClosingQuoteAndKeepsItsBackslashes() {
        XCTAssertEqual(WindowsCommandLine.arguments(#""C:\Program Files\nodejs\node.exe" C:\cli.js -p"#),
                       [#"C:\Program Files\nodejs\node.exe"#, #"C:\cli.js"#, "-p"])
        XCTAssertEqual(WindowsCommandLine.arguments(#"C:\tools\claude.exe"#), [#"C:\tools\claude.exe"#])
        XCTAssertEqual(WindowsCommandLine.arguments("   "), [])
    }

    func testQuotesAndBackslashesFollowTheRuntimeRules() {
        XCTAssertEqual(WindowsCommandLine.arguments(#"x "a b" c\d"#), ["x", "a b", #"c\d"#])
        XCTAssertEqual(WindowsCommandLine.arguments(#"x a\"b"#), ["x", #"a"b"#])
        XCTAssertEqual(WindowsCommandLine.arguments(#"x a\\"b c""#), ["x", #"a\b c"#])
        XCTAssertEqual(WindowsCommandLine.arguments(#"x "a""b""#), ["x", #"a"b"#])
        XCTAssertEqual(WindowsCommandLine.arguments("x \"\"\ty"), ["x", "", "y"])
        XCTAssertEqual(WindowsCommandLine.arguments(#"x "C:\dir\\""#), ["x", #"C:\dir\"#])
    }
}
