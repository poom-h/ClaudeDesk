import Foundation

@main
struct RoutinesChecks {
    static func expectFailure(_ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected failure: \(label)") } catch {}
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("claudedesk-routines-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }   // 2026-10-22 is a Thursday

        // Schedules
        precondition(RoutineSchedule.parse("daily 08:30") == .daily(hour: 8, minute: 30))
        precondition(RoutineSchedule.parse("weekdays 07:05") == .weekdays(hour: 7, minute: 5))
        precondition(RoutineSchedule.parse("mondays 09:00") == .weekly(weekday: 2, hour: 9, minute: 0))
        precondition(RoutineSchedule.parse("every 6h") == .every(minutes: 360) && RoutineSchedule.parse("hourly") == .every(minutes: 60))
        for bad in ["daily 25:00", "sometimes", "every 0h", "daily", "funday 08:00"] { precondition(RoutineSchedule.parse(bad) == nil, bad) }
        let daily = RoutineSchedule.daily(hour: 8, minute: 30)
        let approvedEarly = date("2026-10-01T00:00:00Z")
        precondition(!daily.isDue(now: date("2026-10-22T08:00:00Z"), lastRun: date("2026-10-21T08:31:00Z"), approvedAt: approvedEarly, calendar: calendar))
        precondition(daily.isDue(now: date("2026-10-22T08:31:00Z"), lastRun: date("2026-10-21T08:31:00Z"), approvedAt: approvedEarly, calendar: calendar))
        precondition(daily.isDue(now: date("2026-10-24T11:00:00Z"), lastRun: date("2026-10-21T08:31:00Z"), approvedAt: approvedEarly, calendar: calendar), "missed runs catch up")
        precondition(!daily.isDue(now: date("2026-10-22T10:00:00Z"), lastRun: nil, approvedAt: date("2026-10-22T09:00:00Z"), calendar: calendar), "a time before approval doesn't run")
        let weekdays = RoutineSchedule.weekdays(hour: 8, minute: 0)
        precondition(weekdays.lastOccurrence(atOrBefore: date("2026-10-25T12:00:00Z"), calendar: calendar) == date("2026-10-23T08:00:00Z"), "Sunday looks back to Friday")
        precondition(RoutineSchedule.weekly(weekday: 2, hour: 9, minute: 0).next(after: date("2026-10-22T10:00:00Z"), lastRun: nil, calendar: calendar) == date("2026-10-26T09:00:00Z"))
        let every = RoutineSchedule.every(minutes: 120)
        precondition(every.isDue(now: date("2026-10-22T10:00:00Z"), lastRun: nil, approvedAt: approvedEarly))
        precondition(!every.isDue(now: date("2026-10-22T10:00:00Z"), lastRun: date("2026-10-22T09:00:00Z"), approvedAt: approvedEarly))

        // routines.md
        precondition(Routines.parse(Routines.template).isEmpty, "the template's fenced example must not become a routine")
        let text = """
        # Routines
        intro text

        ## heartbeat
        - agent: agent-a
        - schedule: daily 08:30
        - skill: heartbeat

        Run your heartbeat.
        Second line.

        ## broken
        - schedule: whenever
        - colour: blue

        ## heartbeat
        - agent: agent-a
        - schedule: hourly
        do it
        """
        let parsed = Routines.parse(text)
        precondition(parsed.map(\.name) == ["heartbeat", "broken", "heartbeat"])
        precondition(parsed[0].problem == nil && parsed[0].skill == "heartbeat" && parsed[0].prompt == "Run your heartbeat.\nSecond line.")
        precondition(parsed[0].maxTurns == 30 && parsed[0].timeoutSeconds == 900 && parsed[0].enabled)
        let brokenProblem = parsed[1].problem ?? ""
        precondition(brokenProblem.contains("whenever") && brokenProblem.contains("colour") && brokenProblem.contains("Missing agent"))
        precondition(parsed[2].problem?.contains("already uses the name") == true)
        let limits = Routines.parse("## big\n- agent: a\n- schedule: daily 01:00\n- max_turns: 80\n- timeout: 1h\n- tools: web-fetch\n- enabled: no\n\nGo").first!
        precondition(limits.problem == nil && limits.maxTurns == 80 && limits.timeoutSeconds == 3600 && limits.tools == ["web-fetch"] && !limits.enabled)

        // Approval rules (Q25)
        let base = parsed[0]
        precondition(Routines.approvalReasons(base, grant: nil) == ["new routine"])
        let grant = Routines.grant(for: base, at: approvedEarly)
        precondition(Routines.approvalReasons(base, grant: grant).isEmpty)
        var edited = base
        edited.prompt = "Different words"; edited.scheduleText = "daily 06:00"; edited.schedule = .daily(hour: 6, minute: 0)
        precondition(Routines.approvalReasons(edited, grant: grant).isEmpty, "prompt and time-of-day changes apply freely")
        edited.agent = "agent-b"; edited.schedule = .every(minutes: 15); edited.maxTurns = 50; edited.timeoutSeconds = 3600; edited.tools = ["web-fetch"]
        precondition(Routines.approvalReasons(edited, grant: grant).count == 5)
        precondition(edited.fingerprint != base.fingerprint)

        // Workspace, agent, and decisions
        let workspace = root.appendingPathComponent("ws")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Workspace.prepare(root: workspace, vaultTemplate: nil, skillTemplates: URL(fileURLWithPath: "Resources/SkillTemplates"))
        precondition(manager.fileExists(atPath: Routines.file(in: workspace).path) && manager.fileExists(atPath: Routines.queue(in: workspace).path))
        let agent = try AgentEnvironment.create(name: "Agent A", purpose: "", host: Workspace.agents(in: workspace))
        try AgentEnvironment.connectInbox(agent, inbox: Workspace.inbox(in: workspace), inboxSkill: nil, routines: Routines.folder(in: workspace))
        let instructions = try String(contentsOf: URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        precondition(instructions.contains(AgentEnvironment.routinesMarker) && instructions.contains(Routines.file(in: workspace).path))
        precondition(RoutineRunner.additionalDirectories(of: agent) == [Workspace.inbox(in: workspace).path, Routines.folder(in: workspace).path])
        try "## heartbeat\n- agent: agent-a\n- schedule: daily 08:30\n- skill: heartbeat\n\nRun your heartbeat.\n".write(to: Routines.file(in: workspace), atomically: true, encoding: .utf8)
        let routine = Routines.parse(try String(contentsOf: Routines.file(in: workspace), encoding: .utf8))[0]
        expectFailure("approve a changed routine") { try Routines.decide("heartbeat", fingerprint: "stale", approve: true, workspace: workspace) }
        expectFailure("approve a missing routine") { try Routines.decide("ghost", fingerprint: "x", approve: true, workspace: workspace) }

        // Fake claude records its arguments and answers according to fake/mode.
        let fake = root.appendingPathComponent("fake")
        try manager.createDirectory(at: fake, withIntermediateDirectories: true)
        let script = fake.appendingPathComponent("claude")
        try """
        #!/bin/bash
        dir="\(fake.path)"
        n=$(ls "$dir"/args-* 2>/dev/null | wc -l | tr -d ' ')
        printf '%s\\n' "$@" > "$dir/args-$n"; echo "$CLAUDE_CONFIG_DIR" > "$dir/env-$n"; pwd -P > "$dir/cwd-$n"
        session=""; prev=""; for a in "$@"; do [ "$prev" = "--session-id" ] && session="$a"; prev="$a"; done
        case "$(cat "$dir/mode" 2>/dev/null || echo ok)" in
          ok) printf -- '---\\nkind: message\\nfrom: agent-a\\nsession: %s\\ntitle: Report\\n---\\nhi\\n' "$session" > "\(Workspace.inbox(in: workspace).path)/fake-$session.md"
              echo '{"subtype":"success","num_turns":3,"is_error":false,"permission_denials":[]}' ;;
          quiet) echo '{"subtype":"success","num_turns":1,"is_error":false,"permission_denials":[]}' ;;
          turns) echo '{"subtype":"error_max_turns","num_turns":30,"is_error":true}'; exit 1 ;;
          sleep) exec sleep 30 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func setMode(_ mode: String) throws { try mode.write(to: fake.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
        func calls() -> Int { ((try? manager.contentsOfDirectory(atPath: fake.path)) ?? []).filter { $0.hasPrefix("args-") }.count }
        func args(_ n: Int) -> [String] { (try? String(contentsOf: fake.appendingPathComponent("args-\(n)"), encoding: .utf8))?.components(separatedBy: "\n").dropLast().map { $0 } ?? [] }
        func items(_ kind: String) -> [InboxItem] { Inbox.load(Workspace.inbox(in: workspace)).filter { $0.kind == kind } }

        var clock = date("2026-10-22T09:00:00Z")
        var notifications: [String] = []
        let runner = RoutineRunner(workspace: workspace, agents: [agent], executable: script.path)
        runner.now = { clock }
        runner.calendar = calendar
        runner.notify = { title, _ in notifications.append(title) }

        // A new routine waits for approval and is requested once.
        runner.pass(); runner.pass()
        precondition(calls() == 0 && items("routine").count == 1, "new routines don't run and are requested once")
        let request = items("routine")[0]
        precondition(request.routine == "heartbeat" && request.fingerprint == routine.fingerprint && request.problem == nil)

        // Approved after 08:30: today's time has passed, so the first run is tomorrow.
        try Routines.decide("heartbeat", fingerprint: request.fingerprint, approve: true, workspace: workspace, now: date("2026-10-22T09:05:00Z"))
        clock = date("2026-10-22T09:10:00Z"); runner.pass()
        precondition(calls() == 0)
        clock = date("2026-10-23T08:31:00Z"); runner.pass()
        precondition(calls() == 1, "runs at the next scheduled time")
        let first = args(0)
        let separator = first.firstIndex(of: "--")!
        for flag in ["-p", "--session-id", "--permission-prompts", "--allowedTools"] { precondition(first.contains(flag), flag) }
        precondition(first[first.firstIndex(of: "--permission-mode")! + 1] == "default" && !first.contains("acceptEdits"))
        precondition(first[first.firstIndex(of: "--max-turns")! + 1] == "30")
        precondition(first.contains("Edit(/" + agent.path + "/**)") && first.contains("Edit(/" + Workspace.inbox(in: workspace).path + "/**)"))
        precondition(!first.contains("WebFetch") && first.firstIndex(of: "--allowedTools")! < separator)
        let prompt = first[(separator + 1)...].joined(separator: "\n")
        precondition(prompt.contains("Routine: heartbeat") && prompt.contains("Use the `heartbeat` skill.") && prompt.contains("Run your heartbeat."))
        let configSeen = try String(contentsOf: fake.appendingPathComponent("env-0"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(configSeen == agent.configPath)
        let cwdSeen = try String(contentsOf: fake.appendingPathComponent("cwd-0"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition((cwdSeen as NSString).resolvingSymlinksInPath == (agent.path as NSString).resolvingSymlinksInPath, "runs in the agent folder")
        var state = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        precondition(state.routines["heartbeat"]?.lastOutcome == "ok" && state.runsToday == 1)
        precondition(notifications.count == 1, "a run that files inbox items notifies")
        runner.pass()
        precondition(calls() == 1, "not due again the same day")

        // Queued runs start right away; answers to earlier requests reach the prompt.
        try setMode("quiet")
        try """
        ---
        kind: request
        from: agent-a
        via: routine:heartbeat
        title: Archive old notes?
        status: answered
        resolved: 2026-10-23T09:00:00Z
        decision: approve
        reply: Yes, archive them
        ---
        """.write(to: Inbox.archive(in: Workspace.inbox(in: workspace)).appendingPathComponent("answered.md"), atomically: true, encoding: .utf8)
        let queuedFirst = try Routines.enqueue("heartbeat", requestedBy: "user", note: "check now", workspace: workspace)
        precondition(queuedFirst && Routines.busy("heartbeat", workspace: workspace) == "queued")
        let second = try Routines.enqueue("heartbeat", requestedBy: "user", workspace: workspace)
        precondition(!second, "a second click while queued is ignored")
        let waiting = try manager.contentsOfDirectory(atPath: Routines.queue(in: workspace).path)
        precondition(waiting.count == 1)
        clock = date("2026-10-23T09:30:00Z"); runner.pass()
        precondition(Routines.busy("heartbeat", workspace: workspace) == nil, "finished runs don't block the next one")
        let queueLeft = try manager.contentsOfDirectory(atPath: Routines.queue(in: workspace).path)
        precondition(calls() == 2 && queueLeft.isEmpty)
        let queuedPrompt = args(1).joined(separator: "\n")
        precondition(queuedPrompt.contains("noting: check now") && queuedPrompt.contains("Archive old notes?") && queuedPrompt.contains("Yes, archive them"))
        precondition(notifications.count == 1, "quiet successful runs don't notify")

        // Turn limit: recorded, alerted, notified.
        try setMode("turns")
        try Routines.enqueue("heartbeat", requestedBy: "user", workspace: workspace)
        runner.pass()
        state = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        precondition(state.routines["heartbeat"]?.lastOutcome == "turn-limit" && items("alert").count == 1 && notifications.count == 2)

        // Timeout: the process is stopped.
        try setMode("sleep")
        var short = routine
        short.timeoutSeconds = 2
        let started = Date()
        let timed = runner.run(short, request: nil, lastRun: nil)
        precondition(timed.outcome == "timed-out" && Date().timeIntervalSince(started) < 20)

        // A routine edited beyond its grant pauses and asks again; a rejection is remembered.
        try "## heartbeat\n- agent: agent-a\n- schedule: every 15m\n\nRun.\n".write(to: Routines.file(in: workspace), atomically: true, encoding: .utf8)
        let before = calls()
        clock = date("2026-10-24T09:00:00Z"); runner.pass(); runner.pass()
        let requests = items("routine")
        precondition(calls() == before && requests.count == 2, "a riskier edit pauses and files one new request")
        let newest = requests.first { $0.fingerprint != request.fingerprint }!
        try Routines.decide("heartbeat", fingerprint: newest.fingerprint, approve: false, workspace: workspace)
        try manager.removeItem(at: newest.url)
        var forget = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        forget.routines["heartbeat"]?.requestedFingerprint = nil
        try Routines.save(forget, to: Routines.stateFile(in: workspace))
        runner.pass()
        precondition(items("routine").count == 1 && calls() == before, "rejected versions are not requested again or run")

        // Invalid routines alert once; the daily cap stops runs and alerts once.
        try "## oops\n- agent: agent-a\n\nNo schedule.\n\n## daily\n- agent: agent-a\n- schedule: every 1h\n\nGo.\n".write(to: Routines.file(in: workspace), atomically: true, encoding: .utf8)
        let hourly = Routines.parse(try String(contentsOf: Routines.file(in: workspace), encoding: .utf8))[1]
        try Routines.decide("daily", fingerprint: hourly.fingerprint, approve: true, workspace: workspace)
        var capped = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        capped.runsToday = Routines.maxRunsPerDay
        try Routines.save(capped, to: Routines.stateFile(in: workspace))
        let alertsBefore = items("alert").count
        runner.pass(); runner.pass()
        precondition(calls() == before, "no runs past the daily cap")
        precondition(items("alert").count == alertsBefore + 2, "one alert for the invalid routine, one for the cap")

        // Unknown agents fail clearly.
        var orphan = routine
        orphan.agent = "nobody"
        precondition(runner.run(orphan, request: nil, lastRun: nil).outcome == "failed")

        // The activity log recorded the runner's work.
        let log = try String(contentsOf: ActivityLog.file(in: workspace, at: clock), encoding: .utf8)
        for type in ["routine.paused", "routine.started", "routine.finished", "routine.failed", "routine.timed-out", "routine.invalid", "routine.cap-reached"] {
            precondition(log.contains("\"type\":\"\(type)\""), type)
        }

        print("Passed: schedule parsing and catch-up, routines.md parsing and problems, approval rules, decisions, restricted arguments, run environment, queue, answered-request prompts, notifications, turn limit, timeout, re-approval, rejection, invalid routines, daily cap, unknown agents, activity log.")
    }
}
