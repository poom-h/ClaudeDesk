import Foundation

/// A follow-up the app runs after you resolve an inbox item. Only these actions exist;
/// anything else an agent writes is shown as unsupported and never run.
struct InboxCallback: Hashable, Identifiable {
    static let known = ["resume", "new-conversation", "run-routine", "none"]
    let index: Int
    let action: String
    let argument: String
    var id: Int { index }
    var isKnown: Bool { Self.known.contains(action) }

    var summary: String {
        switch action {
        case "resume": return argument.isEmpty ? "Reopen the conversation it came from" : "Reopen the conversation it came from and send: \(argument)"
        case "new-conversation": return "Start a new conversation with: \(argument)"
        case "run-routine": return "Run the routine \(argument.isEmpty ? "it came from" : "“" + argument + "”") once now (picked up within 5 minutes)"
        case "none": return "Nothing else"
        default: return "Unsupported action “\(action)” (will not run)"
        }
    }
}

struct InboxItem: Identifiable, Hashable {
    static let kinds = ["skill", "request", "message", "routine", "memory", "alert"]
    static let laterKinds = ["draft"]

    let url: URL
    let raw: String
    let kind: String
    let from: String
    let via: String
    let session: String
    let title: String
    let created: String
    let skill: String
    /// A subject label such as `news`, used by Cockpit widgets to find digests.
    let topic: String
    /// For routine items: the routine and the exact version the approval covers.
    let routine: String
    let fingerprint: String
    /// For memory items: the text proposed for appending to the agent's MEMORY.md.
    let memoryText: String
    let choices: [String]
    let onApprove: [InboxCallback]
    let onReject: [InboxCallback]
    let body: String
    let problem: String?
    var id: String { url.lastPathComponent }
}

enum Inbox {
    typealias Failure = AgentEnvironment.Failure

    enum Decision: Equatable {
        case approve, reject, choice(String), reply, done

        var status: String {
            switch self {
            case .approve: return "approved"
            case .reject: return "rejected"
            case .choice, .reply: return "answered"
            case .done: return "done"
            }
        }
        var label: String {
            switch self {
            case .approve: return "approve"
            case .reject: return "reject"
            case .choice(let value): return "choice: " + value
            case .reply: return "reply"
            case .done: return "done"
            }
        }
    }

    static func archive(in inbox: URL) -> URL { inbox.appendingPathComponent("archive") }

    static func load(_ folder: URL) -> [InboxItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return parse(url: url, text: "")
            }
            return parse(url: url, text: text)
        }.sorted { a, b in
            // Alerts first, then newest first.
            if (a.kind == "alert") != (b.kind == "alert") { return a.kind == "alert" }
            return (a.created, a.id) > (b.created, b.id)
        }
    }

    static func parse(url: URL, text: String) -> InboxItem {
        let document = Frontmatter.parse(text)
        let kind = document.text("kind") ?? ""
        let from = document.text("from") ?? ""
        var problem: String?
        if !document.hasFrontmatter { problem = "This file has no properties block, so the app can't tell what it is." }
        else if kind.isEmpty { problem = "This item has no kind." }
        else if InboxItem.laterKinds.contains(kind) { problem = "“\(kind)” items arrive in a later version of ClaudeDesk." }
        else if !InboxItem.kinds.contains(kind) { problem = "“\(kind)” is not a known kind (\(InboxItem.kinds.joined(separator: ", ")))." }
        else if from.isEmpty { problem = "This item doesn't say which agent sent it (from)." }
        else if kind == "skill" && (document.text("skill") ?? "").isEmpty { problem = "This skill item doesn't name the proposed skill (skill)." }
        else if kind == "routine" && ((document.text("routine") ?? "").isEmpty || (document.text("fingerprint") ?? "").isEmpty) {
            problem = "This routine item doesn't say which routine version it approves."
        }
        let memoryText = memoryBlock(in: document.body)
        if problem == nil, kind == "memory", memoryText.isEmpty { problem = "This memory item has no ```memory block with the text to add." }
        func callbacks(_ key: String) -> [InboxCallback] {
            (document.fields[key]?.items ?? []).enumerated().map { index, item in
                switch item {
                case .pair(let action, let argument): return InboxCallback(index: index, action: action, argument: argument)
                case .text(let action): return InboxCallback(index: index, action: action, argument: "")
                }
            }
        }
        let choices = (document.fields["choices"]?.items ?? []).compactMap { item -> String? in
            if case .text(let value) = item, !value.isEmpty { return value }; return nil
        }
        return InboxItem(url: url, raw: text, kind: kind, from: from, via: document.text("via") ?? "conversation",
                         session: document.text("session") ?? "", title: document.text("title") ?? url.deletingPathExtension().lastPathComponent,
                         created: document.text("created") ?? "", skill: document.text("skill") ?? "", topic: document.text("topic") ?? "",
                         routine: document.text("routine") ?? routineName(via: document.text("via") ?? ""),
                         fingerprint: document.text("fingerprint") ?? "", memoryText: memoryText, choices: choices,
                         onApprove: callbacks("on_approve"), onReject: callbacks("on_reject"),
                         body: document.body.trimmingCharacters(in: .whitespacesAndNewlines), problem: problem)
    }

    static func routineName(via: String) -> String { via.hasPrefix("routine:") ? String(via.dropFirst(8)) : "" }

    /// The text inside the first ```memory fenced block.
    static func memoryBlock(in body: String) -> String {
        guard let open = body.range(of: "```memory\n") else { return "" }
        guard let close = body.range(of: "\n```", range: open.upperBound..<body.endIndex) else { return "" }
        return String(body[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The callbacks that belong to a decision. Choices and replies continue like an approval.
    static func callbacks(for item: InboxItem, decision: Decision) -> [InboxCallback] {
        switch decision {
        case .approve, .choice, .reply: return item.onApprove
        case .reject: return item.onReject
        case .done: return []
        }
    }

    static func fill(_ text: String, note: String, decision: Decision) -> String {
        var choice = ""
        if case .choice(let value) = decision { choice = value }
        return text.replacingOccurrences(of: "{reason}", with: note)
            .replacingOccurrences(of: "{reply}", with: note)
            .replacingOccurrences(of: "{choice}", with: choice)
    }

    /// Fails when the file changed since the item was loaded, so a decision never applies to text you didn't see.
    static func checkUnchanged(_ item: InboxItem) throws {
        let current = try? String(contentsOf: item.url, encoding: .utf8)
        guard current == item.raw else {
            throw Failure(message: "This item changed or moved since it was shown. It has been reloaded; review it again.")
        }
    }

    /// Records the outcome in the item and moves it to `archive/`. Returns the archived file.
    static func resolve(_ item: InboxItem, decision: Decision, note: String, now: Date = Date()) throws -> URL {
        try checkUnchanged(item)
        var values: [(String, String)] = [("status", decision.status), ("resolved", ISO8601DateFormatter().string(from: now)), ("decision", decision.label)]
        if !note.isEmpty { values.append((decision == .reject ? "reason" : "reply", note)) }
        let updated = Frontmatter.setting(values, in: item.raw)
        let folder = archive(in: item.url.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(item.url.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + "-\(counter).md")
            counter += 1
        }
        try updated.write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: item.url)
        moveImages(of: item, to: folder)
        return destination
    }

    /// Relative images an item uses (such as `assets/hero.jpg`) move into the archive with it, so they still resolve there.
    /// An image another waiting item still uses is copied instead of moved.
    static func moveImages(of item: InboxItem, to archive: URL) {
        let manager = FileManager.default
        let inbox = item.url.deletingLastPathComponent()
        let others = load(inbox).map(\.body).joined(separator: "\n")
        for source in Set(imageSources(in: item.body)) where URL(string: source)?.scheme == nil && !source.hasPrefix("/") {
            let relative = source.removingPercentEncoding ?? source
            let from = inbox.appendingPathComponent(relative).standardizedFileURL
            guard from.path.hasPrefix(inbox.standardizedFileURL.path + "/"), !from.path.hasPrefix(archive.standardizedFileURL.path + "/"),
                  manager.fileExists(atPath: from.path) else { continue }
            let to = archive.appendingPathComponent(relative).standardizedFileURL
            guard !manager.fileExists(atPath: to.path) else { continue }
            try? manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if imageSources(in: others).contains(source) { try? manager.copyItem(at: from, to: to) } else { try? manager.moveItem(at: from, to: to) }
        }
    }

    /// Image sources in Markdown text (`![alt](source)`).
    static func imageSources(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*<?([^)\s>]+)"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Adds a line under "## Callbacks" in an archived item, recording what each follow-up did.
    static func note(_ line: String, in archived: URL) {
        guard var text = try? String(contentsOf: archived, encoding: .utf8) else { return }
        if !text.contains("\n## Callbacks\n") { text += (text.hasSuffix("\n") ? "" : "\n") + "\n## Callbacks\n" }
        text += "- " + line + "\n"
        try? text.write(to: archived, atomically: true, encoding: .utf8)
    }
}
