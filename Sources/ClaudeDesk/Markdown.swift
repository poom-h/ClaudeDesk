import Foundation

/// One list item. `line` is its line in the source text, so a checklist tick can be written back.
struct MarkdownListItem: Equatable {
    var text: String
    var number: String?      // "1." for ordered lists, nil for bullets
    var checked: Bool?       // nil unless the item is a `[ ]` or `[x]` checklist item
    var depth: Int
    var line: Int
}

/// An interactive or data block written as a fenced block, such as ```button.
/// Fields keep their order so chart values stay in the order the agent wrote them.
struct MarkdownWidgetBlock: Equatable {
    static let kinds = ["button", "input", "stat", "gauge", "chart"]
    var kind: String
    var fields: [(key: String, value: String)]

    func value(_ key: String) -> String? { fields.first { $0.key == key }?.value }

    static func == (a: MarkdownWidgetBlock, b: MarkdownWidgetBlock) -> Bool {
        a.kind == b.kind && a.fields.map { $0.key + "\u{0}" + $0.value } == b.fields.map { $0.key + "\u{0}" + $0.value }
    }
}

/// Block-level Markdown (GitHub style) parsed into a small tree. Inline formatting is left in the text
/// and rendered later. Raw HTML is not rendered: comments are dropped and other tags show as text.
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case image(alt: String, source: String)
    case list([MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String, text: String)
    case rule
    case table(header: [String], rows: [[String]])
    case widget(MarkdownWidgetBlock)
}

enum Markdown {
    static func parse(_ text: String, firstLine: Int = 0) -> [MarkdownBlock] {
        parse(lines: withoutComments(text).components(separatedBy: "\n"), firstLine: firstLine)
    }

    /// Removes `<!-- … -->` comments, keeping line count so checklist line numbers stay right.
    static func withoutComments(_ text: String) -> String {
        var result = "", rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            result += rest[..<open.lowerBound]
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else { rest = ""; break }
            result += String(repeating: "\n", count: rest[open.lowerBound..<close.upperBound].filter { $0 == "\n" }.count)
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    private static func parse(lines: [String], firstLine: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            // Fenced code, or an interactive block such as ```button
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[index]); index += 1 }
                index += 1
                if MarkdownWidgetBlock.kinds.contains(language) {
                    blocks.append(.widget(MarkdownWidgetBlock(kind: language, fields: fields(body))))
                } else {
                    blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                }
                continue
            }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); index += 1; continue }
            if isRule(trimmed) {
                // "Text\n===" is a setext heading; "---" after text stays a rule, which is what agents usually mean.
                if !paragraph.isEmpty, trimmed.hasPrefix("=") {
                    let text = paragraph.joined(separator: " ")
                    paragraph = []
                    blocks.append(.heading(level: 1, text: text))
                } else if trimmed.hasPrefix("=") { paragraph.append(line) } else { flush(); blocks.append(.rule) }
                index += 1; continue
            }
            if let image = image(trimmed) { flush(); blocks.append(image); index += 1; continue }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                let start = index
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var inner = current.dropFirst()
                    if inner.hasPrefix(" ") { inner = inner.dropFirst() }
                    quoted.append(String(inner))
                    index += 1
                }
                blocks.append(.quote(parse(lines: quoted, firstLine: firstLine + start)))
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableDivider(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[index].trimmingCharacters(in: .whitespaces))
                    row += Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if listItem(line, line: 0) != nil {
                flush()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    if let item = listItem(lines[index], line: firstLine + index) { items.append(item); index += 1; continue }
                    let next = lines[index]
                    // Indented continuation lines belong to the previous item.
                    if !items.isEmpty, next.hasPrefix("  "), !next.trimmingCharacters(in: .whitespaces).isEmpty {
                        items[items.count - 1].text += "\n" + next.trimmingCharacters(in: .whitespaces)
                        index += 1; continue
                    }
                    break
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.count == hashes || line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, text: text.replacingOccurrences(of: #"\s#+$"#, with: "", options: .regularExpression))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_=".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static let imagePattern = #"^\[?!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)(?:\]\([^)]*\))?$"#

    /// A line holding only an image, optionally wrapped in a link: `![alt](src)` or `[![alt](src)](href)`.
    private static func image(_ line: String) -> MarkdownBlock? {
        guard line.contains("!["), let regex = try? NSRegularExpression(pattern: imagePattern),
              let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let alt = Range(result.range(at: 1), in: line), let source = Range(result.range(at: 2), in: line) else { return nil }
        return .image(alt: String(line[alt]), source: String(line[source]))
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func listItem(_ line: String, line number: Int) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        var marker: String?
        var content = Substring("")
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            content = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            let after = rest.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count < 10, let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
            marker = digits + "."
            content = after.dropFirst(2)
        }
        var checked: Bool?
        let lower = content.prefix(4).lowercased()
        if lower == "[ ] " || lower == "[x] " { checked = lower == "[x] "; content = content.dropFirst(4) }
        return MarkdownListItem(text: String(content), number: marker, checked: checked, depth: indent / 2, line: number)
    }

    /// `key: value` lines inside an interactive block. A line without a key continues the previous value.
    static func fields(_ lines: [String]) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let colon = trimmed.firstIndex(of: ":"), trimmed[..<colon].count <= 32 {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result.append((key, value)); continue }
            }
            if !result.isEmpty { result[result.count - 1].value += (result[result.count - 1].value.isEmpty ? "" : " ") + trimmed }
        }
        return result
    }

    /// Where an image may be loaded from: https anywhere, or a relative path that stays inside `root`.
    /// http, file URLs, absolute paths, and paths that climb out of `root` are refused.
    static func resolveImage(_ source: String, base: URL, root: URL) -> URL? {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            return scheme == "https" && url.host != nil ? url : nil
        }
        guard !source.hasPrefix("/"), !source.hasPrefix("~") else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        let resolved = base.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.path.hasPrefix(rootPath + "/") ? resolved : nil
    }

    /// Plain text for summaries: no Markdown markers, link syntax reduced to its label.
    static func plain(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "`", "~~"] { value = value.replacingOccurrences(of: marker, with: "") }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
