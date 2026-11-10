import AppKit
import SwiftTerm

@main
struct AgentRuntimeChecks {
    @MainActor static func wait(_ condition: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), "Timed out waiting for agent terminal")
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let host = FileManager.default.temporaryDirectory.appendingPathComponent("claudedesk-agent-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: host) }
        let a = try AgentEnvironment.create(name: "A", purpose: "Test", host: host)
        let b = try AgentEnvironment.create(name: "B", purpose: "Test", host: host)
        let executable = host.appendingPathComponent("probe.sh")
        try """
        #!/bin/zsh
        [[ "$(cd "$CLAUDE_CONFIG_DIR"; pwd -P)" == "$(pwd -P)/.runtime" ]] || exit 9
        [[ "$CLAUDE_CODE_PROJECT_DIR_NAME" == agent ]] || exit 10
        [[ -z "$CLAUDE_CODE_SIMPLE$CLAUDE_CODE_SESSION_ID$CLAUDE_CODE_CHILD_SESSION$CLAUDECODE" ]] || { printf 'INHERITED-%s\\n' "$1"; exit 11; }
        printf '%s' "$1" > "$CLAUDE_CONFIG_DIR/probe-result"
        printf 'READY-%s\\n' "$1"
        while read line; do printf 'REPLY-%s-%s\\n' "$1" "$line"; done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        // Simulate ClaudeDesk being opened from inside a Claude session: none of these may reach a pane.
        for key in ["CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"] { setenv(key, "1", 1) }
        let one = RunningTerminal(project: a.project, session: DeskSession(name: "A"))
        let two = RunningTerminal(project: b.project, session: DeskSession(name: "B"))
        one.start(executable: executable.path, arguments: ["one"], environmentOverrides: AgentEnvironment.environment(for: a))
        two.start(executable: executable.path, arguments: ["two"], environmentOverrides: AgentEnvironment.environment(for: b))
        func output(_ terminal: RunningTerminal) -> String {
            String(decoding: terminal.view.getTerminal().getBufferAsData(), as: UTF8.self)
        }
        wait { output(one).contains("READY-one") && output(two).contains("READY-two") || output(one).contains("INHERITED") }
        precondition(!output(one).contains("INHERITED") && !output(two).contains("INHERITED"), "inherited Claude variables reached a pane")
        let first = try String(contentsOfFile: a.configPath + "/probe-result", encoding: .utf8)
        let second = try String(contentsOfFile: b.configPath + "/probe-result", encoding: .utf8)
        precondition(first == "one" && second == "two")
        one.view.process.send(data: Array("hello\n".utf8)[...])
        wait { output(one).contains("REPLY-one-hello") }
        precondition(!output(two).contains("hello"))
        let pid = one.view.process.shellPid
        one.stop()
        wait { kill(pid, 0) == -1 }
        precondition(two.running)
        let secondPID = two.view.process.shellPid
        two.stop()
        wait { kill(secondPID, 0) == -1 }
        print("Passed: actual RunningTerminal launches with dedicated agent cwd/config, isolated writes, independent input, process shutdown and reaping, no inherited Claude session variables.")
    }
}
