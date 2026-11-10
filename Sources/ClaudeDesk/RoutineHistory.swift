import Foundation

/// One routine run, rebuilt from the activity log's `routine.*` events.
struct RoutineRunRecord: Identifiable, Equatable {
    let runID: String
    let routine: String
    let started: Date
    var finished: Date?
    /// running (no finish event yet), ok, failed, timed-out, turn-limit, stopped, no-agent
    var outcome = "running"
    var seconds: Int?
    var cost: Double?
    /// Started by Run now or an Inbox follow-up rather than the schedule.
    var manual = false
    var items: [String] = []
    var id: String { runID }
    var succeeded: Bool { outcome == "ok" || outcome == "stopped" }
}

enum RoutineHistory {
    /// Routine runs that started on or after `since`, oldest first. Reads each monthly log the range covers.
    static func load(workspace: URL, since: Date, now: Date = Date()) -> [RoutineRunRecord] {
        var records: [String: RoutineRunRecord] = [:]
        let formatter = ISO8601DateFormatter()
        for file in logFiles(workspace: workspace, since: since, now: now) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"type\":\"routine.") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = object["type"] as? String, let subject = object["subject"] as? String,
                      let time = (object["time"] as? String).flatMap(formatter.date(from:)),
                      let details = object["details"] as? [String: String], let run = details["run"] else { continue }
                switch type {
                case "routine.started":
                    var record = records[run] ?? RoutineRunRecord(runID: run, routine: subject, started: time)
                    record.manual = (details["requested"] ?? "schedule") != "schedule"
                    records[run] = record
                case "routine.finished", "routine.failed", "routine.timed-out":
                    // A run that failed before starting (no agent) has only this event.
                    var record = records[run] ?? RoutineRunRecord(runID: run, routine: subject, started: time)
                    record.finished = time
                    record.outcome = (object["outcome"] as? String) ?? (type == "routine.finished" ? "ok" : "failed")
                    record.seconds = details["seconds"].flatMap(Int.init)
                    record.cost = details["cost"].flatMap(Double.init)
                    record.items = (details["items"] ?? "").split(separator: ",").map(String.init)
                    records[run] = record
                default: continue
                }
            }
        }
        return records.values.filter { $0.started >= since }.sorted { ($0.started, $0.runID) < ($1.started, $1.runID) }
    }

    /// The monthly log files from `since` through `now`.
    static func logFiles(workspace: URL, since: Date, now: Date) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        var files: [URL] = []
        var month = since
        while true {
            let file = ActivityLog.file(in: workspace, at: month)
            if !files.contains(file) { files.append(file) }
            guard let next = calendar.date(byAdding: .month, value: 1, to: month),
                  calendar.compare(next, to: now, toGranularity: .month) != .orderedDescending else { break }
            month = next
        }
        return files
    }

    /// Changes whenever any log file in the range changes, so callers reload only then.
    static func signature(workspace: URL, since: Date, now: Date = Date()) -> String {
        logFiles(workspace: workspace, since: since, now: now).map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(file.lastPathComponent):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    /// "45s", "3m 20s", "1h 05m".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h \(String(format: "%02d", seconds % 3600 / 60))m"
    }
}
