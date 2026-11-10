import Foundation

/// Appends one JSON line per event to `<workspace>/logs/YYYY-MM.jsonl`.
/// Only the app and the routine runner write here; entries hold pointers, never content.
enum ActivityLog {
    static func file(in workspace: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return workspace.appendingPathComponent("logs").appendingPathComponent(formatter.string(from: date) + ".jsonl")
    }

    static func append(workspace: URL, type: String, actor: String, subject: String,
                       outcome: String = "ok", details: [String: String] = [:], date: Date = Date()) throws {
        let entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: date),
            "type": type, "actor": actor, "subject": subject, "outcome": outcome, "details": details
        ]
        var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)
        let url = file(in: workspace, at: date)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
