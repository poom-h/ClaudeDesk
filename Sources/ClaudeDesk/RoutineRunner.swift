import Foundation

extension Array where Element == AgentProfile {
    /// Finds an agent by ID, folder name, display name, or unique folder-name prefix such as "atlas".
    func matching(_ reference: String) -> AgentProfile? {
        let key = reference.lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = first(where: { $0.id.uuidString.lowercased() == key || URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == key }) {
            return exact
        }
        let loose = filter { $0.name.lowercased() == key || URL(fileURLWithPath: $0.path).lastPathComponent.lowercased().hasPrefix(key + "-") }
        return loose.count == 1 ? loose[0] : nil
    }
}

/// One pass of the background runner: files approval requests, runs due and queued routines
/// under a restricted Claude profile, and records everything. Safe to call every few minutes.
final class RoutineRunner {
    let workspace: URL
    let agents: [AgentProfile]
    let executable: String
    var now: () -> Date = Date.init
    var calendar = Calendar.current
    var notify: (String, String) -> Void = RoutineRunner.postNotification

    init(workspace: URL, agents: [AgentProfile], executable: String) {
        self.workspace = workspace
        self.agents = agents
        self.executable = executable
    }

    private var inbox: URL { Workspace.inbox(in: workspace) }

    // MARK: Pass

    func pass() {
        let runnerFolder = Routines.runnerFolder(in: workspace)
        try? FileManager.default.createDirectory(at: Routines.queue(in: workspace), withIntermediateDirectories: true)
        // Only one pass at a time; launchd may fire again while a long routine is still running.
        let lock = open(runnerFolder.appendingPathComponent("runner.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(lock, LOCK_UN); close(lock) }

        let text = (try? String(contentsOf: Routines.file(in: workspace), encoding: .utf8)) ?? ""
        let routines = Routines.parse(text)
        let approvals = Routines.load(RoutineApprovals.self, from: Routines.approvalsFile(in: workspace), default: RoutineApprovals())
        var state = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        let today = dayKey(now())
        if state.day != today { state.day = today; state.runsToday = 0 }

        var requested: [String: RoutineRequest] = [:]
        for request in takeQueue() { requested[request.routine] = request }
        for name in requested.keys where !routines.contains(where: { $0.name == name }) {
            log("routine.skipped", actor: "runner", subject: name, outcome: "unknown-routine", details: ["reason": "queued but not in routines.md"])
        }

        for routine in routines {
            var runState = state.routines[routine.name] ?? RoutineRunState()
            defer { state.routines[routine.name] = runState; save(state) }
            if let problem = routine.problem {
                if runState.lastOutcome != "invalid" {
                    runState.lastOutcome = "invalid"
                    fileAlert(title: "Routine “\(routine.name)” can't run: fix routines.md", routine: routine.name, session: "",
                              body: problem + "\n\nEdit `\(Routines.file(in: workspace).path)`.")
                    log("routine.invalid", actor: "runner", subject: routine.name, outcome: "invalid", details: ["problem": problem])
                }
                continue
            }
            if runState.lastOutcome == "invalid" { runState.lastOutcome = nil }
            let request = requested[routine.name]
            guard routine.enabled else {
                if request != nil { log("routine.skipped", actor: "runner", subject: routine.name, outcome: "disabled") }
                continue
            }
            let grant = approvals.grants[routine.name]
            let reasons = Routines.approvalReasons(routine, grant: grant)
            if !reasons.isEmpty {
                if approvals.rejected[routine.name] == routine.fingerprint { continue }
                if runState.requestedFingerprint != routine.fingerprint {
                    fileApprovalRequest(routine, reasons: reasons)
                    runState.requestedFingerprint = routine.fingerprint
                    log("routine.paused", actor: "runner", subject: routine.name, outcome: "needs-approval", details: ["reasons": reasons.joined(separator: "; ")])
                }
                continue
            }
            guard let grant, let schedule = routine.schedule else { continue }
            let due = request != nil || schedule.isDue(now: now(), lastRun: runState.lastRun, approvedAt: grant.approvedAt, calendar: calendar)
            guard due else { continue }
            if state.runsToday >= Routines.maxRunsPerDay {
                if state.capAlertDay != today {
                    state.capAlertDay = today
                    fileAlert(title: "Daily routine limit reached (\(Routines.maxRunsPerDay) runs)", routine: routine.name, session: "",
                              body: "No more routines run today. Remaining due routines run tomorrow.")
                    log("routine.cap-reached", actor: "runner", subject: routine.name, outcome: "cap")
                    notify("Routine limit reached", "No more routines run today.")
                }
                continue
            }
            let result = run(routine, request: request, lastRun: runState.lastRun)
            state.runsToday += 1
            runState.lastRun = now()
            runState.lastOutcome = result.outcome
            runState.lastRunID = result.runID
        }
        state.lastPass = now()
        save(state)
    }

    private func takeQueue() -> [RoutineRequest] {
        let folder = Routines.queue(in: workspace)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            let request = Routines.load(RoutineRequest?.self, from: url, default: nil)
            return request
        }
    }

    // MARK: Running one routine

    struct Result { let runID: String; let outcome: String }

    /// Who asked for a run. Routines come from routines.md; shortcuts and quick captures come from the Cockpit.
    struct Origin {
        var kind = "routine"
        var title: String?
        var runID: String?
    }

    func run(_ routine: Routine, request: RoutineRequest?, lastRun: Date?, origin: Origin = Origin()) -> Result {
        let runID = origin.runID ?? UUID().uuidString.lowercased()
        let label = origin.title ?? routine.name
        let isRoutine = origin.kind == "routine"
        let noun = isRoutine ? "Routine" : ["capture": "Quick capture", "widget": "Widget button", "ask": "Question"][origin.kind] ?? "Shortcut"
        let event = isRoutine ? "routine" : "run"
        final class LiveBox { var value: LiveRun; init(_ value: LiveRun) { self.value = value } }
        let live = LiveBox(LiveRun(runID: runID, title: label, agentID: "", kind: origin.kind, started: now()))
        let saveLive = { [workspace] in try? Routines.save(live.value, to: LiveRun.file(in: workspace, runID: runID)) }
        guard let agent = agents.matching(routine.agent) else {
            live.value.status = "failed"; live.value.result = "No agent named \(routine.agent)."; live.value.finished = now(); saveLive()
            if isRoutine {
                fileAlert(title: "Routine “\(routine.name)” failed: no agent “\(routine.agent)”", routine: routine.name, session: runID,
                          body: "Check the agent name in routines.md.")
            }
            log("\(event).failed", actor: "runner", subject: label, outcome: "no-agent", details: ["run": runID, "agent": routine.agent, "kind": origin.kind])
            notify("\(noun) \(label) failed", "No agent named \(routine.agent).")
            return Result(runID: runID, outcome: "failed")
        }
        let started = now()
        live.value.agentID = agent.id.uuidString
        saveLive()
        log("\(event).started", actor: "runner", subject: label,
            details: ["run": runID, "agent": agent.id.uuidString, "requested": request?.requestedBy ?? (isRoutine ? "schedule" : "user"), "kind": origin.kind])
        let text = isRoutine ? prompt(for: routine, runID: runID, request: request, lastRun: lastRun) : manualPrompt(for: routine, runID: runID, title: label, kind: origin.kind)
        let arguments = Self.arguments(for: routine, agent: agent, runID: runID, prompt: text, vault: Workspace.vault(in: workspace))
        let output = execute(arguments, in: agent, timeout: TimeInterval(routine.timeoutSeconds), started: { pid in
            live.value.pid = pid; saveLive()
        }, step: { step in
            live.value.steps = Array((live.value.steps + [step]).suffix(8)); saveLive()
        })
        try? FileManager.default.createDirectory(at: Routines.runs(in: workspace), withIntermediateDirectories: true)
        try? output.report.write(to: Routines.runs(in: workspace).appendingPathComponent(runID + ".json"))
        if !output.stderr.isEmpty { try? output.stderr.write(to: Routines.runs(in: workspace).appendingPathComponent(runID + ".stderr.txt")) }

        let report = (try? JSONSerialization.jsonObject(with: output.report)) as? [String: Any] ?? [:]
        let subtype = report["subtype"] as? String ?? ""
        let turns = report["num_turns"] as? Int ?? 0
        let denials = (report["permission_denials"] as? [Any])?.count ?? 0
        let stopMarker = LiveRun.stopMarker(in: workspace, runID: runID)
        let outcome: String
        if FileManager.default.fileExists(atPath: stopMarker.path) { outcome = "stopped"; try? FileManager.default.removeItem(at: stopMarker) }
        else if output.timedOut { outcome = "timed-out" }
        else if subtype == "error_max_turns" { outcome = "turn-limit" }
        else if output.status != 0 || report["is_error"] as? Bool == true || report.isEmpty { outcome = "failed" }
        else { outcome = "ok" }
        live.value.status = outcome
        live.value.result = report["result"] as? String ?? (outcome == "stopped" ? "Stopped." : "")
        live.value.finished = now()
        saveLive()
        let created = itemsCreated(by: runID)
        let duration = Int(now().timeIntervalSince(started))
        let finishedType = outcome == "ok" || outcome == "stopped" ? "finished" : (outcome == "timed-out" ? "timed-out" : "failed")
        log("\(event).\(finishedType)", actor: "runner", subject: label, outcome: outcome,
            details: ["run": runID, "agent": agent.id.uuidString, "turns": String(turns), "seconds": String(duration), "kind": origin.kind,
                      "denials": String(denials), "items": created.joined(separator: ","), "output": "runs/\(runID).json",
                      "cost": (report["total_cost_usd"] as? Double).map { String(format: "%.4f", $0) } ?? ""])
        if outcome != "ok" && outcome != "stopped" {
            let explanation = ["timed-out": "It ran longer than \(routine.timeoutSeconds / 60) minutes and was stopped.",
                               "turn-limit": "It reached its limit of \(routine.maxTurns) turns before finishing.",
                               "failed": "Claude exited with an error (status \(output.status))."][outcome] ?? ""
            if isRoutine {
                fileAlert(title: "Routine “\(routine.name)” \(outcome == "failed" ? "failed" : "stopped: " + outcome)", routine: routine.name, session: runID,
                          body: explanation + "\n\nRun output: `\(Routines.runs(in: workspace).appendingPathComponent(runID + ".json").path)`")
            }
            notify("\(noun) \(label): \(outcome)", explanation)
        } else if !created.isEmpty {
            notify("\(agent.name) sent \(created.count) inbox item\(created.count == 1 ? "" : "s")", "From \(isRoutine ? "the \(routine.name) routine" : label).")
        }
        return Result(runID: runID, outcome: outcome)
    }

    /// Runs one manual request from the Cockpit right away. There is no global lock, so it never waits behind a routine.
    func run(_ manual: ManualRun) -> Result {
        run(manual.routine, request: nil, lastRun: nil, origin: Origin(kind: manual.kind, title: manual.title, runID: manual.runID))
    }

    func manualPrompt(for routine: Routine, runID: String, title: String, kind: String) -> String {
        let opening = kind == "ask"
            ? "The user asked you this from the ClaudeDesk Cockpit. Your final message is shown to them as the answer, rendered as Markdown, so make it the answer itself: direct and concise, no summary of what you did. You can't ask questions back; if something needs their decision, say so in the answer. Read your memory and the Memory Vault as needed."
            : "This is a ClaudeDesk background run the user started from the Cockpit, not a conversation. Nobody is watching, so you can't ask questions. File anything that needs the user through the Inbox, then finish what you can. End with a short summary of what you did."
        var lines = [opening, "Run: \(title). Run ID: \(runID). In inbox items you write, use `session: \(runID)` and `via: \(kind)`."]
        if !routine.skill.isEmpty { lines.append("Use the `\(routine.skill)` skill.") }
        if !routine.prompt.isEmpty {
            lines.append(["capture": "The user's request:\n", "ask": "The user's question:\n"][kind].map { $0 + routine.prompt } ?? routine.prompt)
        }
        return lines.joined(separator: "\n\n")
    }

    /// Restricted profile proven in the spike: default mode, no prompts, and only the listed tools allowed.
    /// Agents connected to atrium-memory also get its tools, and change the vault only through them.
    static func arguments(for routine: Routine, agent: AgentProfile, runID: String, prompt: String, vault: URL? = nil) -> [String] {
        var tools = ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "WebSearch", "Skill"]
        var allowed = ["Read", "Glob", "Grep", "WebSearch", "Skill"]
        if routine.tools.contains("web-fetch") { tools.append("WebFetch"); allowed.append("WebFetch") }
        let memoryVault = vault.flatMap { MemoryTool.isConnected(agent) ? $0 : nil }
        let vaultPaths = memoryVault.map { Set([$0.path, $0.resolvingSymlinksInPath().path]) } ?? []
        for directory in [agent.path] + additionalDirectories(of: agent) {
            if !vaultPaths.contains(directory) { allowed.append("Edit(/" + directory + "/**)") }
            let checker = URL(fileURLWithPath: directory).appendingPathComponent(".tools/vault_check.py").path
            if FileManager.default.fileExists(atPath: checker) {
                allowed.append("Bash(python3 \(checker))")
                allowed.append("Bash(python3 \(checker) *)")
            }
        }
        if memoryVault != nil { allowed.append(MemoryTool.toolPermission) }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--session-id", runID, "--max-turns", String(routine.maxTurns),
                         "--permission-mode", "default", "--permission-prompts", "none",
                         "--tools", tools.joined(separator: ","), "--allowedTools"] + allowed
        if let memoryVault { arguments += ["--disallowedTools", MemoryTool.vaultEditRule(memoryVault)] }
        return arguments + ["--", prompt]
    }

    static func additionalDirectories(of agent: AgentProfile) -> [String] {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = settings["permissions"] as? [String: Any] else { return [] }
        return (permissions["additionalDirectories"] as? [String] ?? []).filter { $0.hasPrefix("/") }
    }

    func prompt(for routine: Routine, runID: String, request: RoutineRequest?, lastRun: Date?) -> String {
        var lines = [
            "This is a scheduled ClaudeDesk routine run, not a conversation. Nobody is watching, so you can't ask questions. File anything that needs the user through the Inbox, then finish what you can.",
            "Routine: \(routine.name). Run ID: \(runID). In inbox items you write, use `session: \(runID)` and `via: routine:\(routine.name)`."
        ]
        if let request {
            lines.append("The user asked for this run now\(request.note.isEmpty ? "" : ", noting: \(request.note)").")
        }
        let answers = answeredRequests(for: routine.name, since: lastRun)
        if !answers.isEmpty { lines.append("Answers to this routine's earlier inbox requests:\n" + answers.joined(separator: "\n")) }
        if !routine.skill.isEmpty { lines.append("Use the `\(routine.skill)` skill.") }
        if !routine.output.isEmpty { lines.append("Write the results to: \(routine.output)") }
        if !routine.prompt.isEmpty { lines.append(routine.prompt) }
        return lines.joined(separator: "\n\n")
    }

    /// Resolved inbox items this routine filed, so the run can act on answers without relying on the agent to look.
    func answeredRequests(for name: String, since: Date?) -> [String] {
        let formatter = ISO8601DateFormatter()
        return Inbox.load(Inbox.archive(in: inbox)).compactMap { item in
            let record = Frontmatter.parse(item.raw)
            guard item.via == "routine:" + name, item.from != "claudedesk",
                  let resolved = record.text("resolved").flatMap(formatter.date(from:)), resolved > (since ?? .distantPast) else { return nil }
            var line = "- “\(item.title)”: \(record.text("decision") ?? record.text("status") ?? "resolved")"
            if let reply = record.text("reply") { line += ". Reply: \(reply)" }
            if let reason = record.text("reason") { line += ". Reason: \(reason)" }
            return line
        }
    }

    private func itemsCreated(by runID: String) -> [String] {
        Inbox.load(inbox).filter { $0.session == runID }.map(\.id)
    }

    struct Output { var report = Data(); var stderr = Data(); var status: Int32 = -1; var timedOut = false }

    /// Runs Claude with streaming JSON output: each tool call becomes a step, and the final result event is the report.
    func execute(_ arguments: [String], in agent: AgentProfile, timeout: TimeInterval,
                 started: (Int32) -> Void = { _ in }, step: @escaping (String) -> Void = { _ in }) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: agent.path)
        var environment = AgentEnvironment.withoutInheritedClaudeVariables(ProcessInfo.processInfo.environment)
        environment["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment.merge(AgentEnvironment.environment(for: agent)) { _, agentValue in agentValue }
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        final class Box { var data = Data(); var report = Data() }
        let out = Box(), err = Box()
        let readers = DispatchGroup()
        var result = Output()
        do { try process.run() } catch {
            result.stderr = Data("Could not start \(executable): \(error.localizedDescription)".utf8)
            return result
        }
        started(process.processIdentifier)
        readers.enter()
        DispatchQueue.global().async {
            let handle = stdout.fileHandleForReading
            var buffer = Data()
            func consume(_ line: Data) {
                guard !line.isEmpty else { return }
                if let text = RunSteps.step(fromLine: line) { step(text) }
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   object["type"] as? String == "result" || object["subtype"] != nil { out.report = line }
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    consume(buffer.subdata(in: buffer.startIndex..<newline))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            consume(buffer)
            readers.leave()
        }
        readers.enter(); DispatchQueue.global().async { err.data = stderr.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            result.timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 10) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        readers.wait()
        result.report = out.report
        result.stderr = err.data
        result.status = process.terminationStatus
        return result
    }

    // MARK: Inbox items from the runner

    private func fileApprovalRequest(_ routine: Routine, reasons: [String]) {
        let agentName = agents.matching(routine.agent)?.name ?? routine.agent
        let body = """
        The runner paused this routine until you approve it.

        Why: \(reasons.joined(separator: "; ")).

        Approving covers the routine exactly as written below. Later edits to the prompt or time of day apply without asking; \
        the changes above need approval again.

        ```markdown
        \(routine.section)
        ```
        """
        write(kind: "routine", title: "Approve routine “\(routine.name)” for \(agentName)?", via: "runner", session: "",
              extra: [("routine", routine.name), ("fingerprint", routine.fingerprint), ("agent", routine.agent)], body: body, slug: "routine-" + routine.name)
    }

    private func fileAlert(title: String, routine: String, session: String, body: String) {
        write(kind: "alert", title: title, via: "routine:" + routine, session: session, extra: [("routine", routine)], body: body, slug: "alert-" + routine)
    }

    private func write(kind: String, title: String, via: String, session: String, extra: [(String, String)], body: String, slug: String) {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm"
        var fields: [(String, String)] = [("kind", kind), ("from", "claudedesk"), ("via", via), ("title", title), ("created", stamp.string(from: now())), ("status", "pending")]
        if !session.isEmpty { fields.append(("session", session)) }
        fields += extra
        let text = "---\n" + fields.map { "\($0.0): \(Frontmatter.quote($0.1))" }.joined(separator: "\n") + "\n---\n\n" + body + "\n"
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        var url = inbox.appendingPathComponent("\(stamp.string(from: now()))-claudedesk-\(slug).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = inbox.appendingPathComponent("\(stamp.string(from: now()))-claudedesk-\(slug)-\(counter).md"); counter += 1
        }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Records

    private func save(_ state: RunnerState) { try? Routines.save(state, to: Routines.stateFile(in: workspace)) }

    private func log(_ type: String, actor: String, subject: String, outcome: String = "ok", details: [String: String] = [:]) {
        try? ActivityLog.append(workspace: workspace, type: type, actor: actor, subject: subject, outcome: outcome, details: details, date: now())
    }

    private func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func postNotification(_ title: String, _ message: String) {
        let script = "display notification \(LaunchCommand.appleScriptQuote(message)) with title \(LaunchCommand.appleScriptQuote("ClaudeDesk · " + title))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Setup for the command-line runner

    static func loadAgents() -> [AgentProfile] {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeDesk/agents.json")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([AgentProfile].self, from: data)) ?? []
    }

    static func findClaude(override: String?) -> String? {
        let candidates = (override ?? "").isEmpty
            ? [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            : [NSString(string: override!).expandingTildeInPath]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
