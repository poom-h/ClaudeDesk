import Foundation

/// A small reader and writer for the YAML front matter that inbox items and skills use.
/// It supports `key: value`, inline lists (`[a, b]`), and block lists whose items are
/// plain values or single `action: argument` pairs. Anything richer is kept as text.
enum Frontmatter {
    enum Value: Equatable {
        case text(String)
        case list([Item])

        var string: String? { if case .text(let value) = self { return value }; return nil }
        var items: [Item] {
            switch self {
            case .list(let items): return items
            case .text(let value) where value.isEmpty: return []
            case .text(let value): return [.text(value)]
            }
        }
    }

    enum Item: Equatable {
        case text(String)
        case pair(String, String)
    }

    struct Document {
        var fields: [String: Value]
        var body: String
        var hasFrontmatter: Bool
        func text(_ key: String) -> String? { fields[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    }

    static func parse(_ raw: String) -> Document {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let (block, body) = split(text) else { return Document(fields: [:], body: text, hasFrontmatter: false) }
        var fields: [String: Value] = [:]
        var listKey: String?
        for line in block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let key = listKey, trimmed.hasPrefix("- ") || trimmed == "-", line.first == " " || line.first == "-" {
                let entry = String(trimmed.dropFirst(trimmed == "-" ? 1 : 2))
                if case .list(var items) = fields[key] ?? .list([]) {
                    items.append(item(entry))
                    fields[key] = .list(items)
                }
                continue
            }
            guard line.first != " ", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                fields[key] = .list([])
                listKey = key
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                fields[key] = .list(splitInline(String(value.dropFirst().dropLast())).map { .text(unquote($0)) })
                listKey = nil
            } else {
                fields[key] = .text(unquote(value))
                listKey = nil
            }
        }
        return Document(fields: fields, body: body, hasFrontmatter: true)
    }

    /// Returns `raw` with each key set to its value: existing single-line keys are replaced
    /// in place, new keys are added before the closing `---`.
    static func setting(_ values: [(String, String)], in raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let (block, body) = split(text) else {
            return "---\n" + values.map { "\($0.0): \(quote($0.1))" }.joined(separator: "\n") + "\n---\n" + text
        }
        var lines = block.isEmpty ? [] : block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (key, value) in values {
            let line = "\(key): \(quote(value))"
            if let index = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
                // Drop a block list that belonged to the old value.
                var end = index + 1
                while end < lines.count, lines[end].first == " " || lines[end].hasPrefix("- ") { end += 1 }
                lines.replaceSubrange(index..<end, with: [line])
            } else { lines.append(line) }
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    static func quote(_ value: String) -> String {
        let plain = value.range(of: #"^[A-Za-z0-9_./@+-][A-Za-z0-9 _./@+:-]*$"#, options: .regularExpression) != nil
            && !value.hasSuffix(" ") && !value.contains(": ")
        if plain { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }

    private static func split(_ text: String) -> (String, String)? {
        guard text.hasPrefix("---\n") else { return nil }
        let rest = text.dropFirst(4)
        if rest.hasPrefix("---\n") { return ("", String(rest.dropFirst(4))) }
        if let close = rest.range(of: "\n---\n") { return (String(rest[..<close.lowerBound]), String(rest[close.upperBound...])) }
        if rest.hasSuffix("\n---") { return (String(rest.dropLast(4)), "") }
        return nil
    }

    private static func item(_ entry: String) -> Item {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        if !trimmed.hasPrefix("\""), !trimmed.hasPrefix("'"), let colon = trimmed.firstIndex(of: ":") {
            let key = String(trimmed[..<colon])
            if key.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil {
                return .pair(key, unquote(String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return .text(unquote(trimmed))
    }

    private static func splitInline(_ text: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character; current.append(character)
            } else if character == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else { current.append(character) }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var result = "", escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    result.append(character == "n" ? "\n" : character == "t" ? "\t" : character)
                    escaping = false
                } else if character == "\\" { escaping = true } else { result.append(character) }
            }
            return result
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}
