import SwiftUI
import AppKit

struct InboxView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskTheme) private var theme
    @State private var selection: String?
    @State private var showArchive = false
    @State private var archived: [InboxItem] = []

    private var items: [InboxItem] { showArchive ? archived : store.inboxItems }
    private var selected: InboxItem? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(showArchive ? "Archive" : "Desk").font(.system(.title3, design: .monospaced).weight(.semibold))
                    Spacer()
                    Button(showArchive ? "Desk" : "Archive") { showArchive.toggle(); selection = nil; loadArchive() }.buttonStyle(.borderless)
                    Button { store.showInbox = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close the Desk (⌘I)")
                }.padding(14)
                Divider()
                if items.isEmpty {
                    ContentUnavailableView(showArchive ? "Nothing archived yet" : "Your Desk is clear", systemImage: "tray",
                                           description: Text(showArchive ? "Resolved items are kept here." : "Agents send requests, reports, and proposed skills here."))
                } else {
                    List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                        ForEach(items) { item in row(item).tag(item.id) }
                    }.listStyle(.sidebar)
                }
            }.frame(width: 300).background(theme.panel)
            Divider()
            if let item = selected {
                InboxItemDetail(item: item, readOnly: showArchive).id(item.id + (showArchive ? "-archive" : ""))
            } else {
                Color(nsColor: theme.background)
            }
        }
        .onChange(of: store.inboxItems) { _, _ in if showArchive { loadArchive() } }
    }

    private func row(_ item: InboxItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.problem != nil ? "exclamationmark.triangle" : InboxItemDetail.symbol(item.kind))
                .foregroundStyle(item.problem != nil ? Color.orange : theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2)
                Text("\(store.agent(matching: item.from)?.name ?? item.from) · \(item.kind)\(item.created.isEmpty ? "" : " · " + item.created)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 4)
    }

    private func loadArchive() {
        archived = store.inboxURL.map { Inbox.load(Inbox.archive(in: $0)) } ?? []
    }
}

struct InboxItemDetail: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskTheme) private var theme
    let item: InboxItem
    let readOnly: Bool
    @State private var note = ""
    @State private var disabled: Set<String> = []

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "skill": return "wand.and.stars"
        case "request": return "questionmark.bubble"
        case "message": return "envelope"
        case "routine": return "clock.badge.checkmark"
        case "memory": return "brain"
        case "alert": return "exclamationmark.octagon"
        default: return "doc"
        }
    }

    private var sender: AgentProfile? { store.agent(matching: item.from) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let problem = item.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(item.url.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                }
                if !item.body.isEmpty {
                    MarkdownView(item.body, context: MarkdownContext(base: item.url.deletingLastPathComponent(),
                                                                     root: store.inboxURL ?? item.url.deletingLastPathComponent(), accent: theme.accent))
                }
                if item.kind == "skill" && item.problem == nil { skillPreview }
                if item.kind == "memory" && item.problem == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ADDS TO \((sender?.name ?? item.from).uppercased())'S MEMORY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(item.memoryText).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if readOnly { archivedOutcome } else if item.problem == nil { decision } else {
                    HStack {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    }
                }
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: theme.background))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.kind.isEmpty ? "unknown" : item.kind.uppercased(), systemImage: Self.symbol(item.kind))
                .font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            Text(item.title).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 12) {
                Text("From \(item.from == "claudedesk" ? "ClaudeDesk" : sender?.name ?? (item.from.isEmpty ? "unknown" : item.from))")
                if item.via != "conversation" { Text(item.via) }
                if !item.created.isEmpty { Text(item.created) }
            }.font(.callout).foregroundStyle(.secondary)
            HStack {
                if !item.session.isEmpty && sender != nil {
                    Button { store.openConversation(for: item) } label: { Label("Open conversation", systemImage: "arrow.uturn.backward") }
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Label("Show file", systemImage: "doc.text") }
            }.buttonStyle(.borderless).font(.callout)
        }
    }

    @ViewBuilder private var skillPreview: some View {
        if let proposal = store.proposal(for: item) {
            VStack(alignment: .leading, spacing: 8) {
                Text("PROPOSED SKILL · \(proposal.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text((try? String(contentsOf: proposal.url.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? "")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                Button { NSWorkspace.shared.activateFileViewerSelecting([proposal.url]) } label: { Label("Reveal all files", systemImage: "folder") }
                    .buttonStyle(.borderless).font(.callout)
            }
        } else if !readOnly {
            Label("The proposed skill “\(item.skill)” isn't in \(sender?.name ?? item.from)'s skills-proposed folder.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var decision: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            if item.kind != "message" && item.kind != "alert" {
                callbackList("On approve", item.onApprove, key: "a")
                callbackList("On reject", item.onReject, key: "r")
                TextField(item.kind == "request" ? "Reply or reason (optional)" : "Reason (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                switch item.kind {
                case "message", "alert":
                    Button("Done") { act(.done) }.keyboardShortcut(.defaultAction)
                case "routine":
                    Button("Approve and switch on") { act(.approve) }.keyboardShortcut(.defaultAction)
                    Button("Reject", role: .destructive) { act(.reject) }
                case "memory":
                    Button("Append to memory") { act(.approve) }.keyboardShortcut(.defaultAction)
                    Button("Reject", role: .destructive) { act(.reject) }
                case "skill":
                    Button("Approve and attach") { act(.approve) }.keyboardShortcut(.defaultAction).disabled(store.proposal(for: item) == nil)
                    Button("Reject", role: .destructive) { act(.reject) }
                default:
                    ForEach(item.choices, id: \.self) { choice in Button(choice) { act(.choice(choice)) } }
                    if item.choices.isEmpty { Button("Approve") { act(.approve) }.keyboardShortcut(.defaultAction) }
                    Button("Send reply") { act(.reply) }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Reject", role: .destructive) { act(.reject) }
                }
            }.controlSize(.large)
        }
    }

    @ViewBuilder private func callbackList(_ title: String, _ callbacks: [InboxCallback], key: String) -> some View {
        if !callbacks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(callbacks) { callback in
                    Toggle(isOn: Binding(get: { callback.isKnown && !disabled.contains(key + String(callback.index)) },
                                         set: { on in if on { disabled.remove(key + String(callback.index)) } else { disabled.insert(key + String(callback.index)) } })) {
                        Text(callback.summary).fixedSize(horizontal: false, vertical: true)
                    }.disabled(!callback.isKnown).toggleStyle(.checkbox)
                }
            }
        }
    }

    private var archivedOutcome: some View {
        let record = Frontmatter.parse(item.raw)
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Outcome: \(record.text("status") ?? "unknown")\(record.text("resolved").map { " · " + $0 } ?? "")").font(.headline)
            if let reason = record.text("reason") { Text("Reason: \(reason)") }
            if let reply = record.text("reply") { Text("Reply: \(reply)") }
        }
    }

    private func act(_ decision: Inbox.Decision) {
        let callbacks = Inbox.callbacks(for: item, decision: decision)
        let key = decision == .reject ? "r" : "a"
        let enabled = Set(callbacks.map(\.index).filter { !disabled.contains(key + String($0)) })
        store.resolve(item, decision: decision, note: note, enabled: enabled)
    }
}
