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
        try checkSettingsEdgeCases(host: host)
        try checkVaultSwitch(host: host)
        try checkVaultSwitchUserEdits(host: host)
        try checkVaultSwitchForeignEntry(host: host)
        try checkInstructionsSafety(host: host)
        try checkRunnerArguments(host: host)
        try checkAuditFlare(host: host)
        print("Passed: atrium-memory server entry, settings approval and edit block, instructions, project config, runner arguments, audit flare.")
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

        // The app's own entry follows the running app even when the old binary still exists. Env is kept.
        let elsewhere = try makeExecutable(host: host, app: "Third/ClaudeDesk.app")
        let followed = try MemoryTool.connectServer(agent, executable: elsewhere.path, vault: vault)
        precondition(followed == .repaired)
        let followedEntry = try servers(agent)["atrium-memory"] as! [String: Any]
        precondition(followedEntry["command"] as? String == elsewhere.path && followedEntry["args"] as? [String] == ["mcp"])
        precondition(followedEntry["env"] as? [String: String] == env)
        let followedAgain = try MemoryTool.connectServer(agent, executable: elsewhere.path, vault: vault)
        precondition(followedAgain == .unchanged)

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

    /// Settings that have the wrong shape are reported and not rewritten; a settings path that can't be read throws its own error.
    static func checkSettingsEdgeCases(host: URL) throws {
        let vault = host.appendingPathComponent("EdgeVault")
        let agent = try AgentEnvironment.create(name: "Edge", purpose: "Test", host: host)
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        for invalid in ["{\"permissions\": \"x\"}", "{\"enabledMcpjsonServers\": \"x\"}"] {
            try invalid.write(to: url, atomically: true, encoding: .utf8)
            do {
                try MemoryTool.connectSettings(agent, vault: vault)
                fatalError("invalid settings should be reported: \(invalid)")
            } catch is AgentEnvironment.Failure {}
            let unchanged = try String(contentsOf: url, encoding: .utf8)
            precondition(unchanged == invalid)
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var thrown: Error?
        do { try MemoryTool.connectSettings(agent, vault: vault) } catch { thrown = error }
        precondition(thrown != nil, "a settings path that is a directory must throw")
        precondition(!(thrown is AgentEnvironment.Failure), "a read error must not be reported as invalid JSON")
    }

    /// connectInstructions must never overwrite a CLAUDE.md it cannot read; a missing one is created.
    static func checkInstructionsSafety(host: URL) throws {
        let vault = host.appendingPathComponent("SafetyVault")

        let bad = try AgentEnvironment.create(name: "Unreadable", purpose: "Test", host: host)
        let badURL = URL(fileURLWithPath: bad.path).appendingPathComponent("CLAUDE.md")
        let bytes = Data([0xFF, 0xFE, 0x00])
        try bytes.write(to: badURL)
        var thrown: Error?
        do { try MemoryTool.connectInstructions(bad, vault: vault) } catch { thrown = error }
        precondition(thrown != nil, "a CLAUDE.md that is not UTF-8 must throw")
        let badAfter = try Data(contentsOf: badURL)
        precondition(badAfter == bytes, "a CLAUDE.md that is not UTF-8 must be left unchanged")

        let dir = try AgentEnvironment.create(name: "Directory", purpose: "Test", host: host)
        let dirURL = URL(fileURLWithPath: dir.path).appendingPathComponent("CLAUDE.md")
        try FileManager.default.removeItem(at: dirURL)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        thrown = nil
        do { try MemoryTool.connectInstructions(dir, vault: vault) } catch { thrown = error }
        precondition(thrown != nil, "a CLAUDE.md that is a directory must throw")
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                     "a CLAUDE.md that is a directory must be left in place")

        let missing = try AgentEnvironment.create(name: "Missing", purpose: "Test", host: host)
        let missingURL = URL(fileURLWithPath: missing.path).appendingPathComponent("CLAUDE.md")
        try FileManager.default.removeItem(at: missingURL)
        try MemoryTool.connectInstructions(missing, vault: vault)
        let created = try String(contentsOf: missingURL, encoding: .utf8)
        precondition(created.contains(MemoryTool.instructionsMarker) && created.contains("## Memory Vault tools"),
                     "a missing CLAUDE.md must be created with the section")
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

    static func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    /// The entry follows the current vault, and the app's deny rule and CLAUDE.md section move with it.
    static func checkVaultSwitch(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Switcher", purpose: "Test", host: host)
        let vaultA = host.appendingPathComponent("SwitchVaultA")
        let vaultB = host.appendingPathComponent("SwitchVaultB")
        let exe = try makeExecutable(host: host, app: "Switch/ClaudeDesk.app")
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        let claudeURL = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")

        // The user already had deny rules; the app's rule is added after them, and one more is added later.
        try JSONSerialization.data(withJSONObject: ["permissions": ["deny": ["Bash(rm:*)"]]]).write(to: settingsURL)
        _ = try MemoryTool.connect(agent, executable: exe, vault: vaultA, firstTime: true)
        var s = try settings(agent)
        var permissions = s["permissions"] as! [String: Any]
        permissions["deny"] = (permissions["deny"] as! [String]) + ["Read(/secret/**)"]
        s["permissions"] = permissions
        try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL)
        precondition((permissions["deny"] as! [String]) == ["Bash(rm:*)", MemoryTool.vaultEditRule(vaultA), "Read(/secret/**)"])

        let change = try MemoryTool.connect(agent, executable: exe, vault: vaultB, firstTime: false)
        precondition(change == .repaired)
        let entry = try servers(agent)["atrium-memory"] as! [String: Any]
        let env = entry["env"] as! [String: String]
        precondition(env["ATRIUM_MEMORY_PATH"] == vaultB.path && env["ATRIUM_MEMORY_ACTOR"] == "Switcher")
        let deny = ((try settings(agent))["permissions"] as! [String: Any])["deny"] as! [String]
        precondition(deny == ["Bash(rm:*)", MemoryTool.vaultEditRule(vaultB), "Read(/secret/**)"], "the rule moves in place: \(deny)")
        let text = try String(contentsOf: claudeURL, encoding: .utf8)
        precondition(text.contains(MemoryTool.instructionsSection(vault: vaultB)) && !text.contains(vaultA.path))
        precondition(text.components(separatedBy: MemoryTool.instructionsMarker).count == 2)

        // Again with B: nothing changes, byte for byte.
        let mcpBefore = try read(mcpURL(agent)), settingsBefore = try read(settingsURL), claudeBefore = try read(claudeURL)
        let second = try MemoryTool.connect(agent, executable: exe, vault: vaultB, firstTime: false)
        precondition(second == .unchanged)
        let mcpAfter = try read(mcpURL(agent)), settingsAfter = try read(settingsURL), claudeAfter = try read(claudeURL)
        precondition(mcpBefore == mcpAfter && settingsBefore == settingsAfter && claudeBefore == claudeAfter)

        // Extra env keys survive a switch back.
        var extra = entry
        extra["env"] = env.merging(["EXTRA": "1"]) { a, _ in a }
        try writeConfig(agent, servers: ["atrium-memory": extra])
        _ = try MemoryTool.connect(agent, executable: exe, vault: vaultA, firstTime: false)
        let back = (try servers(agent)["atrium-memory"] as! [String: Any])["env"] as! [String: String]
        precondition(back == ["ATRIUM_MEMORY_PATH": vaultA.path, "ATRIUM_MEMORY_ACTOR": "Switcher", "EXTRA": "1"])
    }

    /// A rule the user removed is not added back, and a section the user edited is not touched.
    static func checkVaultSwitchUserEdits(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Editor", purpose: "Test", host: host)
        let vaultA = host.appendingPathComponent("EditVaultA")
        let vaultB = host.appendingPathComponent("EditVaultB")
        let exe = try makeExecutable(host: host, app: "EditSwitch/ClaudeDesk.app")
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        let claudeURL = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")
        _ = try MemoryTool.connect(agent, executable: exe, vault: vaultA, firstTime: true)

        var s = try settings(agent)
        var permissions = s["permissions"] as! [String: Any]
        permissions["deny"] = [String]()
        s["permissions"] = permissions
        try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL)
        let edited = try String(contentsOf: claudeURL, encoding: .utf8).replacingOccurrences(of: "Use them instead", with: "Prefer them over")
        try edited.write(to: claudeURL, atomically: true, encoding: .utf8)
        let settingsBefore = try read(settingsURL), claudeBefore = try read(claudeURL)

        let change = try MemoryTool.connect(agent, executable: exe, vault: vaultB, firstTime: false)
        precondition(change == .repaired)
        let entry = try servers(agent)["atrium-memory"] as! [String: Any]
        precondition((entry["env"] as! [String: String])["ATRIUM_MEMORY_PATH"] == vaultB.path)
        let settingsAfter = try read(settingsURL), claudeAfter = try read(claudeURL)
        precondition(settingsAfter == settingsBefore, "no B deny rule is added when the user removed the A rule")
        precondition(claudeAfter == claudeBefore, "an edited section is left untouched")

        // Unusable settings are reported, nothing is written, and the entry stays on the old vault so a retry can finish.
        let broken = try AgentEnvironment.create(name: "Broken", purpose: "Test", host: host)
        let brokenSettings = URL(fileURLWithPath: broken.path).appendingPathComponent(".claude/settings.local.json")
        _ = try MemoryTool.connect(broken, executable: exe, vault: vaultA, firstTime: true)
        try "not JSON".write(to: brokenSettings, atomically: true, encoding: .utf8)
        let mcpBefore = try read(mcpURL(broken))
        do {
            _ = try MemoryTool.connect(broken, executable: exe, vault: vaultB, firstTime: false)
            fatalError("unusable settings should be reported")
        } catch is AgentEnvironment.Failure {}
        let brokenAfter = try String(contentsOf: brokenSettings, encoding: .utf8)
        let mcpAfter = try read(mcpURL(broken))
        precondition(brokenAfter == "not JSON" && mcpAfter == mcpBefore)
    }

    /// An entry the user changed is never touched by a switch, and neither are its files.
    static func checkVaultSwitchForeignEntry(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Foreign", purpose: "Test", host: host)
        let vaultA = host.appendingPathComponent("ForeignVaultA")
        let vaultB = host.appendingPathComponent("ForeignVaultB")
        let exe = try makeExecutable(host: host, app: "Foreign/ClaudeDesk.app")
        let custom: [String: Any] = ["command": exe.path, "args": ["mcp", "--read-only"],
                                     "env": ["ATRIUM_MEMORY_PATH": vaultA.path, "ATRIUM_MEMORY_ACTOR": "me"]]
        try writeConfig(agent, servers: ["atrium-memory": custom])
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        try JSONSerialization.data(withJSONObject: ["permissions": ["deny": [MemoryTool.vaultEditRule(vaultA)]]]).write(to: settingsURL)
        let mcpBefore = try read(mcpURL(agent)), settingsBefore = try read(settingsURL)
        let change = try MemoryTool.connect(agent, executable: exe, vault: vaultB, firstTime: false)
        precondition(change == .unchanged)
        let mcpAfter = try read(mcpURL(agent)), settingsAfter = try read(settingsURL)
        precondition(mcpBefore == mcpAfter && settingsBefore == settingsAfter)
    }

    static func checkRunnerArguments(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Runner", purpose: "x", host: host)
        let vault = host.appendingPathComponent("RunnerVault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".tools"), withIntermediateDirectories: true)
        try "".write(to: vault.appendingPathComponent(".tools/vault_check.py"), atomically: true, encoding: .utf8)
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        try JSONSerialization.data(withJSONObject: ["permissions": ["additionalDirectories": [vault.path]]]).write(to: settingsURL)
        let routine = Routine(name: "nightly")
        let vaultEdit = "Edit(/" + vault.path + "/**)"
        let checker = "Bash(python3 " + vault.appendingPathComponent(".tools/vault_check.py").path + ")"

        // Not connected: today's behaviour, unchanged.
        let before = RoutineRunner.arguments(for: routine, agent: agent, runID: "r1", prompt: "go", vault: vault)
        precondition(before.contains(vaultEdit) && !before.contains("mcp__atrium-memory") && !before.contains("--disallowedTools"))

        // Connected: the tools are allowed, vault edits are not granted and are explicitly disallowed.
        _ = try MemoryTool.connectServer(agent, executable: "/Applications/ClaudeDesk.app/Contents/MacOS/atrium-memory", vault: vault)
        let after = RoutineRunner.arguments(for: routine, agent: agent, runID: "r2", prompt: "go", vault: vault)
        let separator = after.firstIndex(of: "--")!
        precondition(after.contains("mcp__atrium-memory") && after.firstIndex(of: "mcp__atrium-memory")! < separator)
        let allowedStart = after.firstIndex(of: "--allowedTools")! + 1
        let disallowedAt = after.firstIndex(of: "--disallowedTools")!
        precondition(!after[allowedStart..<disallowedAt].contains(vaultEdit), "connected agents must not be granted Edit on the vault")
        let disallowed = after.firstIndex(of: "--disallowedTools")!
        precondition(after[disallowed + 1] == vaultEdit && disallowed < separator)
        precondition(after.contains(checker), "the vault checker stays allowed")
        precondition(after.contains("Edit(/" + agent.path + "/**)"), "the agent's own folder stays editable")
        precondition(after.last == "go" && after[separator + 1] == "go")

        // Without a vault (older callers), nothing changes for connected agents either.
        let noVault = RoutineRunner.arguments(for: routine, agent: agent, runID: "r3", prompt: "go")
        precondition(!noVault.contains("mcp__atrium-memory") && !noVault.contains("--disallowedTools"))
    }

    static func checkAuditFlare(host: URL) throws {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)                  // 2026-11-10T09:00:00Z
        let nanos = String(stamp.dropLast()) + ".123456789Z"                  // as atrium-memory writes it
        let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))

        let read = VaultActivity.auditReads(in: #"{"time":"\#(stamp)","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#, now: now)
        precondition(read?.actor == "Atlas" && read?.notes == ["Notes/A.md"])
        let fractional = VaultActivity.auditReads(in: #"{"time":"\#(nanos)","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#, now: now)
        precondition(fractional?.notes == ["Notes/A.md"], "nanosecond timestamps must parse")
        let search = VaultActivity.auditReads(in: #"{"time":"\#(stamp)","actor":"Scout","tool":"vault_search","query":"aws","results":["Notes/A.md","Maps/Tech.md"],"outcome":"ok"}"#, now: now)
        precondition(search?.actor == "Scout" && search?.notes == ["Notes/A.md", "Maps/Tech.md"])
        for ignored in [
            #"{"time":"\#(stamp)","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"not_found"}"#,
            #"{"time":"\#(stamp)","actor":"Atlas","tool":"vault_write","id":"Notes/A.md","outcome":"ok"}"#,
            #"{"time":"\#(stamp)","actor":"Atlas","tool":"vault_search","outcome":"ok"}"#,
            #"{"time":"\#(old)","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#,
            #"{"time":"\#(future)","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#,
            #"{"actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#,
            #"{"time":"yesterday","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#,
            "not json", ""
        ] {
            let result = VaultActivity.auditReads(in: ignored, now: now)
            precondition(result == nil || result!.notes.isEmpty, "should light nothing: \(ignored)")
        }
        precondition(VaultActivity.auditReads(in: #"{"time":"\#(old)","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#, now: now) == nil, "a 60 second old line is history, not a read")

        let vault = host.appendingPathComponent("FlareVault")
        precondition(VaultActivity.auditLog(in: vault).path == vault.path + "/.atrium-memory/audit.jsonl")

        // An audit file that already holds old lines lights nothing; lines appended afterwards do.
        let log = VaultActivity.auditLog(in: vault)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"time":"\#(old)","actor":"Atlas","tool":"vault_read","id":"Old.md","outcome":"ok"}"# + "\n").write(to: log, atomically: true, encoding: .utf8)
        let tail = VaultActivity.Tail()
        let replayed = tail.newLines(in: [log]).compactMap { VaultActivity.auditReads(in: $0.1, now: now) }
        precondition(replayed.isEmpty, "old audit lines in a new file must not light notes")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"time":"\#(stamp)","actor":"Atlas","tool":"vault_read","id":"Home.md","outcome":"ok"}"# + "\n").utf8))
        try handle.close()
        let first = tail.newLines(in: [log]).compactMap { VaultActivity.auditReads(in: $0.1, now: now) }
        precondition(first.map(\.notes) == [["Home.md"]])
        let again = try FileHandle(forWritingTo: log)
        try again.seekToEnd()
        try again.write(contentsOf: Data((#"{"time":"\#(stamp)","actor":"Atlas","tool":"vault_read","id":"Notes/B.md","outcome":"ok"}"# + "\n").utf8))
        try again.close()
        let second = tail.newLines(in: [log]).compactMap { VaultActivity.auditReads(in: $0.1, now: now) }
        precondition(second.map(\.notes) == [["Notes/B.md"]])

        // Graph IDs may be decomposed on disk while audit notes are composed. The read lands on the graph's own ID.
        let graph: Set<String> = ["Notes/Caf\u{0065}\u{0301}.md", "Notes/Plain.md"]
        let matched = VaultActivity.graphIDs(for: ["Notes/Caf\u{00E9}.md", "Notes/Missing.md"], in: graph)
        precondition(matched.count == 1 && matched[0].unicodeScalars.map(\.value) == "Notes/Caf\u{0065}\u{0301}.md".unicodeScalars.map(\.value), "an NFC note must return the NFD graph id")
    }
}
