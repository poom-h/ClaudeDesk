import Foundation

/// Plain-language steps from Claude's tool calls, shared by live runs and conversation activity.
enum RunSteps {
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String {
            guard let path = input[key] as? String, !path.isEmpty else { return "a file" }
            let parts = path.split(separator: "/")
            return parts.suffix(2).joined(separator: "/")
        }
        switch tool {
        case "Read": return "Reading \(file("file_path"))"
        case "Write": return "Writing \(file("file_path"))"
        case "Edit", "MultiEdit": return "Editing \(file("file_path"))"
        case "Glob", "Grep": return "Searching files"
        case "WebSearch": return "Searching the web" + ((input["query"] as? String).map { ": " + $0 } ?? "")
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a page"
            return "Opening \(host)"
        case "Bash":
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "Running " + (command.count > 48 ? String(command.prefix(48)) + "…" : command)
        case "Skill": return "Using skill " + (input["skill"] as? String ?? input["name"] as? String ?? "")
        case "Task", "Agent": return "Delegating to a subagent"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_").filter { !$0.isEmpty }
                return "Using \(parts.count > 1 ? String(parts[1]) : "a connector")"
            }
            return "Using \(tool)"
        }
    }

    /// The latest step described by one line of Claude's streaming JSON or transcript, if it has one.
    static func step(fromLine line: Data) -> String? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              event["type"] as? String == "assistant",
              let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content.reversed() {
            if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                return describe(tool: name, input: block["input"] as? [String: Any] ?? [:])
            }
        }
        if content.contains(where: { $0["type"] as? String == "text" }) { return "Writing a reply" }
        return nil
    }

    /// The most recent step in a transcript, reading only its last part.
    static func latestStep(inTranscript url: URL, tailBytes: Int = 200_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let data = handle.readDataToEndOfFile()
        for line in data.split(separator: 0x0A).reversed() {
            if let step = step(fromLine: Data(line)) { return step }
        }
        return nil
    }
}

/// A background run as the Cockpit sees it, written by the runner while the run is going.
struct LiveRun: Codable, Equatable, Identifiable {
    var runID: String
    var title: String
    var agentID: String
    var kind: String          // routine, shortcut, or capture
    var started: Date
    var pid: Int32 = 0
    var status = "running"    // running, ok, failed, timed-out, turn-limit, stopped
    var steps: [String] = []
    var result = ""
    var finished: Date?
    var id: String { runID }

    static func file(in workspace: URL, runID: String) -> URL {
        Routines.runs(in: workspace).appendingPathComponent(runID + ".live.json")
    }
    static func stopMarker(in workspace: URL, runID: String) -> URL {
        Routines.runs(in: workspace).appendingPathComponent(runID + ".stop")
    }

    /// Live runs still going, plus those that finished within `recent` seconds.
    static func load(in workspace: URL, now: Date = Date(), recent: TimeInterval = 300) -> [LiveRun] {
        let folder = Routines.runs(in: workspace)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".live.json") }
        return names.compactMap { Routines.load(LiveRun?.self, from: folder.appendingPathComponent($0), default: nil) }
            .filter { $0.status == "running" || now.timeIntervalSince($0.finished ?? $0.started) < recent }
            .sorted { $0.started > $1.started }
    }
}
