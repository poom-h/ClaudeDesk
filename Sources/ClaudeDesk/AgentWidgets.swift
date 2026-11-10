import Foundation

/// A Cockpit widget an agent designs itself: one Markdown file in `<agent>/widgets/`.
/// The card part shows on the Cockpit; everything after `<!-- full -->` shows only in focus mode.
struct AgentWidget: Identifiable, Equatable {
    let agentFolder: String      // the agent's folder name, as stored in cockpit.json
    let agentName: String
    let name: String             // file name without .md
    let url: URL
    let title: String
    let symbol: String
    let width: Double
    let card: [MarkdownBlock]
    let full: [MarkdownBlock]
    let modified: Date
    var id: String { agentFolder + "/" + name }
    var folder: URL { url.deletingLastPathComponent() }
}

enum AgentWidgets {
    static let folderName = "widgets"
    static let fullMarker = "<!-- full -->"
    static let widths: [String: Double] = ["small": 270, "medium": 360, "wide": 460]

    static func folder(of agent: AgentProfile) -> URL { URL(fileURLWithPath: agent.path).appendingPathComponent(folderName) }

    /// Every widget file of every agent, ordered by agent then name.
    static func load(agents: [AgentProfile]) -> [AgentWidget] {
        agents.flatMap { agent -> [AgentWidget] in
            let folder = folder(of: agent)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted().compactMap { name in
                let url = folder.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return parse(text, url: url, agentFolder: URL(fileURLWithPath: agent.path).lastPathComponent, agentName: agent.name, modified: modified)
            }
        }
    }

    static func parse(_ text: String, url: URL, agentFolder: String, agentName: String, modified: Date = .distantPast) -> AgentWidget {
        let document = Frontmatter.parse(text)
        let name = url.deletingPathExtension().lastPathComponent
        // Line numbers in blocks are file lines, so a checklist tick lands on the right line.
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n")
        let bodyStart = raw.hasSuffix(document.body) ? raw.dropLast(document.body.count).filter { $0 == "\n" }.count : 0
        var card = document.body, full = ""
        var fullStart = bodyStart
        if let marker = document.body.range(of: fullMarker) {
            card = String(document.body[..<marker.lowerBound])
            full = String(document.body[marker.upperBound...])
            fullStart = bodyStart + card.filter { $0 == "\n" }.count
        }
        let widthText = (document.text("width") ?? "small").lowercased()
        let width = widths[widthText] ?? Double(widthText).map { min(640, max(220, $0)) } ?? 270
        return AgentWidget(agentFolder: agentFolder, agentName: agentName, name: name, url: url,
                           title: document.text("title") ?? name.replacingOccurrences(of: "-", with: " ").capitalized,
                           symbol: document.text("icon") ?? "square.grid.2x2", width: width,
                           card: Markdown.parse(card, firstLine: bodyStart), full: Markdown.parse(full, firstLine: fullStart), modified: modified)
    }

    /// A cheap fingerprint of every widget file, so the Cockpit reloads only when one changes.
    static func signature(agents: [AgentProfile]) -> String {
        agents.map { agent -> String in
            let folder = folder(of: agent)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
            return names.map { name -> String in
                let values = try? folder.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return "\(agent.path)/\(name):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
            }.joined(separator: "|")
        }.joined(separator: "#")
    }

    /// Ticks or unticks one checklist line, only if it still reads as expected.
    static func setChecked(_ checked: Bool, line: Int, in url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line), let item = Markdown.listItem(lines[line], line: line), item.checked != nil else {
            throw AgentEnvironment.Failure(message: "The widget changed before the tick was saved. Try again.")
        }
        let current = lines[line]
        let pattern = #"\[( |x|X)\]"#
        guard let range = current.range(of: pattern, options: .regularExpression) else { return }
        lines[line] = current.replacingCharacters(in: range, with: checked ? "[x]" : "[ ]")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The instruction a widget button or input sends to its agent's background run.
    static func request(for widget: AgentWidget, instruction: String) -> String {
        """
        The user clicked a control on your Cockpit widget “\(widget.title)” (file: `\(widget.url.path)`).
        \(instruction)

        When the result belongs on the widget, update that file (see the `widget-instructions` skill). Keep the file valid; the Cockpit reloads it within seconds.
        """
    }
}
