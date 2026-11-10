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

    /// Makes sure the agent's .mcp.json has the atrium-memory server. Adds it when missing. When the app wrote it and
    /// its command no longer exists (the app was moved), points it at `executable`. Anything else is left as it is.
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
            guard var entry = existing as? [String: Any], isAppWritten(entry),
                  let command = entry["command"] as? String, command != executable,
                  !FileManager.default.fileExists(atPath: command) else { return .unchanged }
            entry["command"] = executable
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

    /// Whether the agent's .mcp.json lists the atrium-memory server.
    static func isConnected(_ agent: AgentProfile) -> Bool {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }
}
