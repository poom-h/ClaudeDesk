import Foundation

/// The user's workspace folder and the standard folders ClaudeDesk keeps inside it.
enum Workspace {
    static let agentsFolder = "agent_brain"
    static let vaultFolder = "MemoryVault"
    static let skillsFolder = "skill_library"
    static let vaultFolders = ["Inbox", "Notes", "Maps", "Assets", "Archive"]

    static func agents(in root: URL) -> URL { root.appendingPathComponent(agentsFolder) }
    static func vault(in root: URL) -> URL { root.appendingPathComponent(vaultFolder) }
    static func skills(in root: URL) -> URL { root.appendingPathComponent(skillsFolder) }
    static func inbox(in root: URL) -> URL { root.appendingPathComponent("inbox") }
    static func logs(in root: URL) -> URL { root.appendingPathComponent("logs") }

    static var bundledVaultTemplate: URL? { Bundle.main.url(forResource: "VaultTemplate", withExtension: nil) }
    static var bundledSkills: URL? { Bundle.main.url(forResource: "SkillTemplates", withExtension: nil) }

    /// Creates whichever standard folders are missing. Existing folders and their files are never changed.
    static func prepare(root: URL, vaultTemplate: URL?, skillTemplates: URL? = nil) throws {
        let manager = FileManager.default
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw AgentEnvironment.Failure(message: "The workspace folder is unavailable: \(root.path)")
        }
        for folder in [agents(in: root), skills(in: root), inbox(in: root), Inbox.archive(in: inbox(in: root)), logs(in: root)]
        where !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for folder in [Routines.folder(in: root), Routines.queue(in: root), Routines.runs(in: root)] where !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if !manager.fileExists(atPath: Routines.file(in: root).path) {
            try Routines.template.write(to: Routines.file(in: root), atomically: true, encoding: .utf8)
        }
        // Skills the app relies on, such as `inbox-instructions`, are added once; later edits in the library are kept.
        if let templates = skillTemplates {
            for name in (try? manager.contentsOfDirectory(atPath: templates.path)) ?? [] where !name.hasPrefix(".") {
                let destination = skills(in: root).appendingPathComponent(name)
                if !manager.fileExists(atPath: destination.path) {
                    try manager.copyItem(at: templates.appendingPathComponent(name), to: destination)
                }
            }
        }
        let vault = vault(in: root)
        guard !manager.fileExists(atPath: vault.path) else { return }
        // Build the vault beside its destination and move it into place once complete.
        let staging = root.appendingPathComponent(".creating-vault-" + UUID().uuidString)
        do {
            if let template = vaultTemplate {
                try manager.copyItem(at: template, to: staging)
                try fillPlaceholders(in: staging, vaultPath: vault.path)
            } else {
                try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            }
            for folder in vaultFolders {
                try manager.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            try manager.moveItem(at: staging, to: vault)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// The workspace to suggest for a setup that only recorded an agent host folder.
    static func migrationSuggestion(forAgentHost path: String) -> String {
        let host = URL(fileURLWithPath: path)
        return host.lastPathComponent == agentsFolder ? host.deletingLastPathComponent().path : host.path
    }

    private static func fillPlaceholders(in folder: URL, vaultPath: String) throws {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension == "md" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("{{VAULT_PATH}}") {
                try text.replacingOccurrences(of: "{{VAULT_PATH}}", with: vaultPath).write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}
