import XCTest
@testable import ClaudeDesk

final class LaunchCommandTests: XCTestCase {
    func testShellArgumentsRemainLiteral() throws {
        let values = ["simple", "a b", "it's quoted", "$(echo injected); `echo nope`", "first\nsecond", "\"double\" \\ path"]
        for value in values {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "printf '%s' " + LaunchCommand.shellQuote(value)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let result = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(data: result, encoding: .utf8), value)
        }
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(LaunchCommand.appleScriptQuote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    func testEmptyPromptDoesNotAddArgument() {
        XCTAssertEqual(LaunchCommand.command(path: "/tmp/a b", executable: "/bin/claude", prompt: ""), "cd -- '/tmp/a b' && '/bin/claude'")
    }

    func testSavedProjectsRoundTrip() throws {
        let projects = [Project(name: "Example", path: "/tmp/example", sessions: [DeskSession(name: "Review", prompt: "Check tests")])]
        XCTAssertEqual(try JSONDecoder().decode([Project].self, from: JSONEncoder().encode(projects)), projects)
    }
}
