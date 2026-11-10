import Foundation

@main
struct SkillsInboxChecks {
    static func expectFailure(_ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected failure: \(label)") } catch {}
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("claudedesk-skills-inbox-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        // Front matter
        let sample = """
        ---
        kind: request
        from: atlas-123
        title: "Archive notes: AWS?"
        choices: [Archive all, "Keep, for now"]
        on_approve:
          - resume: "Chose {choice} {reply}. Continue."
          - new-conversation: Tidy the maps
        on_reject:
          - launch-rockets: now
        ---
        Body text.
        """
        let parsed = Frontmatter.parse(sample)
        precondition(parsed.text("title") == "Archive notes: AWS?")
        precondition(parsed.fields["choices"]?.items == [.text("Archive all"), .text("Keep, for now")])
        precondition(parsed.fields["on_approve"]?.items == [.pair("resume", "Chose {choice} {reply}. Continue."), .pair("new-conversation", "Tidy the maps")])
        precondition(parsed.body == "Body text.")
        let updated = Frontmatter.setting([("status", "approved"), ("reason", "Not now: later")], in: sample)
        let reparsed = Frontmatter.parse(updated)
        precondition(reparsed.text("status") == "approved" && reparsed.text("reason") == "Not now: later" && reparsed.text("kind") == "request")
        precondition(reparsed.fields["on_approve"]?.items.count == 2, "setting a key must keep other lists")
        let replaced = Frontmatter.parse(Frontmatter.setting([("status", "done")], in: Frontmatter.setting([("status", "x")], in: sample)))
        precondition(replaced.text("status") == "done")
        precondition(Frontmatter.unquote(Frontmatter.quote("a \"b\": c\\d")) == "a \"b\": c\\d")

        // Workspace with bundled skills
        let workspace = root.appendingPathComponent("ws")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false)
        let templates = URL(fileURLWithPath: "Resources/SkillTemplates")
        try Workspace.prepare(root: workspace, vaultTemplate: nil, skillTemplates: templates)
        let library = Workspace.skills(in: workspace)
        let inbox = Workspace.inbox(in: workspace)
        for folder in [inbox, Inbox.archive(in: inbox), Workspace.logs(in: workspace)] { precondition(manager.fileExists(atPath: folder.path)) }
        let inboxSkillFile = library.appendingPathComponent("inbox-instructions/SKILL.md")
        let bundled = try String(contentsOf: inboxSkillFile, encoding: .utf8)
        precondition(Frontmatter.parse(bundled).text("name") == SkillLibrary.inboxSkillName)
        try "custom".write(to: inboxSkillFile, atomically: true, encoding: .utf8)
        try Workspace.prepare(root: workspace, vaultTemplate: nil, skillTemplates: templates)
        let keptSkill = try String(contentsOf: inboxSkillFile, encoding: .utf8)
        precondition(keptSkill == "custom", "bundled skills must not overwrite library edits")
        try manager.removeItem(at: library.appendingPathComponent(SkillLibrary.inboxSkillName))
        try Workspace.prepare(root: workspace, vaultTemplate: nil, skillTemplates: templates)

        // Library: create, list, edit
        expectFailure("invalid name") { _ = try SkillLibrary.create(name: "Bad Name", description: "", library: library) }
        let news = try SkillLibrary.create(name: "daily-news", description: "Summarize news: daily", library: library)
        expectFailure("duplicate name") { _ = try SkillLibrary.create(name: "daily-news", description: "", library: library) }
        precondition(SkillLibrary.list(library: library).map(\.name) == ["daily-news", "inbox-instructions", "widget-instructions"])
        precondition(SkillLibrary.list(library: library).first?.description == "Summarize news: daily")
        let original = try SkillLibrary.read(news)
        try SkillLibrary.save(original + "More.\n", skill: news, original: original)
        expectFailure("stale skill save") { try SkillLibrary.save("lost", skill: news, original: original) }

        // Attach and detach
        let agentA = try AgentEnvironment.create(name: "Agent A", purpose: "", host: Workspace.agents(in: workspace))
        let agentB = try AgentEnvironment.create(name: "Agent B", purpose: "", host: Workspace.agents(in: workspace))
        let dirA = SkillTarget.agent(agentA).skillsDirectory
        precondition(SkillLibrary.attachment(of: news, in: dirA) == .detached)
        try SkillLibrary.attach(news, to: dirA)
        try SkillLibrary.attach(news, to: dirA)
        precondition(SkillLibrary.attachment(of: news, in: dirA) == .attached)
        precondition(manager.fileExists(atPath: dirA.appendingPathComponent("daily-news/SKILL.md").path))
        try SkillLibrary.detach(news, from: dirA)
        precondition(SkillLibrary.attachment(of: news, in: dirA) == .detached)
        precondition(manager.fileExists(atPath: news.file.path), "detaching must keep the library copy")
        let dirB = SkillTarget.agent(agentB).skillsDirectory
        try manager.createDirectory(at: dirB.appendingPathComponent("daily-news"), withIntermediateDirectories: true)
        precondition(SkillLibrary.attachment(of: news, in: dirB) == .conflict)
        expectFailure("attach over a real folder") { try SkillLibrary.attach(news, to: dirB) }
        expectFailure("detach a real folder") { try SkillLibrary.detach(news, from: dirB) }
        precondition(manager.fileExists(atPath: dirB.appendingPathComponent("daily-news").path))

        // Project attach records the link in .gitignore once
        let repo = root.appendingPathComponent("repo")
        try manager.createDirectory(at: repo, withIntermediateDirectories: true)
        try "node_modules".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let project = SkillTarget.project(Project(name: "repo", path: repo.path))
        try SkillLibrary.attach(news, to: project.skillsDirectory, repository: project.repository)
        try SkillLibrary.detach(news, from: project.skillsDirectory)
        try SkillLibrary.attach(news, to: project.skillsDirectory, repository: project.repository)
        let gitignore = try String(contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8)
        precondition(gitignore == "node_modules\n.claude/skills/daily-news\n")

        // Proposals
        let proposals = URL(fileURLWithPath: agentA.path).appendingPathComponent(SkillLibrary.proposalsFolder)
        try manager.createDirectory(at: proposals.appendingPathComponent("vault-tidy"), withIntermediateDirectories: true)
        try "---\nname: vault-tidy\ndescription: Tidy maps\n---\n".write(to: proposals.appendingPathComponent("vault-tidy/SKILL.md"), atomically: true, encoding: .utf8)
        precondition(SkillLibrary.proposals(agents: [agentA, agentB]).map(\.name) == ["vault-tidy"])
        let approved = try SkillLibrary.approve("vault-tidy", from: agentA, library: library)
        precondition(!manager.fileExists(atPath: proposals.appendingPathComponent("vault-tidy").path))
        precondition(SkillLibrary.attachment(of: approved, in: dirA) == .attached && approved.description == "Tidy maps")
        try manager.createDirectory(at: proposals.appendingPathComponent("daily-news"), withIntermediateDirectories: true)
        try "x".write(to: proposals.appendingPathComponent("daily-news/SKILL.md"), atomically: true, encoding: .utf8)
        expectFailure("approve over an existing library skill") { try SkillLibrary.approve("daily-news", from: agentA, library: library) }
        try manager.createDirectory(at: proposals.appendingPathComponent("sneaky"), withIntermediateDirectories: true)
        try "x".write(to: proposals.appendingPathComponent("sneaky/SKILL.md"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: proposals.appendingPathComponent("sneaky/secret"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        expectFailure("proposal containing a symlink") { try SkillLibrary.approve("sneaky", from: agentA, library: library) }
        try manager.createSymbolicLink(at: proposals.appendingPathComponent("elsewhere"), withDestinationURL: root)
        expectFailure("proposal that is a symlink") { try SkillLibrary.approve("elsewhere", from: agentA, library: library) }
        expectFailure("missing proposal") { try SkillLibrary.approve("missing", from: agentA, library: library) }

        // Connecting agents to the Inbox is idempotent and keeps existing settings
        let settingsURL = URL(fileURLWithPath: agentA.path).appendingPathComponent(".claude/settings.local.json")
        try "{\"permissions\": {\"allow\": [\"Read\"]}, \"keep\": true}".write(to: settingsURL, atomically: true, encoding: .utf8)
        let inboxSkill = SkillLibrary.list(library: library).first { $0.name == SkillLibrary.inboxSkillName }
        try AgentEnvironment.connectInbox(agentA, inbox: inbox, inboxSkill: inboxSkill)
        try AgentEnvironment.connectInbox(agentA, inbox: inbox, inboxSkill: inboxSkill)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        let permissions = settings["permissions"] as! [String: Any]
        precondition(permissions["additionalDirectories"] as? [String] == [inbox.path] && permissions["allow"] as? [String] == ["Read"] && settings["keep"] as? Bool == true)
        let claude = try String(contentsOf: URL(fileURLWithPath: agentA.path).appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        precondition(claude.components(separatedBy: AgentEnvironment.inboxMarker).count == 2 && claude.contains("# Agent A"))
        precondition(SkillLibrary.attachment(of: inboxSkill!, in: dirA) == .attached)
        try "[]".write(to: URL(fileURLWithPath: agentB.path).appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)
        expectFailure("non-object settings") { try AgentEnvironment.connectInbox(agentB, inbox: inbox, inboxSkill: inboxSkill) }

        // Inbox items
        let good = inbox.appendingPathComponent("2026-10-23-agent-a-question.md")
        try sample.write(to: good, atomically: true, encoding: .utf8)
        try "no properties".write(to: inbox.appendingPathComponent("2026-10-23-raw.md"), atomically: true, encoding: .utf8)
        try "---\nkind: memory\nfrom: a\n---\n".write(to: inbox.appendingPathComponent("2026-10-23-later.md"), atomically: true, encoding: .utf8)
        try "---\nkind: skill\nfrom: a\n---\n".write(to: inbox.appendingPathComponent("2026-10-23-noskill.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: inbox.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let items = Inbox.load(inbox)
        precondition(items.count == 4, "only .md files in the inbox root are items")
        let item = items.first { $0.id == good.lastPathComponent }!
        precondition(item.problem == nil && item.kind == "request" && item.choices == ["Archive all", "Keep, for now"])
        precondition(item.onApprove.map(\.isKnown) == [true, true] && item.onReject.first?.isKnown == false)
        precondition(items.filter { $0.problem != nil }.count == 3)
        precondition(Inbox.fill("Chose {choice} {reply}.", note: "", decision: .choice("Archive all")) == "Chose Archive all .")
        precondition(Inbox.fill("Answer: {reply}", note: "Use the CLI", decision: .reply) == "Answer: Use the CLI")
        precondition(Inbox.fill("Declined: {reason}", note: "too soon", decision: .reject) == "Declined: too soon")
        precondition(Inbox.callbacks(for: item, decision: .reject).count == 1 && Inbox.callbacks(for: item, decision: .done).isEmpty)

        try (sample + "\nEdited.").write(to: good, atomically: true, encoding: .utf8)
        expectFailure("resolve after the file changed") { _ = try Inbox.resolve(item, decision: .approve, note: "") }
        let fresh = Inbox.load(inbox).first { $0.id == good.lastPathComponent }!
        let archived = try Inbox.resolve(fresh, decision: .reject, note: "Not now: later")
        precondition(!manager.fileExists(atPath: good.path) && archived.deletingLastPathComponent().lastPathComponent == "archive")
        let recordText = try String(contentsOf: archived, encoding: .utf8)
        let record = Frontmatter.parse(recordText)
        precondition(record.text("status") == "rejected" && record.text("reason") == "Not now: later" && record.text("decision") == "reject")
        Inbox.note("resume: opened conversation", in: archived)
        let noted = try String(contentsOf: archived, encoding: .utf8)
        precondition(noted.contains("## Callbacks\n- resume: opened conversation"))
        try sample.write(to: good, atomically: true, encoding: .utf8)
        let again = try Inbox.resolve(Inbox.load(inbox).first { $0.id == good.lastPathComponent }!, decision: .done, note: "")
        precondition(again.lastPathComponent == "2026-10-23-agent-a-question-2.md", "archive names must not collide")

        // Activity log
        try ActivityLog.append(workspace: workspace, type: "skill.attached", actor: "user", subject: "daily-news", details: ["target": "agent"])
        try ActivityLog.append(workspace: workspace, type: "inbox.rejected", actor: "user", subject: "x")
        let logText = try String(contentsOf: ActivityLog.file(in: workspace, at: Date()), encoding: .utf8)
        let lines = logText.split(separator: "\n")
        precondition(lines.count == 2)
        for line in lines {
            let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            precondition(Set(entry.keys) == ["time", "type", "actor", "subject", "outcome", "details"])
        }

        print("Passed: front matter, workspace inbox/logs/bundled skills, library create/edit/list, attach/detach/conflicts, project .gitignore, proposal approval and containment, inbox wiring, inbox parsing/problems/callbacks, stale-safe archiving, activity log.")
    }
}
