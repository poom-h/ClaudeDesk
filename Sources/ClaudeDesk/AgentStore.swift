import AppKit
import SwiftUI

extension DeskStore {
    private var agentsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeDesk/agents.json")
    }

    func loadAgents() {
        guard FileManager.default.fileExists(atPath: agentsFile.path) else { return }
        do {
            agents = try JSONDecoder().decode([AgentProfile].self, from: Data(contentsOf: agentsFile))
            selectedAgentID = agents.first?.id
        } catch {
            canSaveAgents = false
            self.error = "Could not read agent registry. The original file is preserved at \(agentsFile.path). \(error.localizedDescription)"
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as workspace"
        panel.message = "ClaudeDesk keeps agents, the memory vault, and the skill library here. Missing folders are created; existing ones are not changed."
        let current = workspacePath.isEmpty ? workspaceMigration ?? legacyAgentHostPath : workspacePath
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useWorkspace(url.path)
    }

    /// Adopts a workspace folder, creating its missing standard folders. Existing agents keep their saved paths.
    func useWorkspace(_ path: String) {
        do {
            try Workspace.prepare(root: URL(fileURLWithPath: path), vaultTemplate: Workspace.bundledVaultTemplate, skillTemplates: Workspace.bundledSkills)
            let migrated = workspaceMigration != nil
            workspacePath = path
            UserDefaults.standard.set(path, forKey: "workspacePath")
            workspaceMigration = nil
            log(migrated ? "workspace.migrated" : "workspace.set", subject: path)
            startWorkspaceServices()
        } catch { self.error = "Could not set up the workspace: \(error.localizedDescription)" }
    }

    func declineWorkspaceMigration() {
        workspaceMigration = nil
        UserDefaults.standard.set(true, forKey: "workspaceMigrationDeclined")
    }

    @discardableResult
    func createAgent(name: String, purpose: String) -> Bool {
        guard !agentHostPath.isEmpty else {
            error = "Choose a workspace folder in Settings first."
            return false
        }
        if !workspacePath.isEmpty && !FileManager.default.fileExists(atPath: agentHostPath) {
            try? FileManager.default.createDirectory(atPath: agentHostPath, withIntermediateDirectories: false)
        }
        guard canSaveAgents else {
            error = "Fix the unreadable agents.json registry before creating another agent."
            return false
        }
        do {
            let agent = try AgentEnvironment.create(name: name, purpose: purpose, host: URL(fileURLWithPath: agentHostPath))
            agents.append(agent)
            selectedAgentID = agent.id
            showTerminals = false
            try saveAgents()
            log("agent.created", subject: agent.name, details: ["agent": agent.id.uuidString, "path": agent.path])
            connectAgentsToInbox()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func saveAgents() throws {
        guard canSaveAgents else { throw AgentEnvironment.Failure(message: "The agent registry could not be loaded.") }
        try FileManager.default.createDirectory(at: agentsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(agents).write(to: agentsFile, options: .atomic)
    }

    @discardableResult
    func launchAgent(_ agent: AgentProfile, title: String? = nil, arguments: [String] = [], actor: String = "user") -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agent.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.fileExists(atPath: agent.configPath) else {
            error = "The agent environment is unavailable at \(agent.path). Restore its folder before opening a conversation."
            return false
        }
        guard let executable = resolveExecutable(UserDefaults.standard.string(forKey: "claudeExecutable") ?? "") else { return false }
        // New conversations get an ID assigned up front; resumed ones keep the ID they were opened with.
        var arguments = arguments
        var sessionID: String?
        if arguments.isEmpty || arguments.first == "--" {
            let assigned = UUID().uuidString.lowercased()
            arguments = ["--session-id", assigned] + arguments
            sessionID = assigned
        } else if let index = arguments.firstIndex(of: "--resume"), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
            sessionID = arguments[index + 1]
        }
        let terminal = RunningTerminal(project: agent.project, session: DeskSession(name: title ?? agent.name), sessionID: sessionID)
        terminals.append(terminal)
        terminal.start(executable: executable, arguments: arguments, environmentOverrides: AgentEnvironment.environment(for: agent))
        let resumed = arguments.contains("--resume") || arguments.contains("--continue")
        track(terminal, type: resumed ? "conversation.resumed" : "conversation.started", actor: actor,
              details: ["agent": agent.id.uuidString, "title": title ?? agent.name, "session": sessionID ?? ""])
        mode = .agents
        showInbox = false
        showTerminals = true
        return terminal.running
    }
}
