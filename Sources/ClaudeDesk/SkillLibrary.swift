import Foundation

struct LibrarySkill: Identifiable, Hashable {
    let name: String
    let description: String
    let url: URL
    var id: String { name }
    var file: URL { url.appendingPathComponent("SKILL.md") }
}

struct SkillProposal: Identifiable, Hashable {
    let agent: AgentProfile
    let name: String
    let description: String
    let url: URL
    var id: String { agent.id.uuidString + "/" + name }
}

/// Where a library skill can be attached. Each target has a skills folder that holds one symlink per attached skill.
enum SkillTarget: Hashable, Identifiable {
    case global, agent(AgentProfile), project(Project)

    var id: String {
        switch self {
        case .global: return "global"
        case .agent(let agent): return "agent:" + agent.id.uuidString
        case .project(let project): return "project:" + project.id.uuidString
        }
    }
    var label: String {
        switch self {
        case .global: return "Global (normal Claude sessions)"
        case .agent(let agent): return agent.name
        case .project(let project): return project.name
        }
    }
    var skillsDirectory: URL {
        switch self {
        case .global: return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills")
        case .agent(let agent): return URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/skills")
        case .project(let project): return URL(fileURLWithPath: project.path).appendingPathComponent(".claude/skills")
        }
    }
    /// Projects are repositories: attached links are listed in the repo's .gitignore.
    var repository: URL? { if case .project(let project) = self { return URL(fileURLWithPath: project.path) }; return nil }
}

enum SkillLibrary {
    typealias Failure = AgentEnvironment.Failure
    enum Attachment { case attached, detached, conflict }

    static let proposalsFolder = "skills-proposed"
    /// The bundled skill that teaches agents how to use the Inbox.
    static let inboxSkillName = "inbox-instructions"
    /// The bundled skill that teaches agents to design their own Cockpit widgets.
    static let widgetSkillName = "widget-instructions"

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    }

    static func list(library: URL) -> [LibrarySkill] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        return names.sorted().compactMap { name in
            let url = library.appendingPathComponent(name)
            guard !name.hasPrefix("."), FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else { return nil }
            return LibrarySkill(name: name, description: description(of: url), url: url)
        }
    }

    static func description(of skillFolder: URL) -> String {
        guard let text = try? String(contentsOf: skillFolder.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return "" }
        return Frontmatter.parse(text).text("description") ?? ""
    }

    static func create(name: String, description: String, library: URL) throws -> LibrarySkill {
        guard isValidName(name) else { throw Failure(message: "Skill names use lowercase letters, numbers, and hyphens, such as daily-news.") }
        let folder = library.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw Failure(message: "A skill named \(name) already exists in the library.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let summary = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = """
        ---
        name: \(name)
        description: \(Frontmatter.quote(summary.isEmpty ? "Describe when Claude should use this skill." : summary))
        ---

        # \(name)

        Write the steps Claude should follow when this skill applies.

        """
        try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return LibrarySkill(name: name, description: summary, url: folder)
    }

    static func read(_ skill: LibrarySkill) throws -> String {
        try String(contentsOf: skill.file, encoding: .utf8)
    }

    /// Saves SKILL.md only if nobody changed it since `original` was read.
    static func save(_ text: String, skill: LibrarySkill, original: String) throws {
        guard try read(skill) == original else {
            throw Failure(message: "SKILL.md changed outside the editor. Your draft is kept here. Copy it if needed, then Reload.")
        }
        try text.write(to: skill.file, atomically: true, encoding: .utf8)
    }

    static func attachment(of skill: LibrarySkill, in directory: URL) -> Attachment {
        let link = directory.appendingPathComponent(skill.name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: link.path) else { return .detached }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return .conflict }
        let resolved = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved == skill.url.standardizedFileURL.resolvingSymlinksInPath().path ? .attached : .conflict
    }

    static func attach(_ skill: LibrarySkill, to directory: URL, repository: URL? = nil) throws {
        switch attachment(of: skill, in: directory) {
        case .attached: return
        case .conflict: throw Failure(message: "\(directory.path) already has a different skill named \(skill.name). Rename or remove it first.")
        case .detached: break
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(skill.name), withDestinationURL: skill.url)
        if let repository { try ignore(".claude/skills/" + skill.name, in: repository) }
    }

    /// Removes the link only when it points at this library skill; real folders are never deleted.
    static func detach(_ skill: LibrarySkill, from directory: URL) throws {
        switch attachment(of: skill, in: directory) {
        case .detached: return
        case .conflict: throw Failure(message: "\(directory.appendingPathComponent(skill.name).path) is not a link to the library, so it was left alone.")
        case .attached: try FileManager.default.removeItem(at: directory.appendingPathComponent(skill.name))
        }
    }

    static func ignore(_ entry: String, in repository: URL) throws {
        let file = repository.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(entry), !lines.contains("/" + entry) else { return }
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n"
        try (prefix + entry + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func proposals(agents: [AgentProfile]) -> [SkillProposal] {
        agents.flatMap { agent -> [SkillProposal] in
            let folder = URL(fileURLWithPath: agent.path).appendingPathComponent(proposalsFolder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.sorted().compactMap { name in
                let url = folder.appendingPathComponent(name)
                guard !name.hasPrefix("."), FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else { return nil }
                return SkillProposal(agent: agent, name: name, description: description(of: url), url: url)
            }
        }
    }

    /// Moves `<agent>/skills-proposed/<name>` into the library and attaches it to the agent.
    @discardableResult
    static func approve(_ name: String, from agent: AgentProfile, library: URL) throws -> LibrarySkill {
        guard isValidName(name) else { throw Failure(message: "The proposed skill name \"\(name)\" is not a valid skill name.") }
        let manager = FileManager.default
        let root = URL(fileURLWithPath: agent.path).resolvingSymlinksInPath().standardizedFileURL
        let proposed = root.appendingPathComponent(proposalsFolder).appendingPathComponent(name)
        for path in [root.appendingPathComponent(proposalsFolder), proposed] {
            if (try? manager.attributesOfItem(atPath: path.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw Failure(message: "The proposed skill uses a symbolic link, so it was not imported.")
            }
        }
        guard manager.fileExists(atPath: proposed.appendingPathComponent("SKILL.md").path) else {
            throw Failure(message: "\(agent.name) has no proposed skill at \(proposed.path).")
        }
        if let files = manager.enumerator(at: proposed, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in files where (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw Failure(message: "The proposed skill contains a symbolic link (\(file.lastPathComponent)), so it was not imported.")
            }
        }
        let destination = library.appendingPathComponent(name)
        guard !manager.fileExists(atPath: destination.path) else {
            throw Failure(message: "The library already has a skill named \(name). Ask \(agent.name) to rename the proposal.")
        }
        try manager.createDirectory(at: library, withIntermediateDirectories: true)
        try manager.moveItem(at: proposed, to: destination)
        let skill = LibrarySkill(name: name, description: description(of: destination), url: destination)
        try attach(skill, to: SkillTarget.agent(agent).skillsDirectory)
        return skill
    }
}
