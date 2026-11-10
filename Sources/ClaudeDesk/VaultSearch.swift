import Foundation

/// Quick search over the Memory Vault for the Cockpit graph: titles first, then paths, then note text.
enum VaultSearch {
    struct Entry: Equatable {
        var id: String        // vault-relative path, the graph's node ID
        var title: String
        var body: String
    }

    struct Result: Equatable, Identifiable {
        var id: String
        var title: String
        var snippet: String
        var score: Int
    }

    /// Every word of the query must appear in the title, path, or text. Best matches first, then by title.
    static func search(_ query: String, in entries: [Entry], limit: Int = 50) -> [Result] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terms = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return entries.compactMap { entry -> Result? in
            let title = entry.title.lowercased(), path = entry.id.lowercased(), body = entry.body.lowercased()
            guard terms.allSatisfy({ title.contains($0) || path.contains($0) || body.contains($0) }) else { return nil }
            var score = 0
            if title == phrase { score += 1000 } else if title.hasPrefix(phrase) { score += 600 } else if title.contains(phrase) { score += 400 }
            for term in terms {
                if title.contains(term) { score += title.hasPrefix(term) || title.contains(" " + term) ? 120 : 80 }
                else if path.contains(term) { score += 40 }
                score += min(20, occurrences(of: term, in: body) * 4)
            }
            return Result(id: entry.id, title: entry.title, snippet: snippet(for: terms, in: entry.body), score: score)
        }
        .sorted { ($0.score, $1.title.lowercased()) > ($1.score, $0.title.lowercased()) }
        .prefix(limit).map { $0 }
    }

    /// About 90 characters of text around the first matching word, on one line, with ellipses where it's cut.
    static func snippet(for terms: [String], in body: String, width: Int = 90) -> String {
        let flat = body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let lower = flat.lowercased()
        // Offsets in the lowercased text only map back when lowercasing kept the length (it usually does).
        guard lower.count == flat.count, let hit = terms.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return String(flat.prefix(width))
        }
        let offset = lower.distance(from: lower.startIndex, to: hit.lowerBound)
        let start = max(0, offset - width / 3)
        let from = flat.index(flat.startIndex, offsetBy: start)
        let to = flat.index(from, offsetBy: min(width, flat.distance(from: from, to: flat.endIndex)))
        return (start > 0 ? "…" : "") + flat[from..<to] + (to < flat.endIndex ? "…" : "")
    }

    /// Searchable text of a note: its Markdown without the properties block.
    static func entry(id: String, title: String, url: URL) -> Entry {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Entry(id: id, title: title, body: readable(Frontmatter.parse(text).body, title: title))
    }

    /// Note text as it reads, for matching and snippets: no Markdown marks, wikilinks as their label,
    /// and no opening heading that just repeats the title.
    static func readable(_ markdown: String, title: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].trimmingCharacters(in: .whitespaces).hasPrefix("#"),
           lines[first].trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() == title.lowercased() {
            lines.remove(at: first)
        }
        var text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, with: "$2", options: .regularExpression)   // [[Note|label]] -> label
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)          // [label](url) -> label
        text = text.replacingOccurrences(of: #"(?m)^\s*(#{1,6}|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)  // line markers
        // Underscores stay: they're usually part of names such as create_agent, not emphasis.
        return text.replacingOccurrences(of: #"[*`~]"#, with: "", options: .regularExpression)
    }

    private static func occurrences(of term: String, in text: String) -> Int {
        var count = 0, search = text.startIndex..<text.endIndex
        while let found = text.range(of: term, range: search) { count += 1; search = found.upperBound..<text.endIndex }
        return count
    }
}

/// Wikilinks for the built-in note viewer: which note a `[[link]]` means, and Markdown with links it can follow.
enum VaultNotes {
    static let linkScheme = "claudedesk-note"

    /// Note IDs by file name without `.md`, lowercased, the way wikilinks name notes.
    static func stems(_ notes: [(id: String, url: URL)]) -> [String: String] {
        Dictionary(notes.map { ($0.url.deletingPathExtension().lastPathComponent.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    /// The note a wikilink target points to: `Folder/Name#Heading` and `Name.md` both find `Name`.
    static func resolve(_ target: String, stems: [String: String]) -> String? {
        var name = target.split(separator: "|").first.map(String.init) ?? target
        name = name.split(separator: "#").first.map(String.init) ?? name
        name = name.split(separator: "/").last.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
        return stems[name]
    }

    private static let wikilink = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)

    /// Notes this Markdown links to, in order, each once.
    static func outgoing(_ markdown: String, stems: [String: String]) -> [String] {
        var found: [String] = []
        for match in wikilink.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let range = Range(match.range(at: 1), in: markdown), let id = resolve(String(markdown[range]), stems: stems),
                  !found.contains(id) else { continue }
            found.append(id)
        }
        return found
    }

    /// Markdown with each `[[Target|label]]` as a normal link the viewer can follow. Links to notes that don't
    /// exist stay as plain text.
    static func linkified(_ markdown: String, stems: [String: String]) -> String {
        var result = "", last = markdown.startIndex
        for match in wikilink.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let whole = Range(match.range, in: markdown), let inner = Range(match.range(at: 1), in: markdown) else { continue }
            result += markdown[last..<whole.lowerBound]
            let target = String(markdown[inner])
            let parts = target.split(separator: "|", maxSplits: 1).map(String.init)
            let label = parts.count > 1 ? parts[1] : (parts.first ?? target).split(separator: "#").first.map(String.init) ?? target
            if let id = resolve(target, stems: stems), let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                result += "[\(label)](\(linkScheme):\(encoded))"
            } else {
                result += label
            }
            last = whole.upperBound
        }
        return result + markdown[last...]
    }

    /// The note ID inside a viewer link, or nil for any other URL.
    static func noteID(from url: URL) -> String? {
        guard url.scheme == linkScheme else { return nil }
        return url.absoluteString.dropFirst(linkScheme.count + 1).removingPercentEncoding
    }

    /// The note's body for reading: without its properties block or an opening heading that repeats the title.
    static func body(of text: String, title: String) -> String {
        var lines = Frontmatter.parse(text).body.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# "), lines[first].dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased() == title.lowercased() {
            lines.remove(at: first)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
