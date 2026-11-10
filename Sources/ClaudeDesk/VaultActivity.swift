import Foundation

/// A vault note an agent just looked at, for the Cockpit's light flare.
struct VaultRead: Equatable {
    var date: Date
    var agent: String
}

/// Finds which Memory Vault notes agents read or search: from atrium-memory's audit log, and, as a fallback, by
/// following their transcripts as they grow (direct reads and `@` imports put the note's full path in a transcript line).
enum VaultActivity {
    /// Vault-relative note paths (such as `Notes/LangGraph basics.md`) that appear in one transcript line.
    static func notes(in line: String, vaultPaths: [String]) -> [String] {
        var found: [String] = []
        for root in vaultPaths {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            var search = line.startIndex..<line.endIndex
            while let start = line.range(of: prefix, range: search) {
                // A path runs until a quote, backslash (JSON escape), or line break, and must end in .md.
                let rest = line[start.upperBound...]
                let end = rest.firstIndex { $0 == "\"" || $0 == "\\" || $0 == "\n" } ?? rest.endIndex
                let candidate = String(rest[..<end])
                if let md = candidate.range(of: ".md", options: .backwards) {
                    let path = String(candidate[..<md.upperBound])
                    if !path.hasPrefix("."), !path.contains("/."), !found.contains(path) { found.append(path) }
                }
                search = start.upperBound..<line.endIndex
            }
        }
        return found
    }

    /// atrium-memory's call log inside the vault.
    static func auditLog(in vault: URL) -> URL {
        vault.appendingPathComponent(".atrium-memory/audit.jsonl")
    }

    /// Notes one atrium-memory audit line shows an agent looking at: the note of a successful `vault_read`, or the
    /// results of a successful `vault_search`, with the caller's name. Nil for other tools, failures, and other lines.
    static func auditReads(in line: String, now: Date = Date(), maxAge: TimeInterval = 10) -> (actor: String, notes: [String])? {
        struct Entry: Decodable { var time: String?; var actor: String?; var tool: String?; var id: String?; var results: [String]?; var outcome: String? }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), entry.outcome == "ok",
              let stamp = entry.time.flatMap(auditTime), abs(now.timeIntervalSince(stamp)) <= maxAge else { return nil }
        switch entry.tool {
        case "vault_read": return entry.id.map { (actor: entry.actor ?? "", notes: [$0]) }
        case "vault_search": return (actor: entry.actor ?? "", notes: entry.results ?? [])
        default: return nil
        }
    }

    /// Graph IDs that match the audit notes, compared in NFC. Returns the graph's own IDs.
    static func graphIDs(for notes: [String], in graph: Set<String>) -> [String] {
        var byNFC: [String: String] = [:]
        for id in graph { byNFC[id.precomposedStringWithCanonicalMapping] = id }
        return notes.compactMap { byNFC[$0.precomposedStringWithCanonicalMapping] }
    }

    /// atrium-memory writes RFC 3339 UTC times, sometimes with nanoseconds. Only the whole seconds are read.
    private static func auditTime(_ text: String) -> Date? {
        guard text.hasSuffix("Z"), text.count >= 20 else { return nil }
        return wholeSecondFormatter.date(from: String(text.prefix(19)) + "Z")
    }

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Follows transcript files, returning only lines added since the last call. A file seen for the first time is
    /// read from the start only if it's brand new; older conversations aren't replayed.
    final class Tail {
        private var offsets: [String: UInt64] = [:]
        var newFileAge: TimeInterval = 90

        func newLines(in files: [URL], now: Date = Date()) -> [(URL, String)] {
            var lines: [(URL, String)] = []
            for file in files {
                // FileManager attributes, not URL resource values: those are cached per URL and go stale.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value else { continue }
                let key = file.path
                if offsets[key] == nil {
                    let isNew = (attributes[.creationDate] as? Date).map { now.timeIntervalSince($0) < newFileAge } ?? false
                    offsets[key] = isNew ? 0 : size
                }
                guard let offset = offsets[key], size > offset, let handle = try? FileHandle(forReadingFrom: file) else {
                    if let offset = offsets[key], size < offset { offsets[key] = size }   // truncated or replaced
                    continue
                }
                defer { try? handle.close() }
                try? handle.seek(toOffset: offset)
                // Cap one read so a huge burst can't stall the main thread; the rest is picked up next time.
                let data = handle.readData(ofLength: Int(min(size - offset, 4_000_000)))
                // Only complete lines; a line still being written is read next time.
                guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
                let complete = data[data.startIndex...lastNewline]
                offsets[key] = offset + UInt64(complete.count)
                for line in complete.split(separator: 0x0A) {
                    if let text = String(data: line, encoding: .utf8) { lines.append((file, text)) }
                }
            }
            return lines
        }
    }

    /// Transcripts changed in the last `window` seconds, for each agent profile.
    static func recentTranscripts(of agents: [AgentProfile], window: TimeInterval = 900, now: Date = Date()) -> [(AgentProfile, URL)] {
        let manager = FileManager.default
        var result: [(AgentProfile, URL)] = []
        for agent in agents {
            let projects = URL(fileURLWithPath: agent.configPath).appendingPathComponent("projects")
            for folder in (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if now.timeIntervalSince(modified) < window { result.append((agent, file)) }
                }
            }
        }
        return result
    }
}
