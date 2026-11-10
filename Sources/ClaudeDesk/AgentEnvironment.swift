import Foundation

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case projects = "Projects", agents = "Agents", skills = "Skills"
    var id: String { rawValue }
}

struct AgentProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var purpose: String
    var path: String
    var createdAt = Date()
    var project: Project { Project(id: id, name: name, path: path, sessions: [], agentID: id) }
    var configPath: String { URL(fileURLWithPath: path).appendingPathComponent(".runtime").path }
}

enum AgentDocument: String, CaseIterable, Identifiable {
    case instructions = "Instructions", memory = "Memory", mcp = "MCP servers", settings = "Settings", localSettings = "Local overrides"
    var id: String { rawValue }
    var file: String {
        switch self {
        case .instructions: return "CLAUDE.md"
        case .memory: return "memory/MEMORY.md"
        case .mcp: return ".mcp.json"
        case .settings: return ".runtime/settings.json"
        case .localSettings: return ".claude/settings.local.json"
        }
    }
    var explanation: String {
        switch self {
        case .instructions: return "Define this agent’s role and working rules. Loaded when a conversation starts."
        case .memory: return "Persistent memory shared by this agent’s conversations. Claude may update this file while working."
        case .mcp: return "MCP servers for this agent. Use a mcpServers object with HTTP or stdio entries. Claude handles trust and authentication."
        case .settings: return "Claude settings for this agent’s private configuration directory, including model, permissions, hooks, and plugins."
        case .localSettings: return "Workspace overrides, plugin enablement, and permissions saved by Claude for this agent. These take precedence over profile settings."
        }
    }
}

enum AgentEnvironment {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func create(name: String, purpose: String, host: URL) throws -> AgentProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure(message: "Give the agent a name.") }
        let manager = FileManager.default
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: host.path, isDirectory: &directory), directory.boolValue else {
            throw Failure(message: "The agent host folder is unavailable. Choose a folder in Settings.")
        }
        let id = UUID()
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let root = host.appendingPathComponent(String(slug.prefix(48)) + "-" + id.uuidString.lowercased())
        let staging = host.appendingPathComponent(".creating-" + id.uuidString)
        let profile = AgentProfile(id: id, name: name, purpose: purpose, path: root.path)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for child in ["memory", "files", ".runtime", ".claude/skills", ".claude/agents"] {
                try manager.createDirectory(at: staging.appendingPathComponent(child), withIntermediateDirectories: true)
            }
            let instructions = """
            # \(name)

            \(purpose)

            ## Working environment
            This directory is your dedicated working environment. Keep your work in files/ unless the user directs otherwise.
            Do not access or change sibling agents' environments unless the user explicitly requests it.

            ## Persistent memory
            Read memory/MEMORY.md at the beginning of each conversation. Maintain concise durable notes there and put detailed topic notes in memory/.
            Save useful preferences, decisions, and ongoing task context when appropriate. Do not save credentials or secrets in memory.
            Memory is shared across this agent's conversations; read the latest file before editing and preserve other sessions' updates.

            @memory/MEMORY.md

            """
            try instructions.write(to: staging.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
            try "# Memory\n\nNo memories recorded yet.\n".write(to: staging.appendingPathComponent("memory/MEMORY.md"), atomically: true, encoding: .utf8)
            try "{\n  \"mcpServers\": {}\n}\n".write(to: staging.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
            let settings: [String: Any] = ["autoMemoryDirectory": root.appendingPathComponent("memory").path]
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent(".runtime/settings.json"), options: .atomic)
            try "{}\n".write(to: staging.appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)
            try JSONEncoder().encode(profile).write(to: staging.appendingPathComponent("agent.json"), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            try manager.moveItem(at: staging, to: root)
            return profile
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    static func documentURL(_ document: AgentDocument, agent: AgentProfile) throws -> URL {
        let root = URL(fileURLWithPath: agent.path).resolvingSymlinksInPath().standardizedFileURL
        var component = root
        for part in document.file.split(separator: "/") {
            component.appendPathComponent(String(part))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw Failure(message: "This document uses a symbolic link. Open it in your own editor to make changes.")
            }
        }
        let url = root.appendingPathComponent(document.file).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw Failure(message: "This file links outside the agent environment. Open it in your own editor to make changes.")
        }
        return url
    }

    static func read(_ document: AgentDocument, agent: AgentProfile) throws -> String {
        try String(contentsOf: documentURL(document, agent: agent), encoding: .utf8)
    }

    static func save(_ text: String, document: AgentDocument, agent: AgentProfile, original: String) throws {
        let url = try documentURL(document, agent: agent)
        guard try String(contentsOf: url, encoding: .utf8) == original else {
            throw Failure(message: "This file changed outside the editor. Your draft is kept here. Copy it if needed, then Reload and merge the latest changes.")
        }
        if document == .mcp || document == .settings || document == .localSettings {
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw Failure(message: "The JSON must contain an object.")
            }
            if document == .mcp {
                guard let servers = object["mcpServers"] as? [String: Any], servers.values.allSatisfy({ $0 is [String: Any] }) else {
                    throw Failure(message: "MCP configuration must contain a mcpServers object with one object per server.")
                }
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let inboxMarker = "<!-- claudedesk:inbox -->"

    /// Connects an agent to the workspace Inbox: allows the folder, adds a CLAUDE.md section, and attaches
    /// the `inbox-instructions` skill. Each step is skipped when already done; nothing else in the files changes.
    static let routinesMarker = "<!-- claudedesk:routines -->"

    static func connectInbox(_ agent: AgentProfile, inbox: URL, inboxSkill: LibrarySkill?, routines: URL? = nil) throws {
        try connectFolders(agent, inbox: inbox, routines: routines)
        try connectInstructions(agent, inbox: inbox, routines: routines)
        if let inboxSkill {
            try SkillLibrary.attach(inboxSkill, to: SkillTarget.agent(agent).skillsDirectory)
        }
    }

    private static func connectFolders(_ agent: AgentProfile, inbox: URL, routines: URL?) throws {
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else {
                throw Failure(message: "\(agent.name)'s .claude/settings.local.json is not a JSON object, so the Inbox folder was not added.")
            }
            settings = object
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var directories = permissions["additionalDirectories"] as? [String] ?? []
        let missing = [inbox.path, routines?.path].compactMap { $0 }.filter { !directories.contains($0) }
        guard !missing.isEmpty else { return }
        directories += missing
        permissions["additionalDirectories"] = directories
        settings["permissions"] = permissions
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: settingsURL, options: .atomic)
    }

    private static func connectInstructions(_ agent: AgentProfile, inbox: URL, routines: URL?) throws {
        let instructionsURL = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")
        var instructions = (try? String(contentsOf: instructionsURL, encoding: .utf8)) ?? ""
        let original = instructions
        func append(_ section: String) {
            if !instructions.isEmpty && !instructions.hasSuffix("\n") { instructions += "\n" }
            instructions += section
        }
        if !instructions.contains(inboxMarker) {
            append("""

            ## Inbox
            \(inboxMarker)
            Send the user non-urgent requests, questions, reports, and proposed skills through the ClaudeDesk Inbox at `\(inbox.path)`, following the `\(SkillLibrary.inboxSkillName)` skill.

            """)
        }
        if let routines, !instructions.contains(routinesMarker) {
            append("""

            ## Routines
            \(routinesMarker)
            Scheduled routines for every agent are defined in `\(routines.appendingPathComponent(Routines.fileName).path)`. Read the `\(SkillLibrary.inboxSkillName)` skill before adding or changing one; new or riskier routines wait for the user's approval.

            """)
        }
        if instructions != original { try instructions.write(to: instructionsURL, atomically: true, encoding: .utf8) }
    }

    static let widgetsMarker = "<!-- claudedesk:widgets -->"

    /// Lets an agent design Cockpit widgets: creates its `widgets/` folder, adds a CLAUDE.md section, and attaches
    /// the `widget-instructions` skill. The folder is inside the agent's own folder, so it can edit only its own widgets.
    static func connectWidgets(_ agent: AgentProfile, widgetSkill: LibrarySkill?) throws {
        let folder = URL(fileURLWithPath: agent.path).appendingPathComponent("widgets")   // AgentWidgets.folderName
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let instructionsURL = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")
        var instructions = (try? String(contentsOf: instructionsURL, encoding: .utf8)) ?? ""
        if !instructions.contains(widgetsMarker) {
            if !instructions.isEmpty && !instructions.hasSuffix("\n") { instructions += "\n" }
            instructions += """

            ## Cockpit widgets
            \(widgetsMarker)
            You design your own widgets on the user's ClaudeDesk Cockpit: one Markdown file per widget in `\(folder.path)`, with images in its `assets/` folder. Follow the `\(SkillLibrary.widgetSkillName)` skill, and keep your widgets current when your work changes what they show.

            """
            try instructions.write(to: instructionsURL, atomically: true, encoding: .utf8)
        }
        if let widgetSkill { try SkillLibrary.attach(widgetSkill, to: SkillTarget.agent(agent).skillsDirectory) }
    }

    /// Appends approved text to the agent's memory/MEMORY.md under a heading, keeping everything already there.
    static func appendMemory(_ text: String, to agent: AgentProfile, heading: String) throws {
        let url = try documentURL(.memory, agent: agent)
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Memory\n"
        let addition = "\n## \(heading)\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try (current + (current.hasSuffix("\n") ? "" : "\n") + addition).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes CLAUDE* variables inherited from whatever launched ClaudeDesk. When the app is opened from a
    /// running Claude session, they would make every pane a nested child of that session (bare mode, no
    /// saved transcripts). Panes start through a login shell, so the user's own profile settings return.
    static func withoutInheritedClaudeVariables(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("CLAUDE") }
    }

    static func environment(for agent: AgentProfile) -> [String: String] {
        ["CLAUDE_CONFIG_DIR": agent.configPath, "CLAUDE_CODE_PROJECT_DIR_NAME": "agent"]
    }
}
