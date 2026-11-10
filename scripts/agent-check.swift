import Foundation

@main
struct AgentChecks {
    static func main() throws {
        let host = FileManager.default.temporaryDirectory.appendingPathComponent("claudedesk-agent-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: host) }
        let first = try AgentEnvironment.create(name: "../Test Agent", purpose: "Help with research", host: host)
        let second = try AgentEnvironment.create(name: "../Test Agent", purpose: "Help with planning", host: host)
        precondition(first.path != second.path && first.configPath != second.configPath)
        precondition(URL(fileURLWithPath: first.path).deletingLastPathComponent().path == host.path)
        precondition(first.project.agentID == first.id)
        for file in AgentDocument.allCases { _ = try AgentEnvironment.read(file, agent: first) }
        let settings = try JSONSerialization.jsonObject(with: Data(AgentEnvironment.read(.settings, agent: first).utf8)) as! [String: Any]
        precondition(settings["autoMemoryDirectory"] as? String == first.path + "/memory")
        precondition(AgentEnvironment.environment(for: first)["CLAUDE_CONFIG_DIR"] == first.configPath)
        let memory = try AgentEnvironment.read(.memory, agent: first)
        try AgentEnvironment.save("# A durable memory\n", document: .memory, agent: first, original: memory)
        let secondMemory = try AgentEnvironment.read(.memory, agent: second)
        precondition(secondMemory == memory)
        do {
            try AgentEnvironment.save("stale overwrite", document: .memory, agent: first, original: memory)
            fatalError("Concurrent edits should be rejected")
        } catch is AgentEnvironment.Failure {}
        let mcp = try AgentEnvironment.read(.mcp, agent: first)
        for invalid in ["not JSON", "[]", "{\"mcpServers\": []}", "{\"mcpServers\": {\"bad\": 1}}"] {
            do {
                try AgentEnvironment.save(invalid, document: .mcp, agent: first, original: mcp)
                fatalError("Invalid MCP JSON should be rejected")
            } catch {}
        }
        let preservedMCP = try AgentEnvironment.read(.mcp, agent: first)
        precondition(preservedMCP == mcp)
        let valid = "{\"mcpServers\": {\"example\": {\"type\": \"http\", \"url\": \"https://example.com/mcp\"}}}"
        try AgentEnvironment.save(valid, document: .mcp, agent: first, original: mcp)
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(first))
        precondition(decoded == first)
        let oldProject = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old repo\",\"path\":\"/tmp/repo\",\"sessions\":[]}"
        let legacy = try JSONDecoder().decode(Project.self, from: Data(oldProject.utf8))
        precondition(legacy.agentID == nil)
        let instructionURL = URL(fileURLWithPath: first.path).appendingPathComponent("CLAUDE.md")
        try FileManager.default.removeItem(at: instructionURL)
        try FileManager.default.createSymbolicLink(at: instructionURL, withDestinationURL: host.appendingPathComponent("outside.md"))
        do {
            _ = try AgentEnvironment.documentURL(.instructions, agent: first)
            fatalError("External symlink should be rejected")
        } catch is AgentEnvironment.Failure {}
        let workspace = host.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let template = URL(fileURLWithPath: "Resources/VaultTemplate")
        try Workspace.prepare(root: workspace, vaultTemplate: template)
        let vault = Workspace.vault(in: workspace)
        for folder in [Workspace.agents(in: workspace), Workspace.skills(in: workspace)] + Workspace.vaultFolders.map({ vault.appendingPathComponent($0) }) {
            precondition(FileManager.default.fileExists(atPath: folder.path), "missing \(folder.path)")
        }
        precondition(FileManager.default.fileExists(atPath: vault.appendingPathComponent(".tools/vault_check.py").path))
        let framework = try String(contentsOf: vault.appendingPathComponent("Notes/Second-Brain-Framework.md"), encoding: .utf8)
        precondition(framework.contains("Vault: `\(vault.path)`") && !framework.contains("{{VAULT_PATH}}"))
        let home = vault.appendingPathComponent("Home.md")
        try "# My own home\n".write(to: home, atomically: true, encoding: .utf8)
        try Workspace.prepare(root: workspace, vaultTemplate: template)
        let homeAfter = try String(contentsOf: home, encoding: .utf8)
        precondition(homeAfter == "# My own home\n", "an existing vault must not be changed")
        let contents = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        precondition(!contents.contains { $0.hasPrefix(".creating-vault-") }, "staging folder left behind")
        do {
            try Workspace.prepare(root: host.appendingPathComponent("missing"), vaultTemplate: template)
            fatalError("A missing workspace folder should be rejected")
        } catch is AgentEnvironment.Failure {}
        precondition(Workspace.migrationSuggestion(forAgentHost: "/a/BrainHub/agent_brain") == "/a/BrainHub")
        precondition(Workspace.migrationSuggestion(forAgentHost: "/a/MyAgents") == "/a/MyAgents")
        print("Passed: unique agent environments, contained paths, per-agent memory/config, persistence, legacy project migration, JSON validation, concurrent edit protection, symlink containment, workspace setup and migration suggestion.")
    }
}
