import Foundation

@main
struct CockpitChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("claudedesk-cockpit-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Workspace.prepare(root: workspace, vaultTemplate: nil, skillTemplates: nil)

        // Layout
        precondition(CockpitLayout.load(in: workspace) == .standard, "a missing cockpit.json gives the standard layout")
        var layout = CockpitLayout.standard
        layout.shortcuts.append(SkillShortcut(title: "Heartbeat", skill: "heartbeat", agent: "atlas"))
        layout.widgets[0].size = .small
        try layout.save(in: workspace)
        precondition(CockpitLayout.load(in: workspace) == layout)
        precondition(WidgetKind.allCases.count == 14 && WidgetKind.builtIn.contains(.mail) && WidgetKind.builtIn.contains(.schedule) && !WidgetKind.builtIn.contains(.news) && !WidgetKind.builtIn.contains(.agent) && WidgetSize.large.span == (2, 2))
        precondition(!CockpitLayout.standard.widgets.contains { $0.kind == .news }, "the retired News widget isn't in new layouts")
        // Widget size: older layouts without it load at 100%, and values are clamped
        try #"{"widgets":[{"id":"7C8F5B4E-1D2A-4E5B-9C3D-2A1B0C9D8E7F","kind":"today","size":"small","settings":{}}],"shortcuts":[],"theme":"space"}"#
            .write(to: CockpitLayout.file(in: workspace), atomically: true, encoding: .utf8)
        let older = CockpitLayout.load(in: workspace)
        precondition(older.widgets.count == 1 && older.widgetScale == nil && older.scale == 1, "a layout saved before widget sizes loads unchanged")
        var scaled = older; scaled.widgetScale = 1.3
        try scaled.save(in: workspace)
        precondition(CockpitLayout.load(in: workspace).scale == 1.3)
        scaled.widgetScale = 9; precondition(scaled.scale == 1.5)
        scaled.widgetScale = 0.1; precondition(scaled.scale == 0.75)
        precondition(WidgetKind.builtIn.allSatisfy { !$0.summary.isEmpty })

        // Side columns: free placement converts once; capture goes; order follows saved height
        var free = CockpitLayout(widgets: [
            WidgetConfig(kind: .tokens, size: .small, x: 900, y: 400),
            WidgetConfig(kind: .capture, size: .wide, x: 400, y: 60),
            WidgetConfig(kind: .routines, size: .small, x: 16, y: 409),
            WidgetConfig(kind: .today, size: .small, x: 16, y: 60),
            WidgetConfig(kind: .agents, size: .small),
            WidgetConfig(kind: .inbox, size: .small, side: 1)])
        let sided = free.migratedToSides(splitX: 720)!
        precondition(sided.widgets.map(\.kind) == [.today, .routines, .tokens, .agents, .inbox], "got \(sided.widgets.map(\.kind))")
        precondition(sided.widgets.map(\.column) == [0, 0, 1, 1, 1] && sided.widgets.allSatisfy { $0.x == nil && $0.y == nil })
        precondition(sided.migratedToSides(splitX: 720) == nil, "converting twice changes nothing")
        free.widgets.removeAll { $0.kind == .capture }
        precondition(!CockpitLayout.standard.widgets.contains { $0.kind == .capture } && !WidgetKind.builtIn.contains(.capture))

        // Vault graph: Home, maps, notes, links; fenced links, Inbox, and Archive ignored
        let vault = Workspace.vault(in: workspace)
        for folder in ["Maps", "Notes", "Archive", "Inbox"] { try manager.createDirectory(at: vault.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try "# Home\n- [[Tech]] — tech\n".write(to: vault.appendingPathComponent("Home.md"), atomically: true, encoding: .utf8)
        try "# Tech\n- [[LangGraph basics|LG]] — graphs\n```\n[[Ghost]]\n```\n".write(to: vault.appendingPathComponent("Maps/Tech.md"), atomically: true, encoding: .utf8)
        try "---\ntype: guide\n---\n# LangGraph basics\nSee [[Tech#top]].\n".write(to: vault.appendingPathComponent("Notes/LangGraph basics.md"), atomically: true, encoding: .utf8)
        try "# Old\n[[Home]]\n".write(to: vault.appendingPathComponent("Archive/Old.md"), atomically: true, encoding: .utf8)
        let graph = VaultGraph.load(vault: vault)
        precondition(Set(graph.nodes.map(\.id)) == ["Home.md", "Maps/Tech.md", "Notes/LangGraph basics.md"])
        precondition(graph.nodes.first { $0.id == "Notes/LangGraph basics.md" }?.title == "LangGraph basics")
        precondition(graph.edges.count == 2, "links count once per pair, fenced links are ignored")

        // Token usage: dedupe repeated message lines, filter by time, attribute sources
        let projects = root.appendingPathComponent("profile/projects/-repo")
        try manager.createDirectory(at: projects, withIntermediateDirectories: true)
        func line(_ id: String, _ time: String, input: Int, output: Int) -> String {
            "{\"timestamp\":\"\(time)\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":10,\"cache_read_input_tokens\":100}}}"
        }
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)).replacingOccurrences(of: "Z", with: ".000Z")
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40 * 86_400)).replacingOccurrences(of: "Z", with: ".000Z")
        try [line("m1", recent, input: 5, output: 50), line("m1", recent, input: 5, output: 50), line("m2", recent, input: 1, output: 9),
             line("m3", old, input: 1000, output: 1000), "not json"].joined(separator: "\n")
            .write(to: projects.appendingPathComponent("session-a.jsonl"), atomically: true, encoding: .utf8)
        try line("m4", recent, input: 2, output: 8).write(to: projects.appendingPathComponent("session-b.jsonl"), atomically: true, encoding: .utf8)
        let scanner = UsageScanner()
        let since = Date().addingTimeInterval(-7 * 86_400)
        let costs = [UsageSession(session: "x", costUSD: 1.25, model: "Opus", captured: Date()), UsageSession(session: "y", costUSD: 9, model: "Opus", captured: Date().addingTimeInterval(-30 * 86_400))]
        let totals = scanner.totals(sources: [(root.appendingPathComponent("profile/projects"), "")], projectSessions: ["session-b"], since: since, costs: costs, runCosts: [(Date(), 0.5)])
        precondition(totals.tokens == (5 + 50 + 110) + (1 + 9 + 110) + (2 + 8 + 110), "duplicates and old messages are excluded (got \(totals.tokens))")
        precondition(totals.output == 67 && totals.bySource["ClaudeDesk projects"] == 120 && totals.bySource["Other Claude Code"] == 285)
        precondition(abs(totals.costUSD - 1.75) < 0.0001 && totals.costSessions == 2)
        let again = scanner.totals(sources: [(root.appendingPathComponent("profile/projects"), "Atlas")], projectSessions: [], since: since)
        precondition(again.bySource["Atlas"] == totals.tokens, "named sources count under the agent")

        // Status line: limits, session cost, compact line, install without replacing
        let input = """
        {"session_id":"abc-123","model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":12.4},
         "cost":{"total_cost_usd":0.42},"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":1792789800},"seven_day":{"used_percentage":33.6,"resets_at":1793066400}}}
        """
        precondition(StatusLine.handle(input: Data(input.utf8), workspace: workspace) == "Opus 5.5 · ctx 12% · 5h 24% · 7d 34%")
        let limits = PlanLimits.load(in: workspace)!
        precondition(limits.fiveHour?.used == 24 && limits.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1793066400))
        precondition(UsageSession.loadAll(in: workspace).first?.costUSD == 0.42)
        _ = StatusLine.handle(input: Data("{\"session_id\":\"../../escape\",\"cost\":{\"total_cost_usd\":1}}".utf8), workspace: workspace)
        precondition(UsageSession.loadAll(in: workspace).count == 1, "unsafe session IDs are not written")
        let settings = root.appendingPathComponent("settings.json")
        try "{\"theme\":\"dark\"}".write(to: settings, atomically: true, encoding: .utf8)
        let added = try StatusLine.install(in: settings, runner: "/Apps/runner", workspace: workspace)
        precondition(added)
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        precondition(installed["theme"] as? String == "dark" && (installed["statusLine"] as? [String: Any])?["command"] as? String == "'/Apps/runner' --statusline --workspace '\(workspace.path)'")
        try "{\"statusLine\":{\"type\":\"command\",\"command\":\"mine\"}}".write(to: settings, atomically: true, encoding: .utf8)
        let replaced = try StatusLine.install(in: settings, runner: "/Apps/runner", workspace: workspace)
        precondition(!replaced, "an existing status line is kept")

        // Steps
        precondition(RunSteps.describe(tool: "Edit", input: ["file_path": "/v/Notes/LangGraph.md"]) == "Editing Notes/LangGraph.md")
        precondition(RunSteps.describe(tool: "WebSearch", input: ["query": "claude"]) == "Searching the web: claude")
        precondition(RunSteps.describe(tool: "mcp__notion__search", input: [:]) == "Using notion")
        let event = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"/a/b/c.md\"}}]}}"
        precondition(RunSteps.step(fromLine: Data(event.utf8)) == "Reading b/c.md")

        // Manual run through the runner, with a fake claude that streams steps
        let agent = try AgentEnvironment.create(name: "Atlas", purpose: "", host: Workspace.agents(in: workspace))
        let fake = root.appendingPathComponent("claude")
        try """
        #!/bin/bash
        printf '%s\\n' "$@" > "\(root.path)/args"
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"ai news"}}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/x/inbox/item.md"}}]}}'
        [ -f "\(root.path)/slow" ] && exec sleep 30
        echo '{"type":"result","subtype":"success","num_turns":2,"is_error":false,"result":"Filed the digest.","total_cost_usd":0.12}'
        """.write(to: fake, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let runner = RoutineRunner(workspace: workspace, agents: [agent], executable: fake.path)
        var notified: [String] = []
        runner.notify = { title, _ in notified.append(title) }
        let manual = ManualRun(kind: "shortcut", title: "News now", agent: "atlas", skill: "news", request: "Focus on agents", webFetch: true)
        let result = runner.run(manual)
        precondition(result.outcome == "ok" && result.runID == manual.runID)
        let live = Routines.load(LiveRun?.self, from: LiveRun.file(in: workspace, runID: manual.runID), default: nil)!
        precondition(live.status == "ok" && live.result == "Filed the digest." && live.steps == ["Searching the web: ai news", "Writing inbox/item.md"])
        precondition(live.kind == "shortcut" && live.agentID == agent.id.uuidString && live.pid > 0)
        let args = try String(contentsOf: root.appendingPathComponent("args"), encoding: .utf8)
        precondition(args.contains("stream-json") && args.contains("--verbose") && args.contains("WebFetch") && args.contains("Use the `news` skill.") && args.contains("Focus on agents"))
        precondition(args.contains("background run the user started from the Cockpit"))
        let state = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        precondition(state.runsToday == 0, "manual runs don't count toward the routine cap")
        precondition(LiveRun.load(in: workspace).map(\.runID) == [manual.runID], "recent runs are listed")
        precondition(LiveRun.load(in: workspace, now: Date().addingTimeInterval(600)).isEmpty, "old finished runs drop off")
        let log = try String(contentsOf: ActivityLog.file(in: workspace, at: Date()), encoding: .utf8)
        precondition(log.contains("\"type\":\"run.started\"") && log.contains("\"type\":\"run.finished\"") && log.contains("\"cost\":\"0.1200\""))
        precondition(Inbox.load(Workspace.inbox(in: workspace)).isEmpty, "manual runs file no approval or alert items")

        // Stop: a stop marker plus SIGTERM ends the run as stopped
        try "".write(to: root.appendingPathComponent("slow"), atomically: true, encoding: .utf8)
        let slow = ManualRun(kind: "capture", title: "Save this", agent: "atlas", request: "save: x")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            let current = Routines.load(LiveRun?.self, from: LiveRun.file(in: workspace, runID: slow.runID), default: nil)!
            try? Data().write(to: LiveRun.stopMarker(in: workspace, runID: slow.runID))
            kill(current.pid, SIGTERM)
        }
        let stopped = runner.run(slow)
        precondition(stopped.outcome == "stopped", "got \(stopped.outcome)")
        precondition(!manager.fileExists(atPath: LiveRun.stopMarker(in: workspace, runID: slow.runID).path))
        precondition(notified.isEmpty, "stopping a run doesn't notify")


        // Markdown: block structure, images, interactive blocks, comments
        let digest = """
        ## Top stories
        ![Hero](https://example.com/a.jpg)
        > Why it matters: **big**
        > second line

        - one
        - [two](https://x.y)
          continued
        1. first
        - [ ] todo
        - [x] done
        | Model | Score |
        |---|:-:|
        | A | 1 |
        | B |
        ---
        <!-- hidden
        comment -->
        ```swift
        let x = 1
        ```
        ```button
        label: More
        run: Find more
          stories please
        ```
        Plain line one
        Plain line two
        """
        let blocks = Markdown.parse(digest)
        precondition(blocks.first == .heading(level: 2, text: "Top stories"))
        precondition(blocks[1] == .image(alt: "Hero", source: "https://example.com/a.jpg"))
        guard case .quote(let quoted) = blocks[2], quoted == [.paragraph("Why it matters: **big**\nsecond line")] else { preconditionFailure("quote: \(blocks[2])") }
        guard case .list(let items) = blocks[3] else { preconditionFailure("list: \(blocks[3])") }
        precondition(items.count == 5 && items[1].text == "[two](https://x.y)\ncontinued" && items[2].number == "1.")
        precondition(items[3].checked == false && items[4].checked == true && items[3].text == "todo" && items[3].line == 9)
        precondition(blocks[4] == .table(header: ["Model", "Score"], rows: [["A", "1"], ["B", ""]]))
        precondition(blocks[5] == .rule)
        precondition(blocks[6] == .code(language: "swift", text: "let x = 1"))
        guard case .widget(let button) = blocks[7] else { preconditionFailure("widget: \(blocks[7])") }
        precondition(button.kind == "button" && button.value("label") == "More" && button.value("run") == "Find more stories please")
        precondition(blocks[8] == .paragraph("Plain line one\nPlain line two"), "plain text keeps its line breaks")
        precondition(blocks.count == 9, "the HTML comment is hidden: \(blocks.count)")
        precondition(Markdown.parse("Just text.\nNo markdown.") == [.paragraph("Just text.\nNo markdown.")], "plain items look as before")
        precondition(Markdown.parse("[![x](https://a.b/c.png)](https://a.b)") == [.image(alt: "x", source: "https://a.b/c.png")])
        precondition(Markdown.plain("**Big** [news](https://a.b) ![i](x.png) `x`") == "Big news  x")

        // Images: https or inside the root only
        let widgetsRoot = root.appendingPathComponent("agent/widgets")
        try manager.createDirectory(at: widgetsRoot.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data([1]).write(to: widgetsRoot.appendingPathComponent("assets/a.png"))
        precondition(Markdown.resolveImage("https://example.com/a.png", base: widgetsRoot, root: widgetsRoot)?.host == "example.com")
        precondition(Markdown.resolveImage("http://example.com/a.png", base: widgetsRoot, root: widgetsRoot) == nil, "no http")
        precondition(Markdown.resolveImage("file:///etc/hosts", base: widgetsRoot, root: widgetsRoot) == nil, "no file URLs")
        precondition(Markdown.resolveImage("/etc/hosts", base: widgetsRoot, root: widgetsRoot) == nil, "no absolute paths")
        precondition(Markdown.resolveImage("../../secret.png", base: widgetsRoot, root: widgetsRoot) == nil, "no climbing out")
        precondition(Markdown.resolveImage("assets/a.png", base: widgetsRoot, root: widgetsRoot)?.lastPathComponent == "a.png")

        // Agent widgets: front matter, card and full parts, checklist ticks, signature
        let scout = AgentProfile(id: UUID(), name: "AI Scout", purpose: "", path: root.appendingPathComponent("agent").path)
        let widgetFile = widgetsRoot.appendingPathComponent("news.md")
        try "---\ntitle: Tech news\nicon: newspaper\nwidth: medium\n---\n### Headline\n- [ ] read it\n<!-- full -->\n## Everything\n- [ ] later\n".write(to: widgetFile, atomically: true, encoding: .utf8)
        try "not a widget".write(to: widgetsRoot.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let before = AgentWidgets.signature(agents: [scout])
        var widgets = AgentWidgets.load(agents: [scout])
        precondition(widgets.count == 1 && widgets[0].title == "Tech news" && widgets[0].width == 360 && widgets[0].agentFolder == "agent")
        precondition(widgets[0].card.first == .heading(level: 3, text: "Headline") && widgets[0].full.first == .heading(level: 2, text: "Everything"))
        guard case .list(let cardItems) = widgets[0].card[1], case .list(let fullItems) = widgets[0].full[1] else { preconditionFailure("widget lists") }
        precondition(cardItems[0].line == 6 && fullItems[0].line == 9, "checklist lines are file lines: \(cardItems[0].line) \(fullItems[0].line)")
        try AgentWidgets.setChecked(true, line: fullItems[0].line, in: widgetFile)
        let ticked = try String(contentsOf: widgetFile, encoding: .utf8)
        precondition(ticked.contains("- [x] later\n") && ticked.contains("- [ ] read it\n"), "tick written to the right line")
        precondition((try? AgentWidgets.setChecked(true, line: 5, in: widgetFile)) == nil, "a line that isn't a checklist item is refused")
        precondition(AgentWidgets.signature(agents: [scout]) != before, "edits change the signature")
        widgets = AgentWidgets.load(agents: [scout])
        precondition(AgentWidgets.parse("# x", url: widgetsRoot.appendingPathComponent("my-board.md"), agentFolder: "a", agentName: "A").title == "My Board")
        precondition(AgentWidgets.parse("---\nwidth: 9999\n---\nx", url: widgetFile, agentFolder: "a", agentName: "A").width == 640)
        precondition(AgentWidgets.request(for: widgets[0], instruction: "Do it").contains(widgetFile.path))

        // Widget-connected agents: folder, CLAUDE.md section once
        try AgentEnvironment.connectWidgets(scout, widgetSkill: nil)
        try AgentEnvironment.connectWidgets(scout, widgetSkill: nil)
        let scoutInstructions = try String(contentsOf: root.appendingPathComponent("agent/CLAUDE.md"), encoding: .utf8)
        precondition(scoutInstructions.components(separatedBy: AgentEnvironment.widgetsMarker).count == 2 && scoutInstructions.contains(widgetsRoot.path))

        // Archiving an item moves its relative images along; shared images are copied
        let inboxFolder = Workspace.inbox(in: workspace)
        try manager.createDirectory(at: inboxFolder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        for name in ["hero.jpg", "shared.jpg"] { try Data([1]).write(to: inboxFolder.appendingPathComponent("assets/" + name)) }
        let itemText = "---\nkind: message\nfrom: ai-scout\ntopic: news\n---\n![a](assets/hero.jpg)\n![b](assets/shared.jpg)\n![c](https://e.com/x.jpg)\n"
        try itemText.write(to: inboxFolder.appendingPathComponent("digest.md"), atomically: true, encoding: .utf8)
        try "---\nkind: message\nfrom: ai-scout\n---\n![b](assets/shared.jpg)\n".write(to: inboxFolder.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        let digestItem = Inbox.load(inboxFolder).first { $0.id == "digest.md" }!
        let archived = try Inbox.resolve(digestItem, decision: .done, note: "")
        let archiveFolder = archived.deletingLastPathComponent()
        precondition(manager.fileExists(atPath: archiveFolder.appendingPathComponent("assets/hero.jpg").path))
        precondition(!manager.fileExists(atPath: inboxFolder.appendingPathComponent("assets/hero.jpg").path), "moved")
        precondition(manager.fileExists(atPath: inboxFolder.appendingPathComponent("assets/shared.jpg").path), "still used, so copied")
        precondition(manager.fileExists(atPath: archiveFolder.appendingPathComponent("assets/shared.jpg").path))


        // Routine history from the activity log: scheduled and manual runs, failures before starting, other months, other events
        let historyRoot = root.appendingPathComponent("history-ws")
        try manager.createDirectory(at: historyRoot.appendingPathComponent("logs"), withIntermediateDirectories: true)
        func logLine(_ time: String, _ type: String, _ subject: String, _ outcome: String, _ details: [String: String]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: ["time": time, "type": type, "actor": "runner", "subject": subject, "outcome": outcome, "details": details], options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
        let october = [
            logLine("2026-10-24T02:00:05Z", "routine.started", "vault-maintenance", "ok", ["run": "r1", "requested": "schedule", "kind": "routine"]),
            logLine("2026-10-24T02:03:10Z", "routine.finished", "vault-maintenance", "ok", ["run": "r1", "seconds": "185", "cost": "0.4200", "items": "a.md,b.md"]),
            logLine("2026-10-24T08:48:20Z", "routine.started", "ai-tech-news", "ok", ["run": "r2", "requested": "user"]),
            logLine("2026-10-24T08:51:43Z", "routine.failed", "ai-tech-news", "turn-limit", ["run": "r2", "seconds": "203"]),
            logLine("2026-10-24T09:00:00Z", "routine.failed", "ghost", "no-agent", ["run": "r3"]),
            logLine("2026-10-24T09:10:00Z", "routine.started", "heartbeat", "ok", ["run": "r4", "requested": "schedule"]),
            logLine("2026-10-24T09:10:01Z", "routine.queued", "heartbeat", "ok", [:]),
            logLine("2026-10-24T09:11:00Z", "run.finished", "Shortcut", "ok", ["run": "r5"]),
        ]
        let iso = ISO8601DateFormatter()
        try (october.joined(separator: "\n") + "\n").write(to: ActivityLog.file(in: historyRoot, at: iso.date(from: "2026-10-24T00:00:00Z")!), atomically: true, encoding: .utf8)
        try (logLine("2026-09-30T23:00:00Z", "routine.started", "heartbeat", "ok", ["run": "r0", "requested": "schedule"]) + "\n")
            .write(to: ActivityLog.file(in: historyRoot, at: iso.date(from: "2026-09-30T00:00:00Z")!), atomically: true, encoding: .utf8)
        let historyNow = iso.date(from: "2026-10-24T12:00:00Z")!
        let runs = RoutineHistory.load(workspace: historyRoot, since: iso.date(from: "2026-09-29T00:00:00Z")!, now: historyNow)
        precondition(runs.map(\.runID) == ["r0", "r1", "r2", "r3", "r4"], "oldest first, across months, routine runs only: \(runs.map(\.runID))")
        precondition(runs[1].outcome == "ok" && runs[1].seconds == 185 && runs[1].cost == 0.42 && runs[1].items == ["a.md", "b.md"] && !runs[1].manual)
        precondition(runs[2].manual && runs[2].outcome == "turn-limit" && !runs[2].succeeded)
        precondition(runs[3].outcome == "no-agent" && runs[3].finished != nil, "a failure without a start still shows")
        precondition(runs[4].outcome == "running" && runs[4].finished == nil)
        precondition(RoutineHistory.load(workspace: historyRoot, since: iso.date(from: "2026-10-24T08:00:00Z")!, now: historyNow).map(\.runID) == ["r2", "r3", "r4"])
        let historySignature = RoutineHistory.signature(workspace: historyRoot, since: historyNow, now: historyNow)
        try ActivityLog.append(workspace: historyRoot, type: "routine.finished", actor: "runner", subject: "heartbeat", details: ["run": "r4"], date: historyNow)
        precondition(RoutineHistory.signature(workspace: historyRoot, since: historyNow, now: historyNow) != historySignature)
        precondition(RoutineHistory.duration(45) == "45s" && RoutineHistory.duration(200) == "3m 20s" && RoutineHistory.duration(3900) == "1h 05m")


        // Vault activity: note paths in transcript lines, and following transcripts as they grow
        let vaultRoot = "/Users/me/BrainHub/MemoryVault"
        let readLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/Users/me/BrainHub/MemoryVault/Maps/Tech.md"}}]}}"#
        precondition(VaultActivity.notes(in: readLine, vaultPaths: [vaultRoot]) == ["Maps/Tech.md"])
        let grepResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"/Users/me/BrainHub/MemoryVault/Notes/LangGraph basics.md\n/Users/me/BrainHub/MemoryVault/Notes/Bedrock.md\n/Users/me/BrainHub/MemoryVault/Notes/LangGraph basics.md"}]}}"#
        precondition(VaultActivity.notes(in: grepResult, vaultPaths: [vaultRoot]) == ["Notes/LangGraph basics.md", "Notes/Bedrock.md"], "search results, each once")
        let bash = #"{"input":{"command":"python3 /Users/me/BrainHub/MemoryVault/.tools/vault_check.py && cat /Users/me/BrainHub/MemoryVault/Home.md"}}"#
        precondition(VaultActivity.notes(in: bash, vaultPaths: [vaultRoot]) == ["Home.md"], "hidden tool folders aren't notes")
        precondition(VaultActivity.notes(in: #"{"input":{"path":"/Users/me/BrainHub/MemoryVault/Notes"}}"#, vaultPaths: [vaultRoot]).isEmpty, "folders aren't notes")

        let transcripts = root.appendingPathComponent("transcripts")
        try manager.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let oldTranscript = transcripts.appendingPathComponent("old.jsonl"), fresh = transcripts.appendingPathComponent("new.jsonl")
        try (readLine + "\n").write(to: oldTranscript, atomically: true, encoding: .utf8)
        try manager.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: oldTranscript.path)
        try (readLine + "\n" + #"{"partial":"#).write(to: fresh, atomically: true, encoding: .utf8)
        let tail = VaultActivity.Tail()
        var seen = tail.newLines(in: [oldTranscript, fresh])
        precondition(seen.count == 1 && seen[0].0 == fresh, "an older transcript isn't replayed; a brand-new one is read from the start; a half-written line waits")
        let appendHandle = try FileHandle(forWritingTo: oldTranscript); try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data((grepResult + "\n").utf8)); try appendHandle.close()
        let freshHandle = try FileHandle(forWritingTo: fresh); try freshHandle.seekToEnd()
        try freshHandle.write(contentsOf: Data("\"done\"}\n".utf8)); try freshHandle.close()
        seen = tail.newLines(in: [oldTranscript, fresh])
        precondition(seen.map { $0.1 } == [grepResult, #"{"partial":"done"}"#], "only new, complete lines: \(seen.map { $0.1 })")
        precondition(tail.newLines(in: [oldTranscript, fresh]).isEmpty)

        // Vault search: every word must match; titles beat paths beat text; snippets around the hit
        let searchEntries = [
            VaultSearch.Entry(id: "Notes/LangGraph basics.md", title: "LangGraph basics", body: "Graphs of agents. State flows between nodes."),
            VaultSearch.Entry(id: "Maps/Tech.md", title: "Tech", body: "- [[LangGraph basics]] — graphs\n- [[Bedrock]]"),
            VaultSearch.Entry(id: "Notes/Bedrock.md", title: "Bedrock inference", body: String(repeating: "filler ", count: 30) + "uses LangGraph for routing"),
            VaultSearch.Entry(id: "Home.md", title: "Home", body: "Start here.")]
        let graphHits = VaultSearch.search("langgraph", in: searchEntries)
        precondition(graphHits.first?.id == "Notes/LangGraph basics.md" && graphHits.count == 3, "title match first: \(graphHits.map(\.id))")
        precondition(VaultSearch.search("langgraph routing", in: searchEntries).map(\.id) == ["Notes/Bedrock.md"], "every word must match")
        precondition(VaultSearch.search("maps", in: searchEntries).map(\.id) == ["Maps/Tech.md"], "paths count")
        precondition(VaultSearch.search("   ", in: searchEntries).isEmpty && VaultSearch.search("zzz", in: searchEntries).isEmpty)
        let bedrockSnippet = graphHits.first { $0.id == "Notes/Bedrock.md" }!.snippet
        precondition(bedrockSnippet.hasPrefix("…") && bedrockSnippet.contains("LangGraph for routing"), "snippet around the hit: \(bedrockSnippet)")
        precondition(VaultSearch.search("HOME", in: searchEntries).first?.score ?? 0 > 1000, "exact title, any case")
        let readable = VaultSearch.readable("# LangGraph basics\n\n## State\n- See [[Tech#top|the tech map]] and [docs](https://x.y)\n> **Key:** `nodes`", title: "LangGraph basics")
        precondition(VaultSearch.readable("Use `create_agent()` **now**", title: "x") == "Use create_agent() now", "names keep underscores")
        precondition(readable == "State\nSee the tech map and docs\nKey: nodes", "plain text, title heading dropped: \(readable.debugDescription)")

        // Note viewer links: wikilinks resolve by file name, become followable links, and list each target once
        let noteStems = VaultNotes.stems([(id: "Notes/LangGraph basics.md", url: URL(fileURLWithPath: "/v/Notes/LangGraph basics.md")),
                                          (id: "Maps/Tech.md", url: URL(fileURLWithPath: "/v/Maps/Tech.md"))])
        precondition(VaultNotes.resolve("Maps/Tech#Top|tech", stems: noteStems) == "Maps/Tech.md" && VaultNotes.resolve("langgraph basics.md", stems: noteStems) == "Notes/LangGraph basics.md")
        let linked = VaultNotes.linkified("See [[Tech|the map]], [[LangGraph basics#State]] and [[Ghost]].", stems: noteStems)
        precondition(linked == "See [the map](claudedesk-note:Maps/Tech.md), [LangGraph basics](claudedesk-note:Notes/LangGraph%20basics.md) and Ghost.", linked)
        precondition(VaultNotes.outgoing("[[Tech]] [[tech|again]] [[Ghost]] [[LangGraph basics]]", stems: noteStems) == ["Maps/Tech.md", "Notes/LangGraph basics.md"])
        precondition(VaultNotes.noteID(from: URL(string: "claudedesk-note:Notes/LangGraph%20basics.md")!) == "Notes/LangGraph basics.md")
        precondition(VaultNotes.noteID(from: URL(string: "https://x.y")!) == nil)
        precondition(VaultNotes.body(of: "---\ntype: guide\n---\n# LangGraph basics\n\nText.", title: "LangGraph basics") == "Text.")

        // Asking an agent: the prompt makes the final message the answer, with the question last
        let askRun = ManualRun(kind: "ask", title: "Ask: what's in Tech?", agent: "atlas", request: "What's in my Tech map?")
        let askPrompt = runner.manualPrompt(for: askRun.routine, runID: askRun.runID, title: askRun.title, kind: "ask")
        precondition(askPrompt.contains("final message is shown to them as the answer") && askPrompt.hasSuffix("The user's question:\nWhat's in my Tech map?"))
        precondition(askRun.routine.name == "ask" && !askPrompt.contains("End with a short summary"))

        // Mail model: Gmail and Calendar parsing, Google sign-in, Jev triage request, answers and policy (all synthetic)
        func b64url(_ s: String) -> String { GoogleOAuth.base64URL(Data(s.utf8)) }
        let gmailJSON: [String: Any] = ["id": "m1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Quick q &amp; a",
            "internalDate": "1761400000000",
            "payload": ["mimeType": "multipart/alternative", "headers": [["name": "From", "value": "\"Ada Lovelace\" <ada@example.com>"], ["name": "Subject", "value": "Can we meet?"]],
                        "parts": [["mimeType": "text/html", "body": ["data": b64url("<p>Hi<br>there</p>")]], ["mimeType": "text/plain", "body": ["data": b64url("Hi there, free Tuesday?")]]]]]
        let mail = Gmail.message(from: gmailJSON, account: "me@example.com")!
        precondition(mail.fromName == "Ada Lovelace" && mail.fromAddress == "ada@example.com" && mail.subject == "Can we meet?" && mail.unread)
        precondition(mail.body == "Hi there, free Tuesday?" && mail.snippet == "Quick q & a" && mail.date.timeIntervalSince1970 == 1_761_400_000)
        precondition(mail.webURL?.absoluteString == "https://mail.google.com/mail/u/me@example.com/#all/t1")
        precondition(Gmail.text(of: ["mimeType": "text/html", "body": ["data": b64url("<style>x{}</style><p>One</p><p>Two &amp; three</p>")]]) == "One\nTwo & three")
        precondition(Gmail.parseAddress("bob@example.com") == ("", "bob@example.com"))
        let events = GoogleCalendar.events(from: ["items": [
            ["id": "e2", "summary": "Standup", "start": ["dateTime": "2026-10-26T09:30:00Z"], "end": ["dateTime": "2026-10-26T09:45:00Z"], "hangoutLink": "https://meet.google.com/x"],
            ["id": "e1", "summary": "Holiday", "start": ["date": "2026-10-26"], "end": ["date": "2026-10-27"]],
            ["id": "e3", "status": "cancelled", "start": ["dateTime": "2026-10-26T10:00:00Z"], "end": ["dateTime": "2026-10-26T11:00:00Z"]]]], account: "me@example.com")
        precondition(events.count == 2 && events.contains { $0.id == "e1" && $0.allDay } && events.first { $0.id == "e2" }?.meetLink == "https://meet.google.com/x", "cancelled events are skipped")
        // PKCE: the RFC 7636 example verifier and challenge
        precondition(GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let authURL = GoogleOAuth.authorizationURL(clientID: "cid", redirect: "http://127.0.0.1:5555", state: "s1", challenge: "c1").absoluteString
        precondition(authURL.contains("code_challenge_method=S256") && authURL.contains("access_type=offline") && authURL.contains("gmail.readonly") && !authURL.contains("gmail.modify"))
        let redirect = GoogleOAuth.callback(fromRequestLine: "GET /?state=s1&code=4%2F0Abc&scope=email HTTP/1.1")
        precondition(redirect.code == "4/0Abc" && redirect.state == "s1" && redirect.error == nil)
        precondition(GoogleOAuth.callback(fromRequestLine: "GET /?error=access_denied&state=s1 HTTP/1.1").error == "access_denied")
        let idToken = "e30." + GoogleOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["email": "me@example.com"])) + ".sig"
        precondition(GoogleOAuth.email(fromIDToken: idToken) == "me@example.com")
        precondition(String(data: GoogleOAuth.form([("a", "b c&d")]), encoding: .utf8) == "a=b%20c%26d")
        // Jev: request carries the guard and every question; parsing is strict; policy orders and flags
        let jevBody = try JSONSerialization.jsonObject(with: try JevTriage.requestBody(for: mail, model: "jev-latest")) as! [String: Any]
        let jevQuestions = jevBody["questions"] as! [String: [String: Any]]
        precondition(Set(jevQuestions.keys) == ["category", "urgent", "reply_needed", "suspicious", "importance"] && jevBody["model"] as? String == "jev-latest")
        precondition(jevQuestions.values.allSatisfy { ($0["instructions"] as? String)?.hasPrefix(JevTriage.guardText) == true }, "every question is guarded")
        precondition(((jevBody["state"] as! [String: Any])["from"] as? String) == "Ada Lovelace <ada@example.com>")
        func jevReply(category: String, urgent: Double, reply: Double, suspicious: Double, importance: Double) -> Data {
            try! JSONSerialization.data(withJSONObject: ["model": "jev-1.14.0", "usage": ["input_tokens": 300], "answers": [
                "category": ["type": "choice", "choice": category, "confidence": 0.9, "probabilities": [category: 0.95]],
                "urgent": ["type": "noul", "noul": urgent], "reply_needed": ["type": "noul", "noul": reply],
                "suspicious": ["type": "noul", "noul": suspicious],
                "importance": ["type": "score", "score": importance, "confidence": 0.6, "probabilities": ["0": 0.1]]]])
        }
        let meeting = try JevTriage.parse(jevReply(category: "meetings", urgent: 0.3, reply: 0.92, suspicious: 0.02, importance: 2.4))
        precondition(meeting.category == "meetings" && meeting.model == "jev-1.14.0" && JevTriage.needsReply(meeting) && !JevTriage.isUrgent(meeting))
        precondition((try? JevTriage.parse(try JSONSerialization.data(withJSONObject: ["detail": [["msg": "bad"]]]))) == nil, "422 errors surface")
        precondition((try? JevTriage.parse(try JSONSerialization.data(withJSONObject: ["answers": ["category": ["type": "choice", "choice": "work"]]]))) == nil, "missing answers fail loudly")
        let phish = try JevTriage.parse(jevReply(category: "finance", urgent: 0.95, reply: 0.9, suspicious: 0.85, importance: 3))
        precondition(JevTriage.isSuspicious(phish) && !JevTriage.isUrgent(phish), "suspicious mail is flagged, not marked urgent")
        var a = mail; a.id = "a"; a.triage = meeting
        var b = mail; b.id = "b"; b.triage = phish
        var c = mail; c.id = "c"; c.unread = false; c.triage = try JevTriage.parse(jevReply(category: "newsletters", urgent: 0.01, reply: 0.01, suspicious: 0.01, importance: 0.2))
        precondition(JevTriage.ordered([c, b, a]).map(\.id) == ["a", "c", "b"], "important first; suspicious never on top")
        precondition(JevTriage.label(for: "newsletters") == "Newsletters")
        let promo = try JevTriage.parse(jevReply(category: "newsletters", urgent: 0.1, reply: 0.9, suspicious: 0.02, importance: 0.5))
        precondition(!JevTriage.needsReply(promo), "newsletters' reply-to-us copy isn't a request")
        let recruiter = try JevTriage.parse(jevReply(category: "jobs", urgent: 0.3, reply: 0.9, suspicious: 0.02, importance: 2.6))
        precondition(JevTriage.needsReply(recruiter) && JevTriage.label(for: "jobs") == "Jobs" && JevTriage.isCurrent(recruiter))
        var stale = recruiter; stale.version = nil
        precondition(!JevTriage.isCurrent(stale), "judgments from older questions are asked again")
        precondition(((jevQuestions["category"]?["criteria"] as? [String: String])?.keys.contains("jobs")) == true)
        // Apple Mail: the script's records become messages that open in Mail (synthetic output)
        let FS = AppleMail.field, RS = AppleMail.record
        let appleOutput = "<abc@mail.example.com>" + FS + "Lunch?" + FS + "Ada Lovelace <ada@example.com>" + FS + "2026-10-26T12:30:00" + FS + "false" + FS + "Me@Gmail.com" + FS + "Are you free\nat one?" + RS
            + "<old@example.com>" + FS + "" + FS + "bob@example.com" + FS + "2026-10-25T08:00:00" + FS + "true" + FS + "" + FS + "" + RS
            + "broken" + FS + "record" + RS
        let apple = AppleMail.messages(from: appleOutput, timeZone: TimeZone(identifier: "UTC")!)
        precondition(apple.count == 2 && apple[0].id == "abc@mail.example.com" && apple[0].unread && !apple[1].unread, "newest first; read status; broken records skipped")
        precondition(apple[0].account == "me@gmail.com" && apple[0].fromName == "Ada Lovelace" && apple[0].snippet == "Are you free at one?" && apple[1].subject == "(no subject)" && apple[1].account == "Mail")
        precondition(apple[0].webURL?.absoluteString == "message://%3Cabc@mail.example.com%3E", "opens in Apple Mail: \(apple[0].webURL?.absoluteString ?? "-")")
        precondition(mail.webURL?.absoluteString.hasPrefix("https://mail.google.com") == true, "Gmail API mail still opens in Gmail")
        precondition(AppleMail.script(days: 3, limit: 80).contains("whose date received > cutoff") && AppleMail.script().contains("if total > 80"))
        print("Passed: cockpit layout, routine history, ask prompt, mail model, vault activity, vault search, note links, markdown blocks, image safety, agent widgets, checklist ticks, archived images, vault graph, token usage dedupe/range/sources/cost, status line limits/cost/install, steps, manual run streaming, no cap, logging, stop.")
    }
}
