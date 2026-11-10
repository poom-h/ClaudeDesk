import SwiftUI
import AppKit

struct AgentHomeView: View {
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @EnvironmentObject var store: DeskStore
    @State private var creating = false

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "person.crop.square").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("Your agents").font(.headline)
                        Text("A home for every assistant").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 20)
                Button { store.showTerminals = true } label: {
                    Label("Conversations (\(store.workspaceTerminals.count))", systemImage: "rectangle.split.2x2")
                        .frame(maxWidth: .infinity)
                }.controlSize(.large).padding(.horizontal, 12).disabled(store.workspaceTerminals.isEmpty)
                List(selection: $store.selectedAgentID) {
                    ForEach(store.agents) { agent in
                        Label(agent.name, systemImage: "person.crop.square").padding(.vertical, 6).tag(agent.id)
                    }
                }.listStyle(.sidebar)
                Button { creating = true } label: {
                    Label("Create agent", systemImage: "plus").frame(maxWidth: .infinity)
                }.controlSize(.large).padding(16).disabled(store.agentHostPath.isEmpty)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if store.showTerminals && !store.workspaceTerminals.isEmpty {
                TerminalWorkspace()
            } else if let agent = store.agents.first(where: { $0.id == store.selectedAgentID }) {
                AgentDetailView(agent: agent).id(agent.id)
            } else {
                ContentUnavailableView {
                    Label(store.agentHostPath.isEmpty ? "Choose a workspace for your agents" : "Create your first agent", systemImage: "person.crop.square.badge.plus")
                } description: {
                    Text(store.agentHostPath.isEmpty
                         ? "Choose a workspace folder once in Settings. Each agent will get its own environment, memory, and local configuration."
                         : "Your workspace is ready. Give an agent a name and purpose, then start a conversation.")
                } actions: {
                    if store.agentHostPath.isEmpty {
                        SettingsLink { Text("Set up workspace") }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Create agent") { creating = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onAppear { if store.showTerminals { sidebarVisibility = .detailOnly } }
        .onChange(of: store.showTerminals) { _, live in sidebarVisibility = live ? .detailOnly : .all }
        .onChange(of: store.selectedAgentID) { _, _ in store.showTerminals = false }
        .sheet(isPresented: $creating) { CreateAgentView() }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct CreateAgentView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var purpose = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create an agent").font(.title2.bold())
            Text("A persistent assistant with its own workspace and memory.").foregroundStyle(.secondary)
            TextField("Name", text: $name, prompt: Text("e.g. Research assistant"))
            Text("What should this agent help with?").font(.headline)
            TextEditor(text: $purpose).frame(height: 120).font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            Label(store.agentHostPath, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Creates a new folder with instructions, memory, files, and private Claude configuration. Your first conversation may ask you to sign in.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create environment") {
                    if store.createAgent(name: name, purpose: purpose) { dismiss() }
                    else { error = store.error; store.error = nil }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 510)
    }
}

private struct AgentDetailView: View {
    @EnvironmentObject var store: DeskStore
    let agent: AgentProfile
    @State private var document: AgentDocument?
    @State private var plugin = ""
    @State private var marketplace = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AGENT ENVIRONMENT").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        Text(agent.name).font(.largeTitle.bold())
                        Text(agent.purpose.isEmpty ? "Ready for a conversation." : agent.purpose).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("New conversation") { store.launchAgent(agent) }
                        Button("Continue latest") { store.launchAgent(agent, title: "\(agent.name) · continued", arguments: ["--continue"]) }
                        Button("Choose past conversation") { store.launchAgent(agent, title: "\(agent.name) · from history", arguments: ["--resume"]) }
                    } label: { Label("Talk to agent", systemImage: "bubble.left.and.bubble.right") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                HStack {
                    Button("New conversation") { store.launchAgent(agent) }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Open environment") { NSWorkspace.shared.open(URL(fileURLWithPath: agent.path)) }
                    Button("Open files") { NSWorkspace.shared.open(URL(fileURLWithPath: agent.path).appendingPathComponent("files")) }
                }
                Text(agent.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                Text("Memory & configuration").font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 12) {
                    ForEach(AgentDocument.allCases) { item in
                        Button { document = item } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.rawValue).font(.headline)
                                Text(item.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }.frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading).padding(16)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                Text("Save changes here, then start a new conversation to load them. To inspect additional memory files, open the environment’s memory folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                pluginControls
                Divider()
                Text("This agent uses a separate Claude profile for history, settings, and plugins. Its folder is the default workspace, not an operating-system sandbox. Claude still asks for its normal permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .sheet(item: $document) { item in AgentDocumentEditor(agent: agent, document: item) }
    }

    private var pluginControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plugins").font(.title3.bold())
                Spacer()
                Button("List installed") { store.launchAgent(agent, title: "Installed plugins", arguments: ["plugin", "list"]) }
            }
            Text("Manage plugins in this agent’s environment. Installation output and any confirmation prompts appear in an embedded terminal.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("plugin-name@marketplace", text: $plugin).textFieldStyle(.roundedBorder)
            HStack {
                Button("Install for this agent") { pluginCommand("install") }
                Button("Enable") { pluginCommand("enable") }
                Button("Disable") { pluginCommand("disable") }
            }.disabled(plugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            HStack {
                TextField("Marketplace source (owner/repo or URL)", text: $marketplace).textFieldStyle(.roundedBorder)
                Button("Add marketplace") {
                    store.launchAgent(agent, title: "Add marketplace", arguments: ["plugin", "marketplace", "add", "--", marketplace.trimmingCharacters(in: .whitespacesAndNewlines)])
                }.disabled(marketplace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func pluginCommand(_ action: String) {
        store.launchAgent(agent, title: "Plugin: \(action)", arguments: ["plugin", action, "--scope", "local", "--", plugin.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
}

struct AgentDocumentEditor: View {
    @Environment(\.dismiss) var dismiss
    let agent: AgentProfile
    let document: AgentDocument
    var onSaved: (() -> Void)? = nil
    @State private var text = ""
    @State private var original: String?
    @State private var error: String?
    @State private var saved = false
    @State private var loading = false
    @State private var discard = false
    @State private var reload = false
    private var dirty: Bool { original != nil && text != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(agent.name) · \(document.rawValue)").font(.title2.bold())
            Text(document.explanation).font(.callout).foregroundStyle(.secondary)
            Text(document.file).font(.caption.monospaced()).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .border(.secondary.opacity(0.3)).disabled(original == nil || loading)
            if loading { ProgressView("Loading document…").controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if saved { Text("Saved. New conversations will load these changes.").font(.caption).foregroundStyle(.green) }
            HStack {
                Button("Reload from disk") { if dirty { reload = true } else { load() } }.disabled(loading)
                Spacer()
                Button("Close") { if dirty { discard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let original else { return }
                    do {
                        try AgentEnvironment.save(text, document: document, agent: agent, original: original)
                        self.original = text; error = nil; saved = true
                        onSaved?()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut("s").disabled(!dirty || loading)
            }
        }.padding(24).frame(width: 700, height: 550)
        .onAppear(perform: load)
        .onChange(of: text) { _, _ in saved = false }
        .interactiveDismissDisabled(dirty)
        .alert("Discard unsaved changes?", isPresented: $discard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { dismiss() }
        }
        .alert("Reload and discard this draft?", isPresented: $reload) {
            Button("Keep editing", role: .cancel) {}
            Button("Reload", role: .destructive) { load() }
        }
    }

    private func load() {
        guard !loading else { return }
        loading = true
        let selectedAgent = agent, selectedDocument = document
        Task { @MainActor in
            let result = await Task.detached {
                Result { try AgentEnvironment.read(selectedDocument, agent: selectedAgent) }
            }.value
            switch result {
            case .success(let content):
                text = content; original = content; error = nil; saved = false
            case .failure(let failure): error = failure.localizedDescription
            }
            loading = false
        }
    }
}
