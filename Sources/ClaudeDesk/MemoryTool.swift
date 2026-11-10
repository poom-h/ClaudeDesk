import Foundation

/// Connects agents to atrium-memory, the Memory Vault MCP server that ships inside ClaudeDesk.
/// Every change is additive: other servers, other settings, and anything the user changed are kept.
enum MemoryTool {
    static let serverName = "atrium-memory"
    /// The permission name that allows every atrium-memory tool.
    static let toolPermission = "mcp__atrium-memory"
    static let instructionsMarker = "<!-- claudedesk:memory-tool -->"

    /// The binary bundled next to the app's executable (Contents/MacOS/atrium-memory), when present.
    static var bundledExecutable: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: serverName),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The rule that stops direct file edits inside the vault. Claude permission rules write an absolute path with a
    /// leading "//", so a path that starts with "/" gets one more.
    static func vaultEditRule(_ vault: URL) -> String { "Edit(/" + vault.path + "/**)" }

    static func serverEntry(executable: String, vault: URL, actor: String) -> [String: Any] {
        ["command": executable, "args": ["mcp"],
         "env": ["ATRIUM_MEMORY_PATH": vault.path, "ATRIUM_MEMORY_ACTOR": actor]]
    }

    enum Change: Equatable { case added, repaired, unchanged }

    /// Makes sure the agent's .mcp.json has the atrium-memory server. Adds it when missing. An entry the app wrote
    /// always follows the running app and the current vault: its command becomes `executable` and its
    /// ATRIUM_MEMORY_PATH becomes `vault`, whichever differs; every other key is kept. Any other entry is left as it is.
    @discardableResult
    static func connectServer(_ agent: AgentProfile, executable: String, vault: URL) throws -> Change {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentEnvironment.Failure(message: "\(agent.name)'s .mcp.json is not a JSON object, so the Memory Vault tools were not added.")
            }
            config = object
        }
        guard var servers = (config["mcpServers"] ?? [String: Any]()) as? [String: Any] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .mcp.json has a mcpServers value that is not an object, so the Memory Vault tools were not added.")
        }
        let change: Change
        if let existing = servers[serverName] {
            guard var entry = existing as? [String: Any], isAppWritten(entry) else { return .unchanged }
            var env = entry["env"] as? [String: Any] ?? [:]
            guard entry["command"] as? String != executable || env["ATRIUM_MEMORY_PATH"] as? String != vault.path else { return .unchanged }
            entry["command"] = executable
            env["ATRIUM_MEMORY_PATH"] = vault.path
            entry["env"] = env
            servers[serverName] = entry
            change = .repaired
        } else {
            servers[serverName] = serverEntry(executable: executable, vault: vault, actor: agent.name)
            change = .added
        }
        config["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
        return change
    }

    /// An entry the app wrote: run as `<…>/atrium-memory mcp`. Entries the user changed don't match, so they're never touched.
    static func isAppWritten(_ entry: [String: Any]) -> Bool {
        (entry["args"] as? [String]) == ["mcp"] && ((entry["command"] as? String)?.hasSuffix("/" + serverName) ?? false)
    }

    /// The vault an app-written entry points at, or nil when there is no such entry (or the file is unusable;
    /// connectServer reports that). A read error propagates.
    static func appWrittenVault(_ agent: AgentProfile) throws -> String? {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any], isAppWritten(entry),
              let env = entry["env"] as? [String: Any] else { return nil }
        return env["ATRIUM_MEMORY_PATH"] as? String
    }

    /// Whether the agent's .mcp.json lists the atrium-memory server.
    static func isConnected(_ agent: AgentProfile) -> Bool {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    /// Approves the server (Claude asks before using a project .mcp.json server, and background runs can't ask),
    /// allows its tools, and blocks direct file edits inside the vault. Only adds; existing settings are kept.
    static func connectSettings(_ agent: AgentProfile, vault: URL) throws {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json is not a JSON object, so the Memory Vault tools were not approved.")
            }
            settings = object
        }
        let original = NSDictionary(dictionary: settings)
        guard settings["permissions"] == nil || settings["permissions"] is [String: Any] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json has a permissions value that is not an object, so the Memory Vault tools were not approved.")
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        settings["enabledMcpjsonServers"] = try adding(serverName, to: settings["enabledMcpjsonServers"], in: agent)
        permissions["allow"] = try adding(toolPermission, to: permissions["allow"], in: agent)
        permissions["deny"] = try adding(vaultEditRule(vault), to: permissions["deny"], in: agent)
        settings["permissions"] = permissions
        guard NSDictionary(dictionary: settings) != original else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The file is rewritten with sorted keys and pretty-printing; only the three lists above change.
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    private static func adding(_ value: String, to list: Any?, in agent: AgentProfile) throws -> [String] {
        guard list == nil || list is [String] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json has a permission list that is not a list of strings, so the Memory Vault tools were not approved.")
        }
        var items = list as? [String] ?? []
        if !items.contains(value) { items.append(value) }
        return items
    }

    static func instructionsSection(vault: URL) -> String {
        """

        ## Memory Vault tools
        \(instructionsMarker)
        The Memory Vault at `\(vault.path)` is reached through the `atrium-memory` tools, which are built into ClaudeDesk. Use them instead of reading or editing vault files directly; direct edits in the vault are blocked.
        - Find notes: start from Home and follow the maps with `vault_read` (it returns each note's links), or use `vault_search`.
        - Change notes: `vault_read` first and keep its `version`. Then use `vault_edit` for one passage, `vault_append` to add to the end, or `vault_write` to create a note (no version) or replace a whole note (with the version).
        - On `stale_version`, the note changed since you read it: read it again, merge your change, and retry. On `exists`, read the note and update it instead.
        - `vault_list` lists a folder's notes, and `vault_backlinks` shows which notes link to one.
        - The vault checker still runs with `python3 \(vault.path)/.tools/vault_check.py`.

        """
    }

    /// Appends the Memory Vault tools section to CLAUDE.md once; the rest of the file is kept.
    static func connectInstructions(_ agent: AgentProfile, vault: URL) throws {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            text = try String(contentsOf: url, encoding: .utf8)   // an unreadable file throws; it is never overwritten
        }
        guard !text.contains(instructionsMarker) else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += instructionsSection(vault: vault)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Moves the deny rule the app added for `old` to `new`, in the same position. If the user removed the old rule,
    /// nothing is added. Nothing is written when nothing changes.
    static func migrateSettings(_ agent: AgentProfile, from old: URL, to new: URL) throws {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json is not a JSON object, so the edit rule was not moved to the new vault.")
        }
        guard let rawPermissions = settings["permissions"] else { return }
        guard var permissions = rawPermissions as? [String: Any] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json has a permissions value that is not an object, so the edit rule was not moved to the new vault.")
        }
        guard let rawDeny = permissions["deny"] else { return }
        guard var deny = rawDeny as? [String] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json has a permission list that is not a list of strings, so the edit rule was not moved to the new vault.")
        }
        let oldRule = vaultEditRule(old), newRule = vaultEditRule(new)
        guard let index = deny.firstIndex(of: oldRule) else { return }
        if deny.contains(newRule) { deny.remove(at: index) } else { deny[index] = newRule }
        permissions["deny"] = deny
        settings["permissions"] = permissions
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    /// Swaps the section the app wrote for `old` with the one for `new`. A section the user edited is left alone.
    static func migrateInstructions(_ agent: AgentProfile, from old: URL, to new: URL) throws {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let oldSection = instructionsSection(vault: old)
        guard let range = text.range(of: oldSection) else { return }
        try text.replacingCharacters(in: range, with: instructionsSection(vault: new))
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Connects an agent. The server entry is checked every time, so a moved app or a changed workspace is followed;
    /// when the vault changed, the deny rule and CLAUDE.md section the app added for the old vault move too. Settings
    /// and instructions are otherwise added only the first time, so the user's later edits are respected.
    /// The migration runs before the entry is rewritten: if it fails, the entry still names the old vault and the
    /// next launch tries again (the migration is safe to repeat).
    @discardableResult
    static func connect(_ agent: AgentProfile, executable: URL, vault: URL, firstTime: Bool) throws -> Change {
        if let previous = try appWrittenVault(agent), previous != vault.path {
            let old = URL(fileURLWithPath: previous)
            try migrateSettings(agent, from: old, to: vault)
            try migrateInstructions(agent, from: old, to: vault)
        }
        let change = try connectServer(agent, executable: executable.path, vault: vault)
        if firstTime {
            try connectSettings(agent, vault: vault)
            try connectInstructions(agent, vault: vault)
        }
        return change
    }

    /// The entry for the user's own Claude sessions (Projects), as JSON to paste into an .mcp.json.
    static func projectConfig(executable: URL, vault: URL) -> String {
        let object: [String: Any] = ["mcpServers": [serverName: serverEntry(executable: executable.path, vault: vault, actor: "project")]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
