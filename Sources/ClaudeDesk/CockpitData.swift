import Foundation

// MARK: - Layout and shortcuts (cockpit.json)

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case today, activity, inbox, news, routines, tokens, limits, shortcuts, capture, agents, vault, agent, mail, schedule
    /// Built-in widgets offered in the picker. News was replaced by agent widgets; it stays decodable for old layouts.
    /// Quick capture was removed with the side columns (2026-10-24); it also stays decodable.
    static var builtIn: [WidgetKind] { allCases.filter { $0 != .news && $0 != .agent && $0 != .capture } }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .activity: return "Activity"
        case .inbox: return "Desk"
        case .news: return "News"
        case .routines: return "Routines"
        case .tokens: return "Token usage"
        case .limits: return "Plan limits"
        case .shortcuts: return "Skill shortcuts"
        case .capture: return "Quick capture"
        case .agents: return "Agents"
        case .vault: return "Vault health"
        case .agent: return "Agent widget"
        case .mail: return "Mail"
        case .schedule: return "Schedule"
        }
    }
    /// One line for the widget gallery.
    var summary: String {
        switch self {
        case .today: return "Greeting, date, Inbox count, next routine and your 5-hour limit."
        case .activity: return "What each agent is doing right now, live run steps with Stop, and recent results."
        case .inbox: return "What agents left on your Desk, with one-click Done and Approve."
        case .news: return "Retired: replaced by AI Scout's own widget."
        case .routines: return "Today's routine runs as they happened, what's running or due, and what's next."
        case .tokens: return "Tokens used today, 7 or 30 days, by source, with an API-equivalent cost."
        case .limits: return "Your 5-hour and 7-day plan usage with reset times."
        case .shortcuts: return "Buttons that run a skill in the background with one click."
        case .capture: return "A text box that sends a request to an agent as a background run."
        case .agents: return "Each agent's skills and last heartbeat, with Talk to open a conversation."
        case .vault: return "Memory Vault note and map counts, today's changes, and the checker's status."
        case .agent: return "A widget an agent designed itself."
        case .mail: return "Your Gmail across accounts, sorted by Jev: urgent and needs-reply first, suspicious mail flagged."
        case .schedule: return "Today's Google Calendar across accounts, with what's next and Join links."
        }
    }

    var symbol: String {
        switch self {
        case .today: return "sun.horizon"
        case .activity: return "waveform.path.ecg"
        case .inbox: return "tray.full"
        case .news: return "newspaper"
        case .routines: return "clock"
        case .tokens: return "chart.bar"
        case .limits: return "gauge.with.dots.needle.33percent"
        case .shortcuts: return "wand.and.stars"
        case .capture: return "bolt"
        case .agents: return "person.2"
        case .vault: return "brain"
        case .agent: return "square.grid.2x2"
        case .mail: return "envelope.open"
        case .schedule: return "calendar"
        }
    }
}

/// Grid footprint, in columns × rows.
enum WidgetSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, wide, large
    var id: String { rawValue }
    var span: (columns: Int, rows: Int) {
        switch self {
        case .small: return (1, 1)
        case .medium: return (2, 1)
        case .wide: return (4, 1)
        case .large: return (2, 2)
        }
    }
}

struct WidgetConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: WidgetKind
    var size: WidgetSize
    var settings: [String: String] = [:]
    /// Which side column the widget sits in: 0 left, 1 right. nil means its kind's default side.
    var side: Int?
    /// Free-placement position from before the side columns; read once to pick each widget's side and order.
    var x: Double?
    var y: Double?
    var collapsed: Bool?

    var column: Int { side ?? min(1, tidyColumn) }

    /// Which side column a widget takes when arranged automatically.
    var tidyColumn: Int {
        switch kind {
        case .today, .inbox, .routines, .limits, .tokens, .schedule: return 0
        case .capture: return 2
        default: return 1
        }
    }
}

struct SkillShortcut: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var skill: String
    var agent: String
    var instruction = ""
    var webFetch = false
}

struct CockpitLayout: Codable, Equatable {
    var widgets: [WidgetConfig]
    var shortcuts: [SkillShortcut] = []
    var theme = "space"
    /// Size of every widget, 0.75–1.5. Optional so layouts saved before it existed still load.
    var widgetScale: Double?

    static let scales: [Double] = [0.75, 0.85, 1, 1.15, 1.3, 1.5]
    var scale: Double { min(1.5, max(0.75, widgetScale ?? 1)) }

    static let standard = CockpitLayout(widgets: [
        WidgetConfig(kind: .today, size: .wide),
        WidgetConfig(kind: .activity, size: .large),
        WidgetConfig(kind: .inbox, size: .medium),
        WidgetConfig(kind: .routines, size: .medium),
        WidgetConfig(kind: .limits, size: .small),
        WidgetConfig(kind: .tokens, size: .small),
        WidgetConfig(kind: .agents, size: .medium),
        WidgetConfig(kind: .vault, size: .small),
        WidgetConfig(kind: .shortcuts, size: .small)
    ])

    /// Converts a free-placement layout to side columns: Quick capture is removed, a hand-placed widget joins the side
    /// its saved position was on (left of `splitX` is left), and each side keeps top-to-bottom order. Returns nil when
    /// there's nothing to convert.
    func migratedToSides(splitX: Double) -> CockpitLayout? {
        guard widgets.contains(where: { $0.kind == .capture || ($0.x != nil && $0.side == nil) }) else { return nil }
        var result = self
        let kept = widgets.filter { $0.kind != .capture }.enumerated().map { index, config -> (WidgetConfig, Double) in
            var widget = config
            if widget.side == nil, let x = widget.x { widget.side = x < splitX ? 0 : 1 }
            // Unplaced widgets keep their list position relative to each other, after the placed ones on their side.
            let order = widget.y ?? (100_000 + Double(index))
            widget.x = nil; widget.y = nil
            return (widget, order)
        }
        result.widgets = kept.sorted { ($0.0.column, $0.1) < ($1.0.column, $1.1) }.map(\.0)
        return result
    }

    static func file(in workspace: URL) -> URL { Routines.runnerFolder(in: workspace).appendingPathComponent("cockpit.json") }
    static func load(in workspace: URL) -> CockpitLayout { Routines.load(CockpitLayout.self, from: file(in: workspace), default: .standard) }
    func save(in workspace: URL) throws { try Routines.save(self, to: Self.file(in: workspace)) }
}

// MARK: - Memory Vault graph

struct VaultNode: Identifiable, Equatable {
    enum Kind { case home, map, note }
    let id: String        // path relative to the vault
    let title: String
    let kind: Kind
    let modified: Date
    let url: URL
}

struct VaultGraph: Equatable {
    var nodes: [VaultNode] = []
    var edges: [(String, String)] = []

    static func == (a: VaultGraph, b: VaultGraph) -> Bool {
        a.nodes == b.nodes && a.edges.map { $0.0 + "→" + $0.1 } == b.edges.map { $0.0 + "→" + $0.1 }
    }

    /// Home, maps, and notes with the wikilinks between them. Inbox, Archive, and hidden folders are left out.
    static func load(vault: URL) -> VaultGraph {
        let manager = FileManager.default
        var files: [(URL, String, VaultNode.Kind)] = []
        let home = vault.appendingPathComponent("Home.md")
        if manager.fileExists(atPath: home.path) { files.append((home, "Home.md", .home)) }
        for (folder, kind) in [("Maps", VaultNode.Kind.map), ("Notes", .note)] {
            let root = vault.appendingPathComponent(folder)
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            let rootPath = root.resolvingSymlinksInPath().path
            for case let url as URL in walker where url.pathExtension == "md" {
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(rootPath + "/") else { continue }
                files.append((url, folder + "/" + path.dropFirst(rootPath.count + 1), kind))
            }
        }
        var graph = VaultGraph()
        var byStem: [String: String] = [:]
        var texts: [String: String] = [:]
        for (url, id, kind) in files {
            let modified = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let heading = text.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
            graph.nodes.append(VaultNode(id: id, title: heading ?? url.deletingPathExtension().lastPathComponent, kind: kind, modified: modified, url: url))
            byStem[url.deletingPathExtension().lastPathComponent.lowercased()] = id
            texts[id] = text
        }
        let link = try! NSRegularExpression(pattern: #"\[\[([^\]|#^]+)"#)
        var seen = Set<String>()
        for (id, text) in texts {
            let body = stripCode(text)
            for match in link.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let range = Range(match.range(at: 1), in: body) else { continue }
                let target = body[range].split(separator: "/").last.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                guard let other = byStem[target.hasSuffix(".md") ? String(target.dropLast(3)) : target], other != id else { continue }
                let key = [id, other].sorted().joined(separator: "|")
                if seen.insert(key).inserted { graph.edges.append((id, other)) }
            }
        }
        return graph
    }

    private static func stripCode(_ text: String) -> String {
        var result: [Substring] = []
        var fenced = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if !fenced { result.append(line) }
        }
        return result.joined(separator: "\n")
    }
}

// MARK: - Token usage

struct UsageTotals: Equatable {
    var tokens = 0        // input + output + cache writes + cache reads
    var output = 0
    var bySource: [String: Int] = [:]
    var costUSD = 0.0
    var costSessions = 0
}

/// Reads token counts from saved transcripts. Results per file are cached by size and date, so rescans are cheap.
final class UsageScanner {
    struct Entry { let time: Date; let tokens: Int; let output: Int }
    private var cache: [String: (size: Int, modified: Date, entries: [Entry])] = [:]

    /// Folders of transcripts, each with the source name its usage counts under.
    static func sources(agents: [AgentProfile]) -> [(URL, String)] {
        [(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"), "")] +
        agents.map { (URL(fileURLWithPath: $0.configPath).appendingPathComponent("projects"), $0.name) }
    }

    /// Totals since `since`. Transcripts in the normal profile count as "ClaudeDesk projects" when their
    /// session ID is in `projectSessions`, and as "Other Claude Code" otherwise.
    func totals(sources: [(URL, String)], projectSessions: Set<String>, since: Date, costs: [UsageSession] = [], runCosts: [(Date, Double)] = []) -> UsageTotals {
        var totals = UsageTotals()
        let manager = FileManager.default
        for (folder, name) in sources {
            guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, modified >= since else { continue }
                let session = url.deletingPathExtension().lastPathComponent
                let source = !name.isEmpty ? name : projectSessions.contains(session) ? "ClaudeDesk projects" : "Other Claude Code"
                for entry in entries(url, size: values?.fileSize ?? 0, modified: modified) where entry.time >= since {
                    totals.tokens += entry.tokens
                    totals.output += entry.output
                    totals.bySource[source, default: 0] += entry.tokens
                }
            }
        }
        for session in costs where session.captured >= since { totals.costUSD += session.costUSD; totals.costSessions += 1 }
        for (time, cost) in runCosts where time >= since { totals.costUSD += cost; totals.costSessions += 1 }
        return totals
    }

    private func entries(_ url: URL, size: Int, modified: Date) -> [Entry] {
        if let cached = cache[url.path], cached.size == size, cached.modified == modified { return cached.entries }
        var entries: [Entry] = []
        var seen = Set<String>()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let data = try? Data(contentsOf: url) {
            for line in data.split(separator: 0x0A) {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let message = event["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
                // Streaming writes one line per content block; each repeats the message's usage.
                if let id = message["id"] as? String, !seen.insert(id).inserted { continue }
                let stamp = (event["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? modified
                let count = { (key: String) in usage[key] as? Int ?? 0 }
                let output = count("output_tokens")
                entries.append(Entry(time: stamp, tokens: count("input_tokens") + output + count("cache_creation_input_tokens") + count("cache_read_input_tokens"), output: output))
            }
        }
        cache[url.path] = (size, modified, entries)
        return entries
    }
}

// MARK: - Plan limits and session costs (written by the status line)

struct PlanWindow: Codable, Equatable {
    var used: Double
    var resetsAt: Date
}

struct PlanLimits: Codable, Equatable {
    var captured: Date
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?

    static func file(in workspace: URL) -> URL { Routines.runnerFolder(in: workspace).appendingPathComponent("usage/latest.json") }
    static func load(in workspace: URL) -> PlanLimits? { Routines.load(PlanLimits?.self, from: file(in: workspace), default: nil) }
}

struct UsageSession: Codable, Equatable {
    var session: String
    var costUSD: Double
    var model: String
    var captured: Date

    static func folder(in workspace: URL) -> URL { Routines.runnerFolder(in: workspace).appendingPathComponent("usage/sessions") }
    static func loadAll(in workspace: URL) -> [UsageSession] {
        let folder = folder(in: workspace)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { Routines.load(UsageSession?.self, from: folder.appendingPathComponent($0), default: nil) }
    }
}

enum StatusLine {
    /// Handles one status line update: records plan limits and the session's cost, and returns the line to show.
    static func handle(input: Data, workspace: URL, now: Date = Date()) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return "" }
        let model = (json["model"] as? [String: Any])?["display_name"] as? String ?? ""
        let context = (json["context_window"] as? [String: Any])?["used_percentage"] as? Double
        func window(_ key: String) -> PlanWindow? {
            guard let raw = (json["rate_limits"] as? [String: Any])?[key] as? [String: Any],
                  let used = raw["used_percentage"] as? Double, let resets = raw["resets_at"] as? Double else { return nil }
            return PlanWindow(used: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let five = window("five_hour"), seven = window("seven_day")
        if five != nil || seven != nil {
            try? Routines.save(PlanLimits(captured: now, fiveHour: five, sevenDay: seven), to: PlanLimits.file(in: workspace))
        }
        if let session = json["session_id"] as? String, !session.isEmpty,
           let cost = (json["cost"] as? [String: Any])?["total_cost_usd"] as? Double, session.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil {
            try? Routines.save(UsageSession(session: session, costUSD: cost, model: model, captured: now),
                               to: UsageSession.folder(in: workspace).appendingPathComponent(session + ".json"))
        }
        var parts = [model].filter { !$0.isEmpty }
        if let context { parts.append("ctx \(Int(context.rounded()))%") }
        if let five { parts.append("5h \(Int(five.used.rounded()))%") }
        if let seven { parts.append("7d \(Int(seven.used.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    /// The settings entry that points a Claude profile's status line at the runner.
    static func command(runner: String, workspace: URL) -> String {
        LaunchCommand.shellQuote(runner) + " --statusline --workspace " + LaunchCommand.shellQuote(workspace.path)
    }

    /// Adds the status line to a profile's settings.json unless one is already configured. Returns true if it was added.
    @discardableResult
    static func install(in settingsFile: URL, runner: String, workspace: URL) throws -> Bool {
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any] else {
                throw AgentEnvironment.Failure(message: "\(settingsFile.path) is not a JSON object, so the status line was not added.")
            }
            settings = object
        }
        guard settings["statusLine"] == nil else { return false }
        settings["statusLine"] = ["type": "command", "command": command(runner: runner, workspace: workspace), "padding": 0]
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: settingsFile, options: .atomic)
        return true
    }
}
