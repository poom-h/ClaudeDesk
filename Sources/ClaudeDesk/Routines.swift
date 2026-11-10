import Foundation

/// When a routine runs, written as a plain phrase: `daily 08:30`, `weekdays 08:30`,
/// `mondays 09:00`, `every 6h`, `every 30m`, or `hourly`.
enum RoutineSchedule: Equatable {
    case daily(hour: Int, minute: Int)
    case weekdays(hour: Int, minute: Int)
    case weekly(weekday: Int, hour: Int, minute: Int)   // Calendar weekday: 1 = Sunday
    case every(minutes: Int)

    static let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func parse(_ raw: String) -> RoutineSchedule? {
        let words = raw.lowercased().split(separator: " ").map(String.init)
        if words == ["hourly"] { return .every(minutes: 60) }
        if words.count == 2, words[0] == "every", let amount = Int(words[1].dropLast()), amount > 0 {
            switch words[1].last {
            case "m": return .every(minutes: amount)
            case "h": return .every(minutes: amount * 60)
            default: return nil
            }
        }
        guard words.count == 2, let (hour, minute) = time(words[1]) else { return nil }
        if words[0] == "daily" { return .daily(hour: hour, minute: minute) }
        if words[0] == "weekdays" { return .weekdays(hour: hour, minute: minute) }
        let day = words[0].hasSuffix("s") ? String(words[0].dropLast()) : words[0]
        if let index = dayNames.firstIndex(of: day) { return .weekly(weekday: index + 1, hour: hour, minute: minute) }
        return nil
    }

    private static func time(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    var minimumIntervalMinutes: Int {
        switch self {
        case .daily, .weekdays: return 24 * 60
        case .weekly: return 7 * 24 * 60
        case .every(let minutes): return minutes
        }
    }

    /// The most recent scheduled time at or before `now` (calendar schedules only).
    func lastOccurrence(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        guard let (hour, minute) = clock else { return nil }
        for back in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate <= now, matches(candidate, calendar: calendar) else { continue }
            return candidate
        }
        return nil
    }

    func next(after now: Date, lastRun: Date?, calendar: Calendar = .current) -> Date? {
        if case .every(let minutes) = self { return lastRun.map { max(now, $0.addingTimeInterval(Double(minutes) * 60)) } ?? now }
        guard let (hour, minute) = clock else { return nil }
        for ahead in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: now),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate > now, matches(candidate, calendar: calendar) else { continue }
            return candidate
        }
        return nil
    }

    /// Due when a scheduled time has passed since the last run and since approval. A missed time runs once.
    func isDue(now: Date, lastRun: Date?, approvedAt: Date, calendar: Calendar = .current) -> Bool {
        if case .every(let minutes) = self {
            guard let lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= Double(minutes) * 60
        }
        guard let occurrence = lastOccurrence(atOrBefore: now, calendar: calendar) else { return false }
        return occurrence > max(lastRun ?? .distantPast, approvedAt)
    }

    private var clock: (Int, Int)? {
        switch self {
        case .daily(let hour, let minute), .weekdays(let hour, let minute), .weekly(_, let hour, let minute): return (hour, minute)
        case .every: return nil
        }
    }

    private func matches(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        switch self {
        case .daily, .every: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekly(let day, _, _): return weekday == day
        }
    }
}

struct Routine: Identifiable, Equatable {
    static let defaultMaxTurns = 30
    static let defaultTimeoutSeconds = 15 * 60
    static let knownTools = ["web-fetch"]

    let name: String
    var agent = ""
    var scheduleText = ""
    var schedule: RoutineSchedule?
    var skill = ""
    var maxTurns = Routine.defaultMaxTurns
    var timeoutSeconds = Routine.defaultTimeoutSeconds
    var enabled = true
    var tools: [String] = []
    var output = ""
    var prompt = ""
    var section = ""
    var problem: String?
    var id: String { name }

    /// The fields that need approval when they change (Q25), as a stable string.
    var fingerprint: String {
        "\(agent.lowercased())|\(schedule?.minimumIntervalMinutes ?? 0)|\(maxTurns)|\(timeoutSeconds)|\(tools.sorted().joined(separator: ","))"
    }
}

/// What the user approved for a routine; edits beyond it pause the routine until approved again.
struct RoutineGrant: Codable, Equatable {
    var agent: String
    var minimumIntervalMinutes: Int
    var maxTurns: Int
    var timeoutSeconds: Int
    var tools: [String]
    var approvedAt: Date
}

struct RoutineApprovals: Codable, Equatable {
    var grants: [String: RoutineGrant] = [:]
    var rejected: [String: String] = [:]   // routine name -> fingerprint that was rejected
}

struct RoutineRunState: Codable, Equatable {
    var lastRun: Date?
    var lastOutcome: String?
    var lastRunID: String?
    var requestedFingerprint: String?
}

struct RunnerState: Codable, Equatable {
    var day = ""
    var runsToday = 0
    var capAlertDay: String?
    var lastPass: Date?
    var routines: [String: RoutineRunState] = [:]
}

struct RoutineRequest: Codable, Equatable {
    var routine: String
    var requestedBy: String
    var time: Date
    var note: String = ""
}

/// A one-off background run the user started from the Cockpit: a skill shortcut or a quick capture.
/// Clicking is the approval, so it skips Inbox approval and the daily routine cap.
struct ManualRun: Codable, Equatable {
    var runID = UUID().uuidString.lowercased()
    var kind: String          // shortcut, capture, widget, or ask
    var title: String
    var agent: String
    var skill = ""
    var request = ""          // the instruction or captured text
    var webFetch = false

    var routine: Routine {
        var routine = Routine(name: ["capture": "quick-capture", "ask": "ask"][kind] ?? (skill.isEmpty ? "shortcut" : skill))
        routine.agent = agent
        routine.skill = skill
        routine.prompt = request
        routine.tools = webFetch ? ["web-fetch"] : []
        return routine
    }
}

enum Routines {
    static let maxRunsPerDay = 20
    static let definitionsFolder = "routines"
    static let fileName = "routines.md"

    static func folder(in workspace: URL) -> URL { workspace.appendingPathComponent(definitionsFolder) }
    static func file(in workspace: URL) -> URL { folder(in: workspace).appendingPathComponent(fileName) }
    /// Runner records live where agents have no access, so they can't approve their own routines.
    static func runnerFolder(in workspace: URL) -> URL { workspace.appendingPathComponent(".claudedesk") }
    static func queue(in workspace: URL) -> URL { runnerFolder(in: workspace).appendingPathComponent("queue") }
    static func runs(in workspace: URL) -> URL { runnerFolder(in: workspace).appendingPathComponent("runs") }
    static func approvalsFile(in workspace: URL) -> URL { runnerFolder(in: workspace).appendingPathComponent("approved.json") }
    static func stateFile(in workspace: URL) -> URL { runnerFolder(in: workspace).appendingPathComponent("state.json") }

    static let template = """
    # Routines

    Scheduled work for ClaudeDesk agents. Each routine is a `##` section: property lines, then the prompt.
    The background runner checks this file every 5 minutes while your Mac is awake.

    Properties: `agent` (required), `schedule` (required: `daily 08:30`, `weekdays 08:30`, `mondays 09:00`,
    `every 6h`, `every 30m`, `hourly`), `skill`, `max_turns` (default 30), `timeout` (default 15m),
    `enabled` (yes/no), `tools` (`web-fetch`), `output`.

    New routines, a different agent, running more often than hourly, higher limits, or extra tools wait for
    approval in the ClaudeDesk Inbox. Prompt and time-of-day edits apply right away.

    Example (remove the backticks to use it):

    ```markdown
    ## heartbeat
    - agent: atlas
    - schedule: daily 08:30
    - skill: heartbeat

    Run your heartbeat routine for today.
    ```

    """

    static func parse(_ raw: String) -> [Routine] {
        var routines: [Routine] = []
        var current: [String] = []
        var heading: String?
        var inFence = false
        func flush() {
            guard let name = heading else { return }
            var routine = parseSection(name: name, lines: current)
            if routines.contains(where: { $0.name == routine.name }) { routine.problem = "Another routine already uses the name \(routine.name)." }
            routines.append(routine)
        }
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                current = []
            } else if heading != nil { current.append(line) }
        }
        flush()
        return routines
    }

    private static func parseSection(name: String, lines: [String]) -> Routine {
        var routine = Routine(name: name)
        routine.section = (["## " + name] + lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var problems: [String] = []
        if !SkillLibrary.isValidName(name) { problems.append("Routine names use lowercase letters, numbers, and hyphens.") }
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else { break }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = Frontmatter.unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            switch key {
            case "agent": routine.agent = value
            case "schedule":
                routine.scheduleText = value
                routine.schedule = RoutineSchedule.parse(value)
                if routine.schedule == nil { problems.append("“\(value)” is not a schedule this runner understands.") }
            case "skill": routine.skill = value
            case "max_turns":
                if let turns = Int(value), (1...200).contains(turns) { routine.maxTurns = turns } else { problems.append("max_turns must be a number from 1 to 200.") }
            case "timeout":
                if let seconds = duration(value), (60...4 * 3600).contains(seconds) { routine.timeoutSeconds = seconds } else { problems.append("timeout must be between 1m and 4h, such as 15m.") }
            case "enabled": routine.enabled = !["no", "false", "off"].contains(value.lowercased())
            case "tools":
                routine.tools = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                let unknown = routine.tools.filter { !Routine.knownTools.contains($0) }
                if !unknown.isEmpty { problems.append("Unknown tools: \(unknown.joined(separator: ", ")). Known: \(Routine.knownTools.joined(separator: ", ")).") }
            case "output": routine.output = value
            default: problems.append("Unknown property “\(key)”.")
            }
            index += 1
        }
        routine.prompt = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if routine.agent.isEmpty { problems.append("Missing agent.") }
        if routine.scheduleText.isEmpty { problems.append("Missing schedule.") }
        if routine.prompt.isEmpty && routine.skill.isEmpty { problems.append("Add a prompt or a skill.") }
        routine.problem = problems.isEmpty ? nil : problems.joined(separator: " ")
        return routine
    }

    static func duration(_ text: String) -> Int? {
        guard let unit = text.last, let amount = Int(text.dropLast()), amount > 0 else { return nil }
        switch unit {
        case "s": return amount
        case "m": return amount * 60
        case "h": return amount * 3600
        default: return nil
        }
    }

    /// Why a routine needs approval before it may run; empty when the current grant covers it.
    static func approvalReasons(_ routine: Routine, grant: RoutineGrant?) -> [String] {
        guard let grant else { return ["new routine"] }
        var reasons: [String] = []
        let interval = routine.schedule?.minimumIntervalMinutes ?? 0
        if routine.agent.lowercased() != grant.agent.lowercased() { reasons.append("runs as a different agent (\(routine.agent))") }
        if interval < 60 && interval < grant.minimumIntervalMinutes { reasons.append("runs more often than hourly") }
        if routine.maxTurns > Routine.defaultMaxTurns && routine.maxTurns > grant.maxTurns { reasons.append("turn limit raised to \(routine.maxTurns)") }
        if routine.timeoutSeconds > Routine.defaultTimeoutSeconds && routine.timeoutSeconds > grant.timeoutSeconds { reasons.append("time limit raised to \(routine.timeoutSeconds / 60)m") }
        let added = Set(routine.tools).subtracting(grant.tools)
        if !added.isEmpty { reasons.append("adds tools: \(added.sorted().joined(separator: ", "))") }
        return reasons
    }

    static func grant(for routine: Routine, at date: Date = Date()) -> RoutineGrant {
        RoutineGrant(agent: routine.agent, minimumIntervalMinutes: routine.schedule?.minimumIntervalMinutes ?? 0,
                     maxTurns: routine.maxTurns, timeoutSeconds: routine.timeoutSeconds, tools: routine.tools, approvedAt: date)
    }

    // MARK: Records

    static func load<T: Decodable>(_ type: T.Type, from url: URL, default value: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return value }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(T.self, from: data)) ?? value
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Queues one run. Returns false, and queues nothing, when the routine is already queued or running,
    /// so a double click or a repeated Inbox follow-up never runs it twice.
    @discardableResult
    static func enqueue(_ name: String, requestedBy: String, note: String = "", workspace: URL, now: Date = Date()) throws -> Bool {
        guard busy(name, workspace: workspace, now: now) == nil else { return false }
        let request = RoutineRequest(routine: name, requestedBy: requestedBy, time: now, note: note)
        try save(request, to: queue(in: workspace).appendingPathComponent(UUID().uuidString + ".json"))
        return true
    }

    /// "queued" while a request for the routine waits in the queue, "running" while a run of it is still going, otherwise nil.
    /// A live record whose process has gone (for example after a crash) doesn't count as running.
    static func busy(_ name: String, workspace: URL, now: Date = Date()) -> String? {
        let folder = queue(in: workspace)
        let requests = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
        if requests.contains(where: { load(RoutineRequest?.self, from: folder.appendingPathComponent($0), default: nil)?.routine == name }) { return "queued" }
        let running = LiveRun.load(in: workspace, now: now).contains { run in
            guard run.kind == "routine", run.title == name, run.status == "running" else { return false }
            return run.pid > 0 ? kill(run.pid, 0) == 0 : now.timeIntervalSince(run.started) < 120
        }
        return running ? "running" : nil
    }

    /// Records a decision on a routine approval request. Approval covers the routine exactly as it is now.
    static func decide(_ name: String, fingerprint: String, approve: Bool, workspace: URL, now: Date = Date()) throws {
        var approvals = load(RoutineApprovals.self, from: approvalsFile(in: workspace), default: RoutineApprovals())
        if approve {
            guard let routine = parse((try? String(contentsOf: file(in: workspace), encoding: .utf8)) ?? "").first(where: { $0.name == name }) else {
                throw AgentEnvironment.Failure(message: "routines.md no longer has a routine named \(name).")
            }
            guard routine.fingerprint == fingerprint else {
                throw AgentEnvironment.Failure(message: "The routine \(name) changed after this request was filed. Reject this request; the runner files a new one for the current version.")
            }
            approvals.grants[name] = grant(for: routine, at: now)
            approvals.rejected[name] = nil
        } else { approvals.rejected[name] = fingerprint }
        try save(approvals, to: approvalsFile(in: workspace))
    }
}
