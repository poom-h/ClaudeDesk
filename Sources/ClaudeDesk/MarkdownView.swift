import SwiftUI
import AppKit
import Charts

/// What interactive blocks can do. Only agent widgets get actions; elsewhere buttons and inputs show but stay inactive.
struct MarkdownActions {
    /// Starts a background run for the agent and returns its run ID.
    var run: (_ title: String, _ instruction: String, _ skill: String, _ webFetch: Bool) -> String?
    var toggle: (_ line: Int, _ checked: Bool) -> Void
    var agentName: String
}

/// Where relative links and images resolve, and how blocks look.
struct MarkdownContext {
    var base: URL
    /// Local images must stay inside this folder.
    var root: URL
    var actions: MarkdownActions?
    var fontSize: CGFloat = 13
    var maxImageHeight: CGFloat = 320
    var accent: Color = .accentColor
    /// Handles links before the usual rules, for example the note viewer following wikilinks. Return true when handled.
    var openLink: ((URL) -> Bool)?
}

/// The one Markdown renderer used by the Inbox, focus mode, and agent widgets.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let context: MarkdownContext

    init(_ text: String, context: MarkdownContext) { self.blocks = Markdown.parse(text); self.context = context }
    init(blocks: [MarkdownBlock], context: MarkdownContext) { self.blocks = blocks; self.context = context }

    var body: some View {
        VStack(alignment: .leading, spacing: context.fontSize * 0.7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in MarkdownBlockView(block: block, context: context) }
        }
        .font(.system(size: context.fontSize))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let openLink = context.openLink, openLink(url) { return .handled }
            return Self.open(url, root: context.root)
        })
    }

    /// Web, mail, and Obsidian links open normally; file links open only inside the item's own folder.
    static func open(_ url: URL, root: URL) -> OpenURLAction.Result {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "obsidian": NSWorkspace.shared.open(url); return .handled
        case "file":
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { return .discarded }
            NSWorkspace.shared.open(url); return .handled
        default: return .discarded
        }
    }

    static func inline(_ text: String, base: URL) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace), baseURL: base)) ?? AttributedString(text)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let context: MarkdownContext

    var body: some View {
        switch block {
        case .heading(let level, let text):
            let size = context.fontSize + [8, 5, 2, 1, 0, 0][min(5, level - 1)]
            Text(MarkdownView.inline(text, base: context.base))
                .font(.system(size: size, weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? context.fontSize * 0.3 : 0)
        case .paragraph(let text):
            Text(MarkdownView.inline(text, base: context.base)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        case .image(let alt, let source):
            MarkdownImage(alt: alt, url: Markdown.resolveImage(source, base: context.base, root: context.root), maxHeight: context.maxImageHeight)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in listRow(item) }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(context.accent.opacity(0.7)).frame(width: 3)
                MarkdownView(blocks: inner, context: context).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: context.fontSize - 1, design: .monospaced)).padding(10)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider().padding(.vertical, 2)
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, cell in Text(MarkdownView.inline(cell, base: context.base)).bold() } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(MarkdownView.inline(cell, base: context.base)) } }
                    }
                }.padding(.vertical, 2)
            }
        case .widget(let widget):
            WidgetBlockView(block: widget, context: context)
        }
    }

    private func listRow(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let checked = item.checked {
                Button { context.actions?.toggle(item.line, !checked) } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? context.accent : .secondary)
                }.buttonStyle(.plain).disabled(context.actions == nil)
            } else {
                Text(item.number ?? "•").foregroundStyle(.secondary).monospacedDigit()
            }
            Text(MarkdownView.inline(item.text, base: context.base))
                .strikethrough(item.checked == true).foregroundStyle(item.checked == true ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.leading, CGFloat(item.depth) * 14)
    }
}

// MARK: - Images

/// A remote (https) or local image, scaled to the column width. Shows its alt text when it can't load.
struct MarkdownImage: View {
    let alt: String
    let url: URL?
    var maxHeight: CGFloat = 320
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .help(alt)
            } else if failed || url == nil {
                Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)).frame(height: min(120, maxHeight))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let loaded = await MarkdownImageLoader.shared.image(for: url) { image = loaded }
        // A view that re-lays out cancels its task; that isn't a failure, and the download carries on for next time.
        else if !Task.isCancelled { failed = true }
    }
}

/// Loads each image once, shared by every view that shows it. Downloads run outside the views' tasks,
/// so a card that re-lays out mid-download doesn't cancel them.
@MainActor final class MarkdownImageLoader {
    static let shared = MarkdownImageLoader()
    private let cache = NSCache<NSString, NSImage>()
    private var loading: [NSString: Task<Data?, Never>] = [:]
    nonisolated private static let maxBytes = 15_000_000

    func image(for url: URL) async -> NSImage? {
        let key = Self.key(url)
        if let cached = cache.object(forKey: key) { return cached }
        let task = loading[key] ?? Task.detached { await Self.fetch(url) }
        loading[key] = task
        let data = await task.value
        loading[key] = nil
        guard let data, let result = NSImage(data: data) else { return nil }
        cache.setObject(result, forKey: key)
        return result
    }

    private static func key(_ url: URL) -> NSString {
        guard url.isFileURL else { return url.absoluteString as NSString }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(modified)" as NSString
    }

    nonisolated private static func fetch(_ url: URL) async -> Data? {
        var data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            if let (body, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.url?.scheme == "https" { data = body }
        }
        guard let data, data.count <= maxBytes else { return nil }
        return data
    }
}

// MARK: - Interactive and data blocks

private struct WidgetBlockView: View {
    @EnvironmentObject var store: DeskStore
    let block: MarkdownWidgetBlock
    let context: MarkdownContext
    @State private var runID: String?
    @State private var startedAt = Date.distantPast
    @State private var text = ""

    /// Running while the run is live, or for a few seconds after the click until the runner records it.
    private var running: Bool {
        guard let runID else { return false }
        if let run = store.liveRuns.first(where: { $0.runID == runID }) { return run.status == "running" }
        return Date().timeIntervalSince(startedAt) < 15
    }

    var body: some View {
        switch block.kind {
        case "button": button
        case "input": input
        case "stat": stat
        case "gauge": gauge
        case "chart": chart
        default: EmptyView()
        }
    }

    private func start(_ instruction: String, title: String) {
        guard let actions = context.actions, !instruction.isEmpty else { return }
        startedAt = Date()
        runID = actions.run(title, instruction, block.value("skill") ?? "", ["true", "yes"].contains(block.value("web")?.lowercased() ?? ""))
    }

    private var button: some View {
        let label = block.value("label") ?? "Run"
        let instruction = block.value("run") ?? ""
        return HStack(spacing: 8) {
            Button { start(instruction, title: label) } label: {
                HStack(spacing: 6) {
                    if running { ProgressView().controlSize(.mini) } else if let icon = block.value("icon") { Image(systemName: icon) }
                    Text(running ? "Working…" : label)
                }.padding(.horizontal, 4).frame(minHeight: 22)
            }
            .buttonStyle(.borderedProminent).tint(context.accent).controlSize(.regular)
            .disabled(context.actions == nil || running || instruction.isEmpty)
            .help(context.actions.map { "Asks \($0.agentName) to: \(instruction)" } ?? "Buttons work on the agent's Cockpit widget")
            if let note = block.value("note") { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var input: some View {
        let instruction = block.value("run") ?? ""
        func send() {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let filled = instruction.contains("{text}") ? instruction.replacingOccurrences(of: "{text}", with: value) : instruction + "\n\nThe user typed: " + value
            start(filled, title: block.value("label") ?? "Ask")
            text = ""
        }
        return HStack(spacing: 6) {
            TextField(block.value("placeholder") ?? "Type and press Return", text: $text)
                .textFieldStyle(.roundedBorder).onSubmit(send)
                .disabled(context.actions == nil || running)
            Button { send() } label: {
                if running { ProgressView().controlSize(.mini) } else { Text(block.value("label") ?? "Send") }
            }
            .disabled(context.actions == nil || running || text.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(context.actions.map { "Asks \($0.agentName) to: \(instruction)" } ?? "")
        }
    }

    private var stat: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = block.value("label") { Text(label.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary) }
            Text(block.value("value") ?? "–").font(.system(size: context.fontSize + 13, weight: .semibold, design: .rounded))
            if let note = block.value("note") { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var gauge: some View {
        let value = Double(block.value("value") ?? "") ?? 0
        let total = max(Double(block.value("max") ?? "") ?? 100, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(block.value("label") ?? "").font(.caption)
                Spacer()
                Text(block.value("note") ?? "\(Int((value / total * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(value, total), total: total).tint(value / total > 0.8 ? .orange : context.accent)
        }
    }

    private var chart: some View {
        let reserved: Set<String> = ["title", "type", "unit"]
        let points = block.fields.filter { !reserved.contains($0.key) }.compactMap { field -> (String, Double)? in
            Double(field.value.replacingOccurrences(of: ",", with: "")).map { (field.key, $0) }
        }
        let line = block.value("type")?.lowercased() == "line"
        return VStack(alignment: .leading, spacing: 6) {
            if let title = block.value("title") { Text(title).font(.caption.weight(.semibold)) }
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                if line {
                    LineMark(x: .value("Label", point.0), y: .value(block.value("unit") ?? "Value", point.1)).foregroundStyle(context.accent)
                    PointMark(x: .value("Label", point.0), y: .value(block.value("unit") ?? "Value", point.1)).foregroundStyle(context.accent)
                } else {
                    BarMark(x: .value("Label", point.0), y: .value(block.value("unit") ?? "Value", point.1)).foregroundStyle(context.accent)
                }
            }
            .frame(height: 120)
        }
    }
}
