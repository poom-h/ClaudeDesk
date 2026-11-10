import Foundation

struct DeskSession: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var prompt = ""
    var lastOpened: Date?
}

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var sessions: [DeskSession] = [DeskSession(name: "Main session")]
    var agentID: UUID?
}

enum LaunchCommand {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func command(path: String, executable: String, prompt: String) -> String {
        let argument = prompt.isEmpty ? "" : " -- " + shellQuote(prompt)
        return "cd -- " + shellQuote(path) + " && " + shellQuote(executable) + argument
    }

    static func script(command: String, title: String) -> String {
        """
        tell application "Terminal"
            activate
            set newSession to do script \(appleScriptQuote(command))
            set custom title of newSession to \(appleScriptQuote(title))
        end tell
        """
    }
}
