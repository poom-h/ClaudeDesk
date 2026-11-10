import AppKit
import SwiftUI

/// One row of the Activity widget.
struct AgentActivity: Identifiable {
    enum State { case conversation, running, waiting, idle }
    let id: String
    let title: String
    let state: State
    let detail: String
    let since: Date?
    var terminalID: UUID?
    var run: LiveRun?
    var finishedRuns: [LiveRun] = []
}

/// Cockpit services: layout, the vault graph, live runs, usage, plan limits, and background runs.
extension DeskStore {
    // MARK: Lifecycle

    func startCockpit() {
        guard cockpitTimers.isEmpty, let workspace = workspaceURL else { return }
        cockpitLayout = CockpitLayout.load(in: workspace)
        refreshAgentWidgets()
        migrateNewsWidgets()
        // Mail and Schedule arrived with the Google integration: add them once, Schedule on the left and Mail on the right.
        if !UserDefaults.standard.bool(forKey: "cockpitMailWidgets.v1") {
            UserDefaults.standard.set(true, forKey: "cockpitMailWidgets.v1")
            if !cockpitLayout.widgets.contains(where: { $0.kind == .mail }) { cockpitLayout.widgets.insert(WidgetConfig(kind: .mail, size: .small, side: 1), at: 0) }
            if !cockpitLayout.widgets.contains(where: { $0.kind == .schedule }) { cockpitLayout.widgets.insert(WidgetConfig(kind: .schedule, size: .small, side: 0), at: 0) }
            saveCockpitLayout()
        }
        // Free placement became side columns: hand-placed widgets keep their side and order; Quick capture is removed.
        if let sided = cockpitLayout.migratedToSides(splitX: Double(NSScreen.main?.frame.width ?? 1440) / 2) {
            cockpitLayout = sided
            saveCockpitLayout()
            log("cockpit.side-columns", actor: "app", subject: "layout", details: ["widgets": String(sided.widgets.count)])
        }
        installStatusLines()
        refreshCockpitFast()
        refreshVault(runChecker: true)
        refreshUsage()
        let fast = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshCockpitFast() } }
        let vault = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshVault(runChecker: false) } }
        let slow = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUsage(); self?.refreshVault(runChecker: true) }
        }
        let mail = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshMail() } }
        cockpitTimers = [fast, vault, slow, mail]
        loadMailCache()
        refreshMail()
    }

    func stopCockpit() {
        cockpitTimers.forEach { $0.invalidate() }
        cockpitTimers = []
    }

    func saveCockpitLayout() {
        guard let workspace = workspaceURL else { return }
        do { try cockpitLayout.save(in: workspace) } catch { self.error = "Could not save the Cockpit layout: \(error.localizedDescription)" }
    }

    // MARK: Refreshing

    func refreshCockpitFast() {
        guard let workspace = workspaceURL else { return }
        let runs = LiveRun.load(in: workspace)
        if runs != liveRuns { liveRuns = runs }
        let limits = PlanLimits.load(in: workspace)
        if limits != planLimits { planLimits = limits }
        refreshAgentWidgets()
        refreshRoutineRuns()
        refreshVaultReads()
    }

    /// Lights up notes agents read or search: new lines in atrium-memory's audit log, and in their transcripts, that mention a vault note.
    func refreshVaultReads() {
        guard let workspace = workspaceURL else { return }
        let vault = Workspace.vault(in: workspace)
        let roots = Array(Set([vault.path, vault.resolvingSymlinksInPath().path]))
        let now = Date()
        var reads = vaultReads.filter { now.timeIntervalSince($0.value.date) < 8 }
        let notes = Set(vaultGraph.nodes.map(\.id))
        let transcripts = VaultActivity.recentTranscripts(of: agents, now: now)
        let owners = Dictionary(transcripts.map { ($0.1.path, $0.0.name) }, uniquingKeysWith: { first, _ in first })
        let audit = VaultActivity.auditLog(in: vault)
        let files = transcripts.map(\.1) + (FileManager.default.fileExists(atPath: audit.path) ? [audit] : [])
        for (file, line) in vaultTail.newLines(in: files, now: now) {
            if file.path == audit.path {
                if let seen = VaultActivity.auditReads(in: line, now: now) {
                    for id in VaultActivity.graphIDs(for: seen.notes, in: notes) { reads[id] = VaultRead(date: now, agent: seen.actor) }
                }
                continue
            }
            guard line.contains(vault.lastPathComponent) else { continue }
            for note in VaultActivity.notes(in: line, vaultPaths: roots) where notes.contains(note) {
                reads[note] = VaultRead(date: now, agent: owners[file.path] ?? "")
            }
        }
        if reads != vaultReads { vaultReads = reads }
    }

    /// Reloads the last 7 days of routine runs, only when the activity log changed.
    func refreshRoutineRuns() {
        guard let workspace = workspaceURL else { return }
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let signature = RoutineHistory.signature(workspace: workspace, since: since)
        guard signature != routineRunSignature else { return }
        routineRunSignature = signature
        routineRuns = RoutineHistory.load(workspace: workspace, since: since)
    }

    /// Reloads agent widgets only when a widget file was added, removed, or changed.
    func refreshAgentWidgets() {
        let signature = AgentWidgets.signature(agents: agents)
        guard signature != agentWidgetSignature else { return }
        agentWidgetSignature = signature
        agentWidgets = AgentWidgets.load(agents: agents)
    }

    func agentWidget(for config: WidgetConfig) -> AgentWidget? {
        agentWidgets.first { $0.agentFolder == config.settings["agent"] && $0.name == config.settings["widget"] }
    }

    func title(of config: WidgetConfig) -> String {
        config.kind == .agent ? agentWidget(for: config)?.title ?? config.settings["title"] ?? "Agent widget" : config.kind.title
    }

    func symbol(of config: WidgetConfig) -> String {
        config.kind == .agent ? agentWidget(for: config)?.validSymbol ?? WidgetKind.agent.symbol : config.kind.symbol
    }

    /// Agent widgets not on the Cockpit yet, offered in + WIDGET.
    var unplacedAgentWidgets: [AgentWidget] {
        agentWidgets.filter { widget in !cockpitLayout.widgets.contains { $0.kind == .agent && $0.settings["agent"] == widget.agentFolder && $0.settings["widget"] == widget.name } }
    }

    /// The built-in News widget is retired: each one becomes AI Scout's own `news` widget in the same place.
    func migrateNewsWidgets() {
        guard cockpitLayout.widgets.contains(where: { $0.kind == .news }) else { return }
        let scout = agents.matching("ai-scout").map { URL(fileURLWithPath: $0.path).lastPathComponent }
        cockpitLayout.widgets = cockpitLayout.widgets.compactMap { config in
            guard config.kind == .news else { return config }
            guard let scout else { return nil }
            var widget = config
            widget.kind = .agent
            widget.settings = ["agent": scout, "widget": "news", "title": "News"]
            return widget
        }
        saveCockpitLayout()
        log("cockpit.news-migrated", actor: "app", subject: "news", details: ["agent": scout ?? "none"])
    }

    func refreshVault(runChecker: Bool) {
        guard let workspace = workspaceURL else { return }
        let vault = Workspace.vault(in: workspace)
        let previous = Dictionary(vaultGraph.nodes.map { ($0.id, $0.modified) }, uniquingKeysWith: { first, _ in first })
        let graph = VaultGraph.load(vault: vault)
        let now = Date()
        var pulses = vaultPulses.filter { now.timeIntervalSince($0.value) < 10 }
        if !previous.isEmpty {
            for node in graph.nodes where previous[node.id] != node.modified { pulses[node.id] = now }
        }
        if graph != vaultGraph { vaultGraph = graph }
        if pulses != vaultPulses { vaultPulses = pulses }
        let checker = vault.appendingPathComponent(".tools/vault_check.py")
        guard runChecker, FileManager.default.fileExists(atPath: checker.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", checker.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let result = output.split(separator: "\n").last { $0.hasPrefix("Result:") }.map { String($0.dropFirst(8)) } ?? "checker unavailable"
            DispatchQueue.main.async { self.vaultCheck = result }
        }
    }

    /// Recounts token usage off the main thread; transcripts are cached, so only changed files are re-read.
    func refreshUsage() {
        guard let workspace = workspaceURL else { return }
        let sources = UsageScanner.sources(agents: agents)
        let sessions = projectSessionIDs()
        let costs = UsageSession.loadAll(in: workspace)
        let runCosts = runCostRecords(in: workspace)
        let scanner = usageScanner
        DispatchQueue.global(qos: .utility).async {
            var results: [Int: UsageTotals] = [:]
            let calendar = Calendar.current
            for days in [1, 7, 30] {
                let since = days == 1 ? calendar.startOfDay(for: Date()) : Date().addingTimeInterval(-Double(days) * 86_400)
                results[days] = scanner.totals(sources: sources, projectSessions: sessions, since: since, costs: costs, runCosts: runCosts)
            }
            DispatchQueue.main.async { self.usage = results }
        }
    }

    /// Session IDs of project panes ClaudeDesk started, from the activity log.
    private func projectSessionIDs() -> Set<String> {
        guard let workspace = workspaceURL else { return [] }
        var ids = Set<String>()
        let logs = Workspace.logs(in: workspace)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? [] where name.hasSuffix(".jsonl") {
            guard let text = try? String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"project\"") && line.contains("conversation.") {
                if let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let details = entry["details"] as? [String: String], let session = details["session"], !session.isEmpty { ids.insert(session) }
            }
        }
        return ids
    }

    private func runCostRecords(in workspace: URL) -> [(Date, Double)] {
        let folder = Routines.runs(in: workspace)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".live.json") && !$0.hasSuffix(".request.json") }
        return names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cost = report["total_cost_usd"] as? Double,
                  let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else { return nil }
            return (modified, cost)
        }
    }

    // MARK: Activity

    func activity() -> (agents: [AgentActivity], projects: [AgentActivity]) {
        let agentRows = agents.map { agent -> AgentActivity in
            let runs = liveRuns.filter { $0.agentID == agent.id.uuidString }
            let finished = runs.filter { $0.status != "running" }
            if let run = runs.first(where: { $0.status == "running" }) {
                return AgentActivity(id: agent.id.uuidString, title: agent.name, state: .running,
                                     detail: "\(run.title) · \(run.steps.last ?? "Starting…")", since: run.started, run: run, finishedRuns: finished)
            }
            if let pane = terminals.first(where: { $0.project.agentID == agent.id && $0.running }) {
                let step = pane.sessionID.flatMap { id in
                    RunSteps.latestStep(inTranscript: URL(fileURLWithPath: agent.configPath).appendingPathComponent("projects/agent/\(id).jsonl"))
                }
                return AgentActivity(id: agent.id.uuidString, title: agent.name, state: .conversation,
                                     detail: step ?? "In a conversation", since: pane.started, terminalID: pane.id, finishedRuns: finished)
            }
            let waiting = inboxItems.filter { self.agent(matching: $0.from)?.id == agent.id }.count
            if waiting > 0 {
                return AgentActivity(id: agent.id.uuidString, title: agent.name, state: .waiting,
                                     detail: "\(waiting) item\(waiting == 1 ? "" : "s") on your Desk", since: nil, finishedRuns: finished)
            }
            return AgentActivity(id: agent.id.uuidString, title: agent.name, state: .idle,
                                 detail: lastActive(agent).map { "Last active " + $0.formatted(.relative(presentation: .named)) } ?? "Idle",
                                 since: nil, finishedRuns: finished)
        }
        let projectRows = terminals.filter { $0.project.agentID == nil && $0.running }.map { pane -> AgentActivity in
            let step = pane.sessionID.flatMap { id -> String? in
                let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
                let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
                return folders.lazy.map { projects.appendingPathComponent($0).appendingPathComponent(id + ".jsonl") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }.flatMap { RunSteps.latestStep(inTranscript: $0) }
            }
            return AgentActivity(id: pane.id.uuidString, title: "\(pane.project.name) · \(pane.session.name)", state: .conversation,
                                 detail: step ?? "In a conversation", since: pane.started, terminalID: pane.id)
        }
        return (agentRows, projectRows)
    }

    private func lastActive(_ agent: AgentProfile) -> Date? {
        let folder = URL(fileURLWithPath: agent.configPath).appendingPathComponent("projects/agent")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.modificationDate] as? Date }.max()
    }

    // MARK: Background runs

    /// Starts a shortcut or quick capture right away through the runner, which applies the restricted profile and limits.
    func startManualRun(_ manual: ManualRun) {
        guard let workspace = workspaceURL else { error = "Choose a workspace folder in Settings first."; return }
        guard FileManager.default.isExecutableFile(atPath: runnerExecutable.path) else {
            error = "The background runner is missing from this copy of ClaudeDesk."; return
        }
        do {
            let request = Routines.runs(in: workspace).appendingPathComponent(manual.runID + ".request.json")
            try Routines.save(manual, to: request)
            let process = Process()
            process.executableURL = runnerExecutable
            process.arguments = ["--workspace", workspace.path, "--run-request", request.path]
            process.environment = AgentEnvironment.withoutInheritedClaudeVariables(ProcessInfo.processInfo.environment)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            log("run.requested", subject: manual.title, details: ["run": manual.runID, "kind": manual.kind, "agent": manual.agent])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshCockpitFast() }
        } catch { self.error = "Could not start the run: \(error.localizedDescription)" }
    }

    func stopRun(_ run: LiveRun) {
        guard let workspace = workspaceURL, run.status == "running", run.pid > 0 else { return }
        try? Data().write(to: LiveRun.stopMarker(in: workspace, runID: run.runID))
        kill(run.pid, SIGTERM)
        log("run.stop-requested", subject: run.title, details: ["run": run.runID])
    }

    /// A button or input on an agent widget: a background run of that agent, under the same restricted profile as shortcuts.
    func runWidgetAction(_ widget: AgentWidget, title: String, instruction: String, skill: String, webFetch: Bool) -> String {
        let manual = ManualRun(kind: "widget", title: "\(widget.title) · \(title)", agent: widget.agentFolder, skill: skill,
                               request: AgentWidgets.request(for: widget, instruction: instruction), webFetch: webFetch)
        startManualRun(manual)
        return manual.runID
    }

    func setWidgetChecked(_ widget: AgentWidget, line: Int, checked: Bool) {
        do {
            try AgentWidgets.setChecked(checked, line: line, in: widget.url)
            log("widget.checked", subject: widget.id, details: ["line": String(line + 1), "checked": checked ? "yes" : "no"])
        } catch { self.error = error.localizedDescription }
        refreshAgentWidgets()
    }

    /// A question from the Cockpit's Ask panel: a background run whose final message is the answer. Earlier turns of
    /// the same chat go along as context, so follow-ups make sense. Returns the run ID.
    func ask(_ question: String, agent: AgentProfile, history: [(question: String, answer: String)]) -> String {
        var request = ""
        if !history.isEmpty {
            request = "Earlier in this chat:\n" + history.suffix(4).map { "Q: \($0.question)\nA: \(String($0.answer.prefix(1500)))" }
                .joined(separator: "\n\n") + "\n\nNow: "
        }
        request += question
        // Questions about mail or the schedule get the triaged mail and calendar as context.
        let topics = ["mail", "email", "e-mail", "message", "reply", "replies", "calendar", "schedule", "meeting", "agenda", "today", "tomorrow", "urgent", "inbox"]
        let lower = question.lowercased()
        let context = topics.contains(where: lower.contains) ? mailContext() : ""
        if !context.isEmpty { request = context + "\n\n" + request }
        let manual = ManualRun(kind: "ask", title: "Ask: " + String(question.prefix(60)), agent: URL(fileURLWithPath: agent.path).lastPathComponent,
                               request: request)
        startManualRun(manual)
        return manual.runID
    }

    func runShortcut(_ shortcut: SkillShortcut) {
        startManualRun(ManualRun(kind: "shortcut", title: shortcut.title, agent: shortcut.agent, skill: shortcut.skill,
                                 request: shortcut.instruction, webFetch: shortcut.webFetch))
    }

    // MARK: Plan limits collection

    /// Adds the ClaudeDesk status line to the normal profile and each agent profile once, never over an existing one.
    func installStatusLines() {
        guard let workspace = workspaceURL, FileManager.default.isExecutableFile(atPath: runnerExecutable.path) else { return }
        let key = "statusLineProfiles"
        var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let profiles = [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")] +
            agents.map { URL(fileURLWithPath: $0.configPath).appendingPathComponent("settings.json") }
        for settings in profiles where !done.contains(settings.path) {
            do {
                if try StatusLine.install(in: settings, runner: runnerExecutable.path, workspace: workspace) {
                    log("statusline.installed", actor: "app", subject: settings.path)
                }
                done.insert(settings.path)
            } catch { log("statusline.skipped", actor: "app", subject: settings.path, outcome: "failed", details: ["reason": error.localizedDescription]) }
        }
        UserDefaults.standard.set(Array(done), forKey: key)
    }

    // MARK: Navigation from widgets

    func openInStudio(terminal: UUID? = nil, inbox: Bool = false) {
        UserDefaults.standard.set("studio", forKey: "appMode")
        if let terminal, let pane = terminals.first(where: { $0.id == terminal }) {
            mode = pane.project.agentID == nil ? .projects : .agents
            activeTerminalID = terminal
            showTerminals = true
        }
        showInbox = inbox
    }
}

extension AgentWidget {
    /// The agent's chosen SF Symbol, or a neutral one when the name doesn't exist.
    var validSymbol: String { NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? WidgetKind.agent.symbol : symbol }
}
