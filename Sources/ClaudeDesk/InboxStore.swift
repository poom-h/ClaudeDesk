import AppKit
import SwiftUI

/// Workspace services: the activity log, the skill library, and the Inbox.
extension DeskStore {
    var workspaceURL: URL? { workspacePath.isEmpty ? nil : URL(fileURLWithPath: workspacePath) }
    var libraryURL: URL? { workspaceURL.map(Workspace.skills(in:)) }
    var inboxURL: URL? { workspaceURL.map(Workspace.inbox(in:)) }
    var pendingInboxCount: Int { inboxItems.count }

    // MARK: Activity log

    func log(_ type: String, actor: String = "user", subject: String, outcome: String = "ok", details: [String: String] = [:]) {
        guard let workspace = workspaceURL else { return }
        try? ActivityLog.append(workspace: workspace, type: type, actor: actor, subject: subject, outcome: outcome, details: details)
    }

    /// Logs a conversation's start now and its natural exit later.
    func track(_ terminal: RunningTerminal, type: String = "conversation.started", actor: String = "user", details: [String: String]) {
        var details = details
        details["pane"] = terminal.id.uuidString
        log(type, actor: actor, subject: terminal.session.name, outcome: terminal.running ? "ok" : "failed", details: details)
        terminal.onExit = { [weak self] status in
            self?.log("conversation.ended", actor: "app", subject: terminal.session.name, outcome: status, details: ["pane": terminal.id.uuidString])
        }
    }

    // MARK: Watching the workspace

    func startWorkspaceServices() {
        folderWatchers.forEach { $0.cancel() }
        folderWatchers = []
        // Workspaces set up by an older version gain the folders and bundled skills added since.
        if let workspace = workspaceURL {
            do { try Workspace.prepare(root: workspace, vaultTemplate: Workspace.bundledVaultTemplate, skillTemplates: Workspace.bundledSkills) }
            catch { self.error = "Could not update the workspace folder: \(error.localizedDescription)" }
        }
        refreshSkills()
        refreshInbox()
        connectAgentsToInbox()
        refreshRoutines()
        for folder in [inboxURL, libraryURL, workspaceURL.map(Routines.folder(in:))].compactMap({ $0 }) { watch(folder) }
        if activityObserver == nil {
            activityObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshSkills()
                    self?.refreshInbox()
                    self?.refreshRoutines()
                }
            }
        }
    }

    private func watch(_ folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshSkills()
                self?.refreshInbox()
                self?.refreshRoutines()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderWatchers.append(source)
    }

    func refreshSkills() {
        librarySkills = libraryURL.map(SkillLibrary.list(library:)) ?? []
        if let name = selectedSkillName, !librarySkills.contains(where: { $0.name == name }) { selectedSkillName = nil }
        if selectedSkillName == nil { selectedSkillName = librarySkills.first?.name }
        skillRevision += 1
    }

    func refreshInbox() {
        guard let inbox = inboxURL else { inboxItems = []; return }
        let items = Inbox.load(inbox)
        // Log each item the first time the app sees it; the seen list only keeps items still waiting.
        let seenKey = "loggedInboxItems"
        let seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        for item in items where !seen.contains(item.id) {
            log(item.problem == nil ? "inbox.created" : "inbox.unreadable", actor: item.from.isEmpty ? "unknown" : item.from,
                subject: item.id, outcome: item.problem == nil ? "ok" : "problem", details: ["kind": item.kind, "title": item.title])
        }
        UserDefaults.standard.set(items.map(\.id), forKey: seenKey)
        inboxItems = items
    }

    // MARK: Agents

    /// Connects each agent to the Inbox once. Later manual edits to its files are respected.
    func connectAgentsToInbox() {
        guard let inbox = inboxURL, let workspace = workspaceURL else { return }
        // v2 also grants the routines folder; agents connected by 3.4.0 are updated once more.
        let key = "workspaceConnectedAgents.v2"
        var connected = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let inboxSkill = librarySkills.first { $0.name == SkillLibrary.inboxSkillName }
        var problems: [String] = []
        for agent in agents where !connected.contains(agent.id.uuidString) {
            do {
                try AgentEnvironment.connectInbox(agent, inbox: inbox, inboxSkill: inboxSkill, routines: Routines.folder(in: workspace))
                connected.insert(agent.id.uuidString)
                log("agent.inbox-connected", actor: "app", subject: agent.name, details: ["agent": agent.id.uuidString])
            } catch { problems.append("\(agent.name): \(error.localizedDescription)") }
        }
        UserDefaults.standard.set(Array(connected), forKey: key)
        // Cockpit widgets arrived in 3.7.0; each agent is connected once.
        let widgetKey = "workspaceConnectedAgents.widgets.v1"
        var widgetConnected = Set(UserDefaults.standard.stringArray(forKey: widgetKey) ?? [])
        let widgetSkill = librarySkills.first { $0.name == SkillLibrary.widgetSkillName }
        for agent in agents where !widgetConnected.contains(agent.id.uuidString) {
            do {
                try AgentEnvironment.connectWidgets(agent, widgetSkill: widgetSkill)
                widgetConnected.insert(agent.id.uuidString)
                log("agent.widgets-connected", actor: "app", subject: agent.name, details: ["agent": agent.id.uuidString])
            } catch { problems.append("\(agent.name): \(error.localizedDescription)") }
        }
        UserDefaults.standard.set(Array(widgetConnected), forKey: widgetKey)
        if !problems.isEmpty { error = "Could not connect every agent to the Inbox.\n" + problems.joined(separator: "\n") }
        skillRevision += 1
    }

    /// Finds the agent an inbox item came from, by ID, folder name, or display name.
    func agent(matching from: String) -> AgentProfile? { agents.matching(from) }

    // MARK: Skills

    var skillTargets: [SkillTarget] {
        [.global] + agents.map(SkillTarget.agent) + projects.map(SkillTarget.project)
    }

    func attachment(of skill: LibrarySkill, to target: SkillTarget) -> SkillLibrary.Attachment {
        _ = skillRevision
        return SkillLibrary.attachment(of: skill, in: target.skillsDirectory)
    }

    func setSkill(_ skill: LibrarySkill, attached: Bool, to target: SkillTarget) {
        do {
            if attached { try SkillLibrary.attach(skill, to: target.skillsDirectory, repository: target.repository) }
            else { try SkillLibrary.detach(skill, from: target.skillsDirectory) }
            log(attached ? "skill.attached" : "skill.detached", subject: skill.name, details: ["target": target.id, "path": target.skillsDirectory.path])
        } catch { self.error = error.localizedDescription }
        skillRevision += 1
    }

    @discardableResult
    func createSkill(name: String, description: String) -> Bool {
        guard let library = libraryURL else { error = "Choose a workspace folder in Settings first."; return false }
        do {
            let skill = try SkillLibrary.create(name: name, description: description, library: library)
            log("skill.created", subject: skill.name)
            refreshSkills()
            selectedSkillName = skill.name
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    // MARK: Inbox

    /// Applies a decision: the kind's built-in action, then archive, then the callbacks you left switched on.
    @discardableResult
    func resolve(_ item: InboxItem, decision: Inbox.Decision, note: String, enabled: Set<Int>) -> Bool {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = agent(matching: item.from)
        do {
            try Inbox.checkUnchanged(item)
            if item.kind == "skill", decision == .approve {
                guard let sender, let library = libraryURL else {
                    throw AgentEnvironment.Failure(message: "No agent named “\(item.from)” exists, so the skill can't be imported.")
                }
                let skill = try SkillLibrary.approve(item.skill, from: sender, library: library)
                log("skill.approved", subject: skill.name, details: ["agent": sender.id.uuidString, "item": item.id])
                refreshSkills()
            }
            if item.kind == "routine", decision == .approve || decision == .reject, let workspace = workspaceURL {
                try Routines.decide(item.routine, fingerprint: item.fingerprint, approve: decision == .approve, workspace: workspace)
                log(decision == .approve ? "routine.approved" : "routine.rejected", subject: item.routine, details: ["item": item.id])
                refreshRoutines()
            }
            if item.kind == "memory", decision == .approve {
                guard let sender else { throw AgentEnvironment.Failure(message: "No agent named “\(item.from)” exists, so the memory can't be saved.") }
                try AgentEnvironment.appendMemory(item.memoryText, to: sender, heading: "Approved from the Inbox, " + item.created)
                log("agent.memory-appended", subject: sender.name, details: ["agent": sender.id.uuidString, "item": item.id])
            }
            let archived = try Inbox.resolve(item, decision: decision, note: note)
            log("inbox." + decision.status, subject: item.id, details: ["kind": item.kind, "from": item.from, "decision": decision.label])
            for callback in Inbox.callbacks(for: item, decision: decision) where enabled.contains(callback.index) && callback.isKnown {
                let text = Inbox.fill(callback.argument, note: note, decision: decision)
                let result = run(callback, text: text, item: item, agent: sender)
                Inbox.note("\(callback.action): \(result.message)", in: archived)
                log("inbox.callback", actor: "app", subject: item.id, outcome: result.ok ? "ok" : "failed", details: ["action": callback.action])
            }
            refreshInbox()
            return true
        } catch {
            self.error = error.localizedDescription
            refreshInbox()
            return false
        }
    }

    private func run(_ callback: InboxCallback, text: String, item: InboxItem, agent: AgentProfile?) -> (ok: Bool, message: String) {
        switch callback.action {
        case "none": return (true, "nothing to do")
        case "resume":
            guard let agent else { return (false, "no agent named “\(item.from)”") }
            guard !item.session.isEmpty else { return (false, "the item has no session to resume") }
            let opened = launchAgent(agent,
                                     arguments: ["--resume", item.session] + (text.isEmpty ? [] : ["--", text]), actor: "inbox")
            return opened ? (true, "reopened conversation \(item.session)") : (false, "could not reopen conversation \(item.session)")
        case "run-routine":
            let name = text.isEmpty ? item.routine : text
            guard !name.isEmpty, let workspace = workspaceURL else { return (false, "no routine named") }
            do {
                guard try Routines.enqueue(name, requestedBy: "inbox", note: item.title, workspace: workspace) else {
                    return (true, "routine \(name) was already queued or running, so it wasn't queued again")
                }
                log("routine.queued", subject: name, details: ["item": item.id])
                return (true, "queued routine \(name)")
            } catch { return (false, error.localizedDescription) }
        case "new-conversation":
            guard let agent else { return (false, "no agent named “\(item.from)”") }
            let opened = launchAgent(agent, arguments: text.isEmpty ? [] : ["--", text], actor: "inbox")
            return opened ? (true, "started a new conversation") : (false, "could not start a conversation")
        default: return (false, "unsupported action")
        }
    }

    func openConversation(for item: InboxItem) {
        guard let agent = agent(matching: item.from) else { error = "No agent named “\(item.from)” exists."; return }
        launchAgent(agent, arguments: ["--resume", item.session])
    }

    func proposal(for item: InboxItem) -> SkillProposal? {
        guard let agent = agent(matching: item.from) else { return nil }
        return SkillLibrary.proposals(agents: [agent]).first { $0.name == item.skill }
    }
}

// MARK: - Routines

extension DeskStore {
    static let runnerLabel = "local.claudedesk.runner"
    var runnerPlist: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(Self.runnerLabel).plist")
    }
    var runnerExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/claudedesk-runner") }

    func refreshRoutines() {
        guard let workspace = workspaceURL else { routineList = []; return }
        routineList = Routines.parse((try? String(contentsOf: Routines.file(in: workspace), encoding: .utf8)) ?? "")
        runnerEnabled = FileManager.default.fileExists(atPath: runnerPlist.path)
    }

    func runNow(_ routine: Routine) {
        guard let workspace = workspaceURL else { return }
        do {
            guard try Routines.enqueue(routine.name, requestedBy: "user", workspace: workspace) else {
                let state = Routines.busy(routine.name, workspace: workspace) ?? "queued"
                log("routine.queue-skipped", subject: routine.name, outcome: state)
                notice = "\(routine.name) is already \(state == "running" ? "running" : "queued"), so it wasn't queued again."
                return
            }
            log("routine.queued", subject: routine.name)
            // Wake the runner now instead of waiting for its next 5-minute check. Without -k, a pass already going isn't interrupted.
            _ = launchctl(["kickstart", "gui/\(getuid())/\(Self.runnerLabel)"])
            notice = "Queued \(routine.name). It starts in a few seconds."
        } catch { self.error = error.localizedDescription }
    }

    /// Installs or removes the LaunchAgent that runs claudedesk-runner every 5 minutes.
    func setRunner(enabled: Bool) {
        guard let workspace = workspaceURL else { error = "Choose a workspace folder in Settings first."; return }
        let domain = "gui/\(getuid())"
        do {
            if enabled {
                guard FileManager.default.isExecutableFile(atPath: runnerExecutable.path) else {
                    throw AgentEnvironment.Failure(message: "The routine runner is missing from this copy of ClaudeDesk (\(runnerExecutable.path)).")
                }
                let log = Routines.runnerFolder(in: workspace).appendingPathComponent("runner.log").path
                let plist: [String: Any] = [
                    "Label": Self.runnerLabel,
                    "ProgramArguments": [runnerExecutable.path, "--workspace", workspace.path],
                    "StartInterval": 300, "RunAtLoad": true, "ProcessType": "Background",
                    "StandardOutPath": log, "StandardErrorPath": log
                ]
                try FileManager.default.createDirectory(at: runnerPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: runnerPlist, options: .atomic)
                _ = launchctl(["bootout", "\(domain)/\(Self.runnerLabel)"])
                let status = launchctl(["bootstrap", domain, runnerPlist.path])
                guard status == 0 else { throw AgentEnvironment.Failure(message: "macOS refused to start the routine runner (launchctl status \(status)).") }
                self.log("runner.enabled", subject: workspace.path)
            } else {
                _ = launchctl(["bootout", "\(domain)/\(Self.runnerLabel)"])
                try? FileManager.default.removeItem(at: runnerPlist)
                self.log("runner.disabled", subject: workspace.path)
            }
        } catch { self.error = error.localizedDescription }
        refreshRoutines()
    }

    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

// MARK: - Routines status for the sidebar

struct RoutineSummary {
    enum Tone { case off, ok, waiting, attention }
    let text: String
    let tone: Tone
}

extension DeskStore {
    /// One line for the sidebar's Routines row, most urgent state first.
    func routineSummary(now: Date = Date()) -> RoutineSummary {
        guard let workspace = workspaceURL else { return RoutineSummary(text: "Set up workspace", tone: .off) }
        let alerts = inboxItems.filter { $0.kind == "alert" }.count
        if alerts > 0 { return RoutineSummary(text: alerts == 1 ? "1 alert" : "\(alerts) alerts", tone: .attention) }
        guard runnerEnabled else { return RoutineSummary(text: "Off", tone: .off) }
        guard !routineList.isEmpty else { return RoutineSummary(text: "No routines yet", tone: .off) }
        let approvals = Routines.load(RoutineApprovals.self, from: Routines.approvalsFile(in: workspace), default: RoutineApprovals())
        let state = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        let ready = routineList.filter { routine in
            routine.problem == nil && routine.enabled && Routines.approvalReasons(routine, grant: approvals.grants[routine.name]).isEmpty
        }
        if let failed = ready.first(where: { ["failed", "timed-out", "turn-limit"].contains(state.routines[$0.name]?.lastOutcome ?? "") }) {
            return RoutineSummary(text: "\(failed.name) didn't finish", tone: .attention)
        }
        let waiting = routineList.filter { routine in
            routine.problem == nil && routine.enabled && approvals.rejected[routine.name] != routine.fingerprint
                && !Routines.approvalReasons(routine, grant: approvals.grants[routine.name]).isEmpty
        }.count
        let next = ready.compactMap { routine in routine.schedule?.next(after: now, lastRun: state.routines[routine.name]?.lastRun) }.min()
        if let next {
            let calendar = Calendar.current
            let time = next.formatted(date: .omitted, time: .shortened)
            let when = calendar.isDateInToday(next) ? time : calendar.isDateInTomorrow(next) ? "tomorrow \(time)" : next.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return RoutineSummary(text: "next \(when)" + (waiting > 0 ? " · \(waiting) to approve" : ""), tone: waiting > 0 ? .waiting : .ok)
        }
        if waiting > 0 { return RoutineSummary(text: waiting == 1 ? "1 to approve" : "\(waiting) to approve", tone: .waiting) }
        return RoutineSummary(text: "On", tone: .ok)
    }
}
