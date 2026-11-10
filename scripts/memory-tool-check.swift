import Foundation

@main
struct MemoryToolChecks {
    static func main() throws {
        let host = FileManager.default.temporaryDirectory.appendingPathComponent("claudedesk-memory-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: host) }
        try checkServer(host: host)
        try checkAdditive(host: host)
        try checkUnchangedPaths(host: host)
        try checkReadErrors(host: host)
        try checkSettingsAndInstructions(host: host)
        print("Passed: atrium-memory server entry, settings approval and edit block, instructions, project config.")
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

    static func settings(_ agent: AgentProfile) throws -> [String: Any] {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func checkSettingsAndInstructions(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Scout", purpose: "Find things", host: host)
        let vault = host.appendingPathComponent("MemoryVault")
        let exe = try makeExecutable(host: host, app: "Settings.app")
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        let claudeURL = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")

        // Existing settings are kept; the three entries are added once.
        let existing: [String: Any] = ["permissions": ["additionalDirectories": [vault.path], "allow": ["WebSearch"]], "model": "opus"]
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)
        try MemoryTool.connectSettings(agent, vault: vault)
        try MemoryTool.connectSettings(agent, vault: vault)
        let s = try settings(agent)
        let permissions = s["permissions"] as! [String: Any]
        precondition(s["model"] as? String == "opus")
        precondition(s["enabledMcpjsonServers"] as? [String] == ["atrium-memory"])
        precondition(permissions["allow"] as? [String] == ["WebSearch", "mcp__atrium-memory"])
        precondition(permissions["deny"] as? [String] == ["Edit(/" + vault.path + "/**)"])
        precondition(MemoryTool.vaultEditRule(vault).hasPrefix("Edit(//"))
        precondition(permissions["additionalDirectories"] as? [String] == [vault.path])

        // Settings that aren't usable are reported and not rewritten.
        for invalid in ["not JSON", "{\"permissions\": {\"allow\": \"Read\"}}"] {
            try invalid.write(to: settingsURL, atomically: true, encoding: .utf8)
            do {
                try MemoryTool.connectSettings(agent, vault: vault)
                fatalError("unusable settings should be reported: \(invalid)")
            } catch is AgentEnvironment.Failure {}
            let unchanged = try String(contentsOf: settingsURL, encoding: .utf8)
            precondition(unchanged == invalid)
        }
        try "{}".write(to: settingsURL, atomically: true, encoding: .utf8)

        // The CLAUDE.md section is appended once, and the existing text is kept.
        let before = try String(contentsOf: claudeURL, encoding: .utf8)
        try MemoryTool.connectInstructions(agent, vault: vault)
        try MemoryTool.connectInstructions(agent, vault: vault)
        let text = try String(contentsOf: claudeURL, encoding: .utf8)
        precondition(text.hasPrefix(before))
        precondition(text.components(separatedBy: MemoryTool.instructionsMarker).count == 2, "section added exactly once")
        for phrase in ["## Memory Vault tools", vault.path, "vault_read", "vault_search", "vault_edit", "stale_version", ".tools/vault_check.py"] {
            precondition(text.contains(phrase), "instructions should mention \(phrase)")
        }

        // connect(firstTime: false) only checks the server entry.
        let other = try AgentEnvironment.create(name: "Later", purpose: "x", host: host)
        let otherSettings = URL(fileURLWithPath: other.path).appendingPathComponent(".claude/settings.local.json")
        let otherClaude = URL(fileURLWithPath: other.path).appendingPathComponent("CLAUDE.md")
        let settingsBefore = try String(contentsOf: otherSettings, encoding: .utf8)
        let claudeBefore = try String(contentsOf: otherClaude, encoding: .utf8)
        let change = try MemoryTool.connect(other, executable: exe, vault: vault, firstTime: false)
        precondition(change == .added && MemoryTool.isConnected(other))
        let settingsAfter = try String(contentsOf: otherSettings, encoding: .utf8)
        let claudeAfter = try String(contentsOf: otherClaude, encoding: .utf8)
        precondition(settingsAfter == settingsBefore && claudeAfter == claudeBefore)
        _ = try MemoryTool.connect(other, executable: exe, vault: vault, firstTime: true)
        let claudeConnected = try String(contentsOf: otherClaude, encoding: .utf8)
        precondition(claudeConnected.contains(MemoryTool.instructionsMarker))
        let otherSettingsConnected = try settings(other)
        precondition(otherSettingsConnected["enabledMcpjsonServers"] as? [String] == ["atrium-memory"])

        // The project config is the same entry, with actor "project".
        let project = MemoryTool.projectConfig(executable: exe, vault: vault)
        let parsed = try JSONSerialization.jsonObject(with: Data(project.utf8)) as! [String: Any]
        let entry = (parsed["mcpServers"] as! [String: Any])["atrium-memory"] as! [String: Any]
        precondition((entry["env"] as! [String: String])["ATRIUM_MEMORY_ACTOR"] == "project" && entry["command"] as? String == exe.path)
    }

    /// Canonical JSON bytes, so two values can be compared exactly.
    static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    /// Writes .mcp.json with an unrelated top-level key and the given servers.
    static func writeConfig(_ agent: AgentProfile, servers: [String: Any]) throws {
        let object: [String: Any] = ["foo": ["bar": [1, 2]], "mcpServers": servers]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: mcpURL(agent))
    }

    /// Adds and repairs must leave an unrelated top-level key and another server exactly as they were.
    static func checkAdditive(host: URL) throws {
        let example: [String: Any] = ["type": "http", "url": "https://example.com/mcp", "headers": ["X": "y"]]
        let expectedFoo = try canonical(["bar": [1, 2]])
        let expectedExample = try canonical(example)

        func assertKept(_ agent: AgentProfile, _ context: String) throws {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: mcpURL(agent))) as! [String: Any]
            let foo = try canonical(object["foo"] ?? NSNull())
            precondition(foo == expectedFoo, "foo changed after \(context)")
            let servers = object["mcpServers"] as! [String: Any]
            let kept = try canonical(servers["example"] ?? NSNull())
            precondition(kept == expectedExample, "example server changed after \(context)")
        }

        let agent = try AgentEnvironment.create(name: "Additive", purpose: "Test", host: host)
        let vault = host.appendingPathComponent("AdditiveVault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let exe = try makeExecutable(host: host, app: "AddApp/ClaudeDesk.app")

        // Add: no atrium-memory entry yet.
        try writeConfig(agent, servers: ["example": example])
        let added = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        precondition(added == .added)
        precondition(MemoryTool.isConnected(agent))
        try assertKept(agent, "add")

        // Repair: the app wrote the entry, then the app was moved and the old command is gone.
        let oldCommand = host.appendingPathComponent("Gone/ClaudeDesk.app/Contents/MacOS/atrium-memory").path
        try writeConfig(agent, servers: ["example": example,
                                         "atrium-memory": MemoryTool.serverEntry(executable: oldCommand, vault: vault, actor: "Additive")])
        let repaired = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        precondition(repaired == .repaired)
        let command = try servers(agent)["atrium-memory"] as! [String: Any]
        precondition(command["command"] as? String == exe.path)
        try assertKept(agent, "repair")
    }

    /// Entries that match the app's pattern, or are not objects, must not be rewritten.
    static func checkUnchangedPaths(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Unchanged", purpose: "Test", host: host)
        let vault = host.appendingPathComponent("UnchangedVault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        // App-written entry whose command equals the executable, but the file does not exist on disk.
        let missing = host.appendingPathComponent("Missing/ClaudeDesk.app/Contents/MacOS/atrium-memory").path
        try writeConfig(agent, servers: ["atrium-memory": MemoryTool.serverEntry(executable: missing, vault: vault, actor: "Unchanged")])
        let beforeSame = try Data(contentsOf: mcpURL(agent))
        let same = try MemoryTool.connectServer(agent, executable: missing, vault: vault)
        precondition(same == .unchanged)
        let afterSame = try Data(contentsOf: mcpURL(agent))
        precondition(afterSame == beforeSame, "matching command must leave the file byte-for-byte unchanged")

        // An atrium-memory value that is not an object.
        try "{\n  \"mcpServers\": {\"atrium-memory\": \"x\"}\n}\n".write(to: mcpURL(agent), atomically: true, encoding: .utf8)
        let beforeText = try Data(contentsOf: mcpURL(agent))
        let text = try MemoryTool.connectServer(agent, executable: missing, vault: vault)
        precondition(text == .unchanged)
        let afterText = try Data(contentsOf: mcpURL(agent))
        precondition(afterText == beforeText, "non-object entry must leave the file byte-for-byte unchanged")
    }

    /// A read failure (here, permission denied) must propagate as itself, not as "not a JSON object".
    static func checkReadErrors(host: URL) throws {
        if getuid() == 0 {
            print("Skipped: unreadable .mcp.json check (running as root).")
            return
        }
        let agent = try AgentEnvironment.create(name: "Locked", purpose: "Test", host: host)
        let vault = host.appendingPathComponent("LockedVault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let exe = try makeExecutable(host: host, app: "LockedApp/ClaudeDesk.app")
        let text = Data("{\"mcpServers\": {}}\n".utf8)
        try text.write(to: mcpURL(agent))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mcpURL(agent).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mcpURL(agent).path) }

        var thrown: Error?
        do { _ = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault) } catch { thrown = error }
        precondition(thrown != nil, "an unreadable .mcp.json must throw")
        precondition(!(thrown is AgentEnvironment.Failure), "a read error must not be reported as invalid JSON")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mcpURL(agent).path)
        let unchanged = try Data(contentsOf: mcpURL(agent))
        precondition(unchanged == text, "an unreadable .mcp.json must be left unchanged")
    }
}
