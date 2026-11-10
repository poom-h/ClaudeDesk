import SwiftUI
import AppKit

@main
struct ClaudeDeskApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var store = DeskStore()
    @AppStorage("appMode") private var appMode = "cockpit"

    private func workspaceAction(_ action: String) { NotificationCenter.default.post(name: .workspaceAction, object: action) }

    var body: some Scene {
        // A WindowGroup always opens a window at launch when none is restored; a single `Window` scene
        // can come back closed after quitting, leaving the app running with nothing on screen.
        WindowGroup("ClaudeDesk", id: "main") {
            ModeRootView().environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { AppLifecycle.store = store }

        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { store.addProject() }.keyboardShortcut("n")
            }
            CommandMenu("Workspace") {
                Button("Cockpit") { withAnimation(.smooth(duration: 0.55)) { appMode = "cockpit" } }.keyboardShortcut("1")
                Button("Studio") { withAnimation(.smooth(duration: 0.55)) { appMode = "studio" } }.keyboardShortcut("2")
                Divider()
                Button("Desk") { store.showInbox.toggle() }.keyboardShortcut("i")
                Divider()
                Button("Focus Active Pane") { workspaceAction("focus") }.keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Reset Layout") { workspaceAction("reset") }.keyboardShortcut("0", modifiers: [.command, .shift])
                Button("Next Pane") { workspaceAction("next") }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Previous Pane") { workspaceAction("previous") }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
                ForEach(0..<9) { index in
                    Button("Select Pane \(index + 1)") { workspaceAction(String(index)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                }
            }
        }
        Settings { SettingsView().environmentObject(store) }
    }
}

struct DeskView: View {
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.deskTheme) private var theme
    @EnvironmentObject private var store: DeskStore
    @AppStorage("claudeExecutable") private var executable = ""
    @State private var search = ""
    @State private var editing: DeskSession?
    @State private var editingProject: UUID?
    @State private var removing: Project?

    private var selected: Project? { store.projects.first { $0.id == store.selectedID } }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("ClaudeDesk").font(.headline)
                        Text("A place for every session").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 20)
                Button { store.showTerminals = true } label: {
                    Label("Live workspace (\(store.workspaceTerminals.count))", systemImage: "rectangle.split.2x2")
                        .frame(maxWidth: .infinity)
                }.controlSize(.large).padding(.horizontal, 12).disabled(store.workspaceTerminals.isEmpty)
                List(selection: $store.selectedID) {
                    Section("PROJECTS") {
                        ForEach(store.projects) { project in
                            Label {
                                HStack {
                                    Text(project.name).lineLimit(1)
                                    Spacer()
                                    Text("\(project.sessions.count)").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "folder") }
                            .padding(.vertical, 6).tag(project.id)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
                                Button("Remove Project…", role: .destructive) { removing = project }
                            }
                        }
                    }
                }.listStyle(.sidebar)
                Button(action: store.addProject) {
                    Label("Add project", systemImage: "plus").frame(maxWidth: .infinity)
                }.controlSize(.large).padding(16)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if store.showTerminals && !store.workspaceTerminals.isEmpty {
                TerminalWorkspace()
            } else if let project = selected {
                projectDetail(project)
            } else {
                ContentUnavailableView {
                    Label("Make room for your ideas", systemImage: "terminal")
                } description: {
                    Text("Add a project folder, name your Claude sessions,\nand open them together when you’re ready to work.")
                } actions: {
                    Button("Add your first project", action: store.addProject).buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .onAppear { if store.showTerminals { sidebarVisibility = .detailOnly } }
        .onChange(of: store.showTerminals) { _, live in sidebarVisibility = live ? .detailOnly : .all }
        .onChange(of: store.selectedID) { _, _ in store.showTerminals = false }
        .sheet(item: $editing) { session in
            SessionEditor(session: session) { updated in
                if let id = editingProject { store.update(updated, in: id) }
            }
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Remove project?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let project = removing { store.removeProject(project.id) }
                removing = nil
            }
        } message: { Text("This removes the saved project and session shortcuts. Your files and running instances are kept.") }
    }

    private func projectDetail(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("YOUR WORKSPACE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    Text(project.name).font(.system(size: 32, weight: .bold))
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                    } label: { Label(project.path, systemImage: "folder").lineLimit(1).truncationMode(.middle) }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.launch(project.sessions, in: project, executableOverride: executable) }
                } label: { Label("Open all", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(project.sessions.isEmpty || store.launching)
            }.padding(30)
            Divider()
            HStack {
                Text("Sessions").font(.title3.weight(.semibold))
                Text("\(project.sessions.count)").foregroundStyle(.secondary)
                Spacer()
                TextField("Find a session", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Button {
                    editingProject = project.id
                    editing = DeskSession(name: "")
                } label: { Label("New session", systemImage: "plus") }
            }.padding(.horizontal, 30).padding(.vertical, 22)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 16)], spacing: 16) {
                    ForEach(project.sessions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.prompt.localizedCaseInsensitiveContains(search) }) { session in
                        sessionCard(session, project: project)
                    }
                }.padding(.horizontal, 30).padding(.bottom, 24)
                if project.sessions.isEmpty {
                    ContentUnavailableView("Your next task starts here", systemImage: "plus.rectangle", description: Text("Create a named session for a feature, review, or experiment."))
                } else if !search.isEmpty && !project.sessions.contains(where: { $0.name.localizedCaseInsensitiveContains(search) || $0.prompt.localizedCaseInsensitiveContains(search) }) {
                    ContentUnavailableView.search(text: search)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if store.launching { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.up.forward.app") }
                Text(store.launching ? "Starting Claude…" : (store.notice ?? "Sessions run inside the live workspace."))
                Spacer()
                Text("\(project.sessions.count) saved").foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).padding(16)
        }
        .background(Color(nsColor: theme.background))
    }

    private func sessionCard(_ session: DeskSession, project: Project) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "terminal").font(.title2).foregroundStyle(.tint)
                    .frame(width: 42, height: 42).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                Menu {
                    Button("Edit session") { editingProject = project.id; editing = session }
                    Button("Duplicate") {
                        store.update(DeskSession(name: session.name + " copy", prompt: session.prompt), in: project.id)
                    }
                    Button("Remove shortcut", role: .destructive) { store.removeSession(session.id, from: project.id) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(session.name).font(.headline).lineLimit(1)
                Text(session.prompt.isEmpty ? "An open canvas. Start a conversation with Claude." : session.prompt)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3).frame(height: 54, alignment: .topLeading)
            }
            HStack {
                if let date = session.lastOpened {
                    Text("Opened \(date.formatted(.relative(presentation: .named)))").lineLimit(1)
                } else { Text("Ready when you are") }
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await store.launch([session], in: project, executableOverride: executable) }
            } label: { Label("Open Claude", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
            .controlSize(.large).disabled(store.launching)
        }.padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.07)))
    }
}

struct SessionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var session: DeskSession
    var onSave: (DeskSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(session.name.isEmpty ? "New session" : "Edit session").font(.title2.bold())
            Text("Give each line of work a home.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $session.name, prompt: Text("e.g. Frontend, Tests, Code review"))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Starting prompt (optional)")
                    TextEditor(text: $session.prompt).font(.body).frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    Text("Sent to Claude each time you open this shortcut. Each launch starts a new conversation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save session") {
                    session.name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(session)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 490)
    }
}

struct SettingsView: View {
    @AppStorage("deskTheme") private var themeName = DeskTheme.space.rawValue
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @EnvironmentObject private var store: DeskStore
    @AppStorage("claudeExecutable") private var executable = ""
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            IntegrationsSettings().environmentObject(store).tabItem { Label("Integrations", systemImage: "key") }
        }
        .frame(width: 600)
        .preferredColorScheme((DeskTheme(rawValue: themeName) ?? .claude).dark ? .dark : .light)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance").font(.headline)
            Picker("Theme", selection: $themeName) {
                ForEach(DeskTheme.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            HStack {
                Text("Terminal font · \(Int(fontSize)) pt")
                Slider(value: $fontSize, in: 6...32, step: 1)
                Button("Reset") { fontSize = 13 }
            }
            Divider()
            Text("Workspace folder").font(.headline)
            Text(store.workspacePath.isEmpty ? "Choose where ClaudeDesk keeps your agents, memory vault, and skill library" : store.workspacePath)
                .font(.callout).textSelection(.enabled)
            if store.workspacePath.isEmpty && !store.legacyAgentHostPath.isEmpty {
                Text("Agents currently live in \(store.legacyAgentHostPath). Choose a workspace to add the memory vault and skill library.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(store.workspacePath.isEmpty ? "Choose folder…" : "Change folder…", action: store.chooseWorkspace)
            Text("ClaudeDesk keeps agents in \(Workspace.agentsFolder)/, the memory vault in \(Workspace.vaultFolder)/, and skills in \(Workspace.skillsFolder)/. Missing folders are created; existing ones are never changed. Changing the workspace does not move existing agents.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(isOn: Binding(get: { store.runnerEnabled }, set: { store.setRunner(enabled: $0) })) {
                Text("Run routines in the background").font(.headline)
            }.toggleStyle(.switch).disabled(store.workspacePath.isEmpty)
            Text("Runs due routines from routines.md every 5 minutes while your Mac is awake. Manage them from the clock button in the sidebar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Claude Code").font(.headline)
            TextField("Executable path", text: $executable, prompt: Text("Auto-detect"))
            Text("Leave blank to check ~/.local/bin, /opt/homebrew/bin, and /usr/local/bin. You can also paste the full path from `which claude`.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Claude runs inside the app with its normal permissions and sign-in. Multiple instances share their project folder; each has an independent terminal.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Memory Vault tools").font(.headline)
            Text("Agents read and change the Memory Vault through atrium-memory, which is built into ClaudeDesk. To use it in your own Claude sessions too, copy this setup into a project's .mcp.json.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Copy MCP config") {
                guard let executable = MemoryTool.bundledExecutable else { return }
                let vault = Workspace.vault(in: URL(fileURLWithPath: store.workspacePath))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MemoryTool.projectConfig(executable: executable, vault: vault), forType: .string)
            }.disabled(store.workspacePath.isEmpty || MemoryTool.bundledExecutable == nil)
        }.padding(24)
    }
}

/// Keys and accounts for integrations. Secrets go straight into the Keychain and are never shown again.
struct IntegrationsSettings: View {
    @EnvironmentObject private var store: DeskStore
    @AppStorage("jevModel") private var jevModel = ""
    @State private var revision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Jev · TypeSafe", "Categorises your email: one small typed judgment per message. About $0.00002 a message.") {
                    SecretField(title: "API key", key: Secrets.Key.jevAPIKey, prompt: "ts-…", revision: $revision)
                    HStack {
                        Text("Model").frame(width: 120, alignment: .leading)
                        TextField("Model", text: $jevModel, prompt: Text(JevTriage.defaultModel)).textFieldStyle(.roundedBorder)
                    }
                    Link("Get an API key at typesafe.ai", destination: URL(string: "https://typesafe.ai")!).font(.caption)
                }
                section("Mail and calendar", "Read-only. ClaudeDesk never sends, moves or deletes mail, or changes your calendar.") {
                    Picker("Source", selection: $store.mailSource) {
                        Text("This Mac (Apple Mail and Calendar)").tag("mac")
                        Text("Google API (advanced)").tag("google")
                    }
                    .onChange(of: store.mailSource) { _, _ in store.mailMessages = []; store.calendarEvents = []; store.refreshMail() }
                    if store.mailSource == "mac" {
                        Text("Uses the accounts on your Mac, so there's nothing to sign in to here and they stay connected.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 8) {
                            Text("1.").monospacedDigit()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Add your Gmail in Internet Accounts with **Mail** and **Calendars** on, and open Apple Mail once so it syncs.")
                                Button("Open Internet Accounts") { MacAccounts.openInternetAccounts() }
                            }
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Text("2.").monospacedDigit()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allow ClaudeDesk to read them. macOS asks about your calendars now, and about Mail on the first fetch.")
                                HStack {
                                    Button(store.macMailConnected ? "Allowed · check again" : "Allow access") { store.connectMacAccounts() }
                                    Button("Refresh now") { store.refreshMail() }.disabled(!store.macMailConnected || store.mailRefreshing)
                                    if store.mailRefreshing { ProgressView().controlSize(.small) }
                                }
                            }
                        }
                        if store.macMailConnected {
                            let found = store.mailAccountList
                            Text(found.isEmpty ? "No accounts found yet." : "Found: " + found.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !store.mailStatus.isEmpty { Text(store.mailStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                if store.mailSource == "google" {
                section("Google API", "Connects straight to Gmail and Google Calendar with your own Google Cloud OAuth client.") {
                    SecretField(title: "OAuth client ID", key: Secrets.Key.googleClientID, prompt: "…apps.googleusercontent.com", revision: $revision)
                    SecretField(title: "Client secret", key: Secrets.Key.googleClientSecret, prompt: "GOCSPX-…", revision: $revision)
                    DisclosureGroup("How to get these (one time, about 5 minutes)") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Open console.cloud.google.com and create a project, for example “ClaudeDesk”.")
                            Text("2. APIs & Services › Library: enable **Gmail API** and **Google Calendar API**.")
                            Text("3. OAuth consent screen: choose External (or Internal for a Google Workspace organisation) and add the accounts you'll connect as test users.")
                            Text("4. Credentials › Create credentials › OAuth client ID › **Desktop app**. Paste its client ID and secret above.")
                            Text("While the app is in Testing, Google signs accounts out after 7 days; Internal apps, or publishing the app, avoid that.")
                                .foregroundStyle(.secondary)
                        }.font(.caption).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
                    }.font(.callout)
                    Divider()
                    Text("ACCOUNTS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                    if store.googleAccounts.isEmpty { Text("No accounts yet.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(store.googleAccounts, id: \.self) { account in
                        HStack {
                            Image(systemName: "person.crop.circle")
                            Text(account)
                            Spacer()
                            Button("Remove", role: .destructive) { store.removeGoogleAccount(account) }
                                .help("Signs this account out of ClaudeDesk and forgets its mail")
                        }
                    }
                    HStack {
                        Button { store.addGoogleAccount() } label: { Label("Add Google account", systemImage: "plus") }
                            .disabled(!(Secrets.has(Secrets.Key.googleClientID) && Secrets.has(Secrets.Key.googleClientSecret)))
                            .help("Opens Google's sign-in in your browser")
                        Button("Refresh now") { store.refreshMail() }.disabled(store.googleAccounts.isEmpty || store.mailRefreshing)
                        if store.mailRefreshing { ProgressView().controlSize(.small) }
                    }
                    if !store.mailStatus.isEmpty { Text(store.mailStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                }
                Text("Keys, secrets and sign-ins are stored in your macOS Keychain on this Mac only, not in files or iCloud. After ClaudeDesk updates, macOS may ask once to let it use them; choose Always Allow.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .frame(height: 620)
        .id(revision)
    }

    private func section<Content: View>(_ title: String, _ note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}

/// One secret: "Saved" with Replace and Remove, or a masked field to enter it. The saved value is never shown.
private struct SecretField: View {
    let title: String
    let key: String
    let prompt: String
    @Binding var revision: Int
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let saved = Secrets.has(key)
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            if saved && !editing {
                Label("Saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text("••••••••").foregroundStyle(.secondary)
                Spacer()
                Button("Replace") { editing = true }
                Button("Remove", role: .destructive) {
                    Secrets.remove(key)
                    if key == Secrets.Key.jevAPIKey { Task { await JevKey.shared.forget() } }
                    revision += 1
                }
            } else {
                SecureField(title, text: $draft, prompt: Text(prompt)).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if editing { Button("Cancel") { editing = false; draft = "" } }
            }
        }
    }

    private func save() {
        guard Secrets.set(draft, for: key) else { return }
        if key == Secrets.Key.jevAPIKey { Task { await JevKey.shared.forget() } }
        draft = ""
        editing = false
        revision += 1
    }
}
