import Foundation

@main
struct MemoryToolChecks {
    static func main() throws {
        let host = FileManager.default.temporaryDirectory.appendingPathComponent("claudedesk-memory-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: host) }
        try checkServer(host: host)
        print("Passed: atrium-memory server entry added, kept, repaired after a move, user entries left alone, invalid files reported.")
    }

    /// A fake bundled binary at <host>/<app>/Contents/MacOS/atrium-memory.
    static func makeExecutable(host: URL, app: String) throws -> URL {
        let folder = host.appendingPathComponent(app + "/Contents/MacOS")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("atrium-memory")
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func mcpURL(_ agent: AgentProfile) -> URL {
        URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
    }

    static func servers(_ agent: AgentProfile) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: mcpURL(agent))) as! [String: Any]
        return object["mcpServers"] as! [String: Any]
    }

    static func checkServer(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Atlas", purpose: "Test", host: host)
        let vault = host.appendingPathComponent("MemoryVault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let exe = try makeExecutable(host: host, app: "ClaudeDesk.app")
        precondition(!MemoryTool.isConnected(agent))

        // Added to a fresh agent, with the exact entry from the spec.
        let added = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        precondition(added == .added)
        let entry = try servers(agent)["atrium-memory"] as! [String: Any]
        precondition(entry["command"] as? String == exe.path && entry["args"] as? [String] == ["mcp"])
        let env = entry["env"] as! [String: String]
        precondition(env == ["ATRIUM_MEMORY_PATH": vault.path, "ATRIUM_MEMORY_ACTOR": "Atlas"])
        precondition(MemoryTool.isConnected(agent) && MemoryTool.isAppWritten(entry))

        // Running again changes nothing.
        let again = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        precondition(again == .unchanged)

        // Other servers are kept.
        var withOther = try servers(agent)
        withOther["example"] = ["type": "http", "url": "https://example.com/mcp"]
        try JSONSerialization.data(withJSONObject: ["mcpServers": withOther]).write(to: mcpURL(agent))
        _ = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        let kept = try servers(agent)
        precondition(kept["example"] != nil, "other servers must be kept")

        // The app moved: the old binary is gone, so the app's own entry is repointed. Nothing else changes.
        let moved = try makeExecutable(host: host, app: "Moved/ClaudeDesk.app")
        try FileManager.default.removeItem(at: exe)
        let repaired = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
        precondition(repaired == .repaired)
        let after = try servers(agent)["atrium-memory"] as! [String: Any]
        precondition(after["command"] as? String == moved.path && after["env"] as? [String: String] == env)

        // A command that still exists is not replaced, even if the app offers another path.
        let elsewhere = try makeExecutable(host: host, app: "Third/ClaudeDesk.app")
        let stays = try MemoryTool.connectServer(agent, executable: elsewhere.path, vault: vault)
        precondition(stays == .unchanged)

        // An entry the user changed is left alone, even when its command is missing.
        try "{\"mcpServers\": {\"atrium-memory\": {\"command\": \"/opt/missing/wrapper\", \"args\": [\"mcp\", \"--actor\", \"me\"]}}}"
            .write(to: mcpURL(agent), atomically: true, encoding: .utf8)
        let userEntry = try String(contentsOf: mcpURL(agent), encoding: .utf8)
        let left = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
        precondition(left == .unchanged)
        let userAfter = try String(contentsOf: mcpURL(agent), encoding: .utf8)
        precondition(userAfter == userEntry)

        // Files that aren't usable JSON are reported and not rewritten.
        for invalid in ["not JSON", "[]", "{\"mcpServers\": []}"] {
            try invalid.write(to: mcpURL(agent), atomically: true, encoding: .utf8)
            do {
                _ = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
                fatalError("invalid .mcp.json should be reported: \(invalid)")
            } catch is AgentEnvironment.Failure {}
            let unchanged = try String(contentsOf: mcpURL(agent), encoding: .utf8)
            precondition(unchanged == invalid)
        }

        // A missing .mcp.json is created.
        try FileManager.default.removeItem(at: mcpURL(agent))
        let created = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
        precondition(created == .added && MemoryTool.isConnected(agent))
    }
}
