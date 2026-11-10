import Foundation

@main
struct Checks {
    static func main() throws {
        let values = ["simple", "a b", "it's quoted", "$(echo injected); `echo nope`", "first\nsecond", "\"double\" \\ path", "--dangerous-option"]
        for value in values {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "printf '%s' " + LaunchCommand.shellQuote(value)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            precondition(String(data: data, encoding: .utf8) == value)
            let appleScript = Process()
            appleScript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            appleScript.arguments = ["-e", "return " + LaunchCommand.appleScriptQuote(value)]
            let result = Pipe()
            appleScript.standardOutput = result
            try appleScript.run()
            let returned = result.fileHandleForReading.readDataToEndOfFile()
            appleScript.waitUntilExit()
            precondition(appleScript.terminationStatus == 0)
            precondition(String(data: returned, encoding: .utf8) == value + "\n")
        }
        precondition(LaunchCommand.command(path: "/tmp", executable: "/bin/claude", prompt: "--help") == "cd -- '/tmp' && '/bin/claude' -- '--help'")
        let projects = [Project(name: "Test", path: "/tmp", sessions: [DeskSession(name: "Review", prompt: "Check tests")])]
        let decoded = try JSONDecoder().decode([Project].self, from: JSONEncoder().encode(projects))
        precondition(decoded == projects)
        print("Passed: 7 shell round trips, 7 AppleScript round trips, option separation, project persistence.")
    }
}
