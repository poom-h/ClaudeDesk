import SwiftUI
import AppKit

private struct SidebarDocument: Identifiable {
    let agent: AgentProfile
    let document: AgentDocument
    var id: String { agent.id.uuidString + document.rawValue }
}

struct ModeRootView: View {
    @EnvironmentObject var store: DeskStore
    @AppStorage("deskTheme") private var themeName = DeskTheme.space.rawValue
    @AppStorage("claudeExecutable") private var executable = ""
    /// "cockpit" or "studio"; clicking the app title switches between them.
    @AppStorage("appMode") private var appMode = "cockpit"
    @AppStorage("cockpitReduceMotion") private var cockpitReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var integrations = false
    /// Which environment the Plugins & MCP sheet opens on: "global", or an agent or project ID.
    @State private var integrationsTarget = "global"
    @State private var creatingAgent = false
    @State private var creatingSkill = false
    @State private var document: SidebarDocument?
    @State private var editing: DeskSession?
    @State private var editingProject: UUID?
    @State private var removingProject: Project?
    /// The Space Studio's own sidebar toggle, since it doesn't use the system split view.
    @AppStorage("studioSidebarShown") private var sidebarShown = true
    private var theme: DeskTheme { DeskTheme(rawValue: themeName) ?? .space }
    private var agent: AgentProfile? { store.agents.first { $0.id == store.selectedAgentID } }
    private var project: Project? { store.projects.first { $0.id == store.selectedID } }

    var body: some View {
        ZStack {
        if appMode == "cockpit" {
            // Zooming out into space: the Cockpit settles in from slightly larger, the Studio recedes.
            CockpitView()
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.06)),
                                        removal: .opacity.combined(with: .scale(scale: 1.04))))
                .zIndex(1)
        } else {
        if theme.isSpace {
            spaceStudio
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                        removal: .opacity.combined(with: .scale(scale: 0.95))))
        } else {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebarColumn.background(theme.panel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detail
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                removal: .opacity.combined(with: .scale(scale: 0.95))))
        }
        }
        }
        .animation(cockpitReduceMotion || systemReduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.55), value: appMode)
        .onAppear {
            // The Studio's new look: switch to Space once. The older themes stay in Settings.
            if !UserDefaults.standard.bool(forKey: "studioSpaceTheme.v1") {
                UserDefaults.standard.set(true, forKey: "studioSpaceTheme.v1")
                themeName = DeskTheme.space.rawValue
            }
        }
        .environment(\.deskTheme, theme)
        .tint(theme.accent)
        .preferredColorScheme(theme.dark ? .dark : .light)
        .sheet(isPresented: $integrations) { IntegrationsView(initialTarget: integrationsTarget).environmentObject(store) }
        .sheet(isPresented: $creatingAgent) { CreateAgentView().environmentObject(store) }
        .sheet(isPresented: $creatingSkill) { NewSkillView().environmentObject(store) }
        .sheet(isPresented: $store.showRoutines) { RoutinesView().environmentObject(store) }
        .sheet(item: $document) { item in
            AgentDocumentEditor(agent: item.agent, document: item.document) {
                store.log("agent.edited", subject: item.agent.name, details: ["agent": item.agent.id.uuidString, "document": item.document.file])
            }
        }
        .sheet(item: $editing) { session in
            SessionEditor(session: session) { updated in
                if let id = editingProject { store.update(updated, in: id) }
            }
        }
        .alert("Remove project?", isPresented: Binding(get: { removingProject != nil }, set: { if !$0 { removingProject = nil } })) {
            Button("Cancel", role: .cancel) { removingProject = nil }
            Button("Remove", role: .destructive) {
                if let item = removingProject { store.removeProject(item.id) }
                removingProject = nil
            }
        } message: { Text("Removes saved shortcuts. Your files and running terminals are kept.") }
        .alert("Set up your workspace folder?", isPresented: Binding(get: { store.workspaceMigration != nil }, set: { _ in })) {
            Button("Use This Folder") { if let path = store.workspaceMigration { store.useWorkspace(path) } }
            Button("Choose Another…") { store.chooseWorkspace() }
            Button("Keep Current Setup", role: .cancel) { store.declineWorkspaceMigration() }
        } message: {
            Text("ClaudeDesk now keeps agents, the memory vault, and the skill library in one workspace folder.\n\nUse \(store.workspaceMigration ?? "")? Any missing \(Workspace.agentsFolder), \(Workspace.vaultFolder), and \(Workspace.skillsFolder) folders will be created. Existing agents and files stay where they are. You can change this later in Settings.")
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }


    /// The Studio sidebar: tools, the Projects / Agents / Skills switch, the list, and actions.
    private var sidebarColumn: some View {
        VStack(spacing: 0) {
                // In the Space Studio the switch lives in the status strip, as in the Cockpit.
                if !theme.isSpace {
                    ModeSwitch(selection: $appMode, text: Color(nsColor: theme.foreground), highlight: theme.accent.opacity(0.3), track: Color.primary.opacity(0.05))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
                }
                VStack(spacing: 2) {
                    toolRow("Desk", icon: store.showInbox ? "tray.full.fill" : "tray.full", selected: store.showInbox,
                            help: "Your Desk: requests, reports, and proposals from agents (⌘I)") {
                        store.showInbox.toggle()
                    } trailing: {
                        if store.pendingInboxCount > 0 {
                            Text("\(min(store.pendingInboxCount, 99))").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).frame(minHeight: 16).background(theme.accent, in: Capsule())
                        }
                    }
                    let summary = store.routineSummary()
                    toolRow("Routines", icon: "clock", selected: false, help: "Scheduled work for your agents") {
                        store.showRoutines = true
                    } trailing: {
                        HStack(spacing: 5) {
                            Circle().fill(summaryColor(summary.tone)).frame(width: 6, height: 6)
                            Text(summary.text).font(.system(size: 11)).foregroundStyle(summary.tone == .off ? .secondary : summaryColor(summary.tone)).lineLimit(1)
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 10).padding(.top, theme.isSpace ? 10 : 0)
                workspaceSwitch.padding(.horizontal, 12).padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch store.mode {
                        case .agents: agentsSidebar
                        case .skills: skillsSidebar
                        case .projects: projectsSidebar
                        }
                        if store.mode != .skills && !store.workspaceTerminals.isEmpty {
                            Divider()
                            sectionLabel("LIVE SESSIONS")
                            ForEach(Array(store.workspaceTerminals.enumerated()), id: \.element.id) { index, terminal in
                                Button {
                                    store.activeTerminalID = terminal.id
                                    NotificationCenter.default.post(name: .workspaceAction, object: String(index))
                                } label: {
                                    HStack {
                                        ClaudeSessionMark(color: sessionColor(terminal.colorIndex)).frame(width: 14, height: 14)
                                        Text(terminal.session.name).lineLimit(1)
                                        Spacer()
                                        Text(terminal.shortLabel).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                    }.padding(8).background(store.activeTerminalID == terminal.id ? theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(12)
                }
                Divider()
                if store.mode == .agents {
                    if store.agentHostPath.isEmpty {
                        SettingsLink { Label("Set up workspace", systemImage: "folder.badge.plus") }.padding(12)
                    } else {
                        Button { creatingAgent = true } label: { Label("Create agent", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }
                            .buttonStyle(SidebarActionStyle(prominent: true)).padding(12)
                    }
                } else if store.mode == .skills {
                    Button { creatingSkill = true } label: { Label("New skill", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(SidebarActionStyle(prominent: true)).padding(12).disabled(store.libraryURL == nil)

                } else {
                    Button(action: store.addProject) { Label("Add project", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(SidebarActionStyle(prominent: true)).padding(12)
                }
                Divider()
                HStack(spacing: 16) {
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                    Button { integrationsTarget = "global"; integrations = true } label: { Label("Global plugins", systemImage: "puzzlepiece.extension") }
                        .help("Plugins and MCP servers for normal Claude sessions. Agents have their own under Agent tools.")
                    Spacer()
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
            }
    }

    @ViewBuilder private var detail: some View {
        if store.showInbox {
            InboxView()
        } else if store.mode == .skills {
            if let skill = store.librarySkills.first(where: { $0.name == store.selectedSkillName }) {
                SkillDetailView(skill: skill).id(skill.name)
            } else {
                ContentUnavailableView {
                    Label(store.libraryURL == nil ? "Choose a workspace first" : "Your skill library", systemImage: "wand.and.stars")
                } description: {
                    Text(store.libraryURL == nil
                         ? "Set a workspace folder in Settings to create a skill library."
                         : "Every skill lives here once. Attach it to Global, agents, or projects.")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(emptyBackground)
            }
        } else if store.workspaceTerminals.isEmpty {
            ContentUnavailableView {
                Label("Your workspace", systemImage: "terminal")
            } description: {
                Text("Choose a project or agent in the sidebar, then start a conversation.\nYour terminals stay here while you browse and configure.")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(emptyBackground)
        } else { TerminalWorkspace() }
    }

    /// Empty screens let the starfield show through in the Space Studio.
    private var emptyBackground: Color { theme.isSpace ? SpaceTheme().settings.background.opacity(0.45) : Color(nsColor: theme.background) }

    // MARK: Space Studio

    /// The Studio in the Cockpit's look: starfield, the same status strip, a glass sidebar and a rounded main panel.
    private var spaceStudio: some View {
        let style = SpaceTheme().settings
        return ZStack {
            SpaceBackground(graph: VaultGraph(), layout: ConstellationLayout(), pulses: [:], reduceMotion: true, settings: style)
                .overlay(Color.black.opacity(0.18))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                studioStrip(style)
                HStack(alignment: .top, spacing: 12) {
                    if sidebarShown {
                        sidebarColumn
                            .frame(width: 292)
                            .background(style.background.opacity(0.74), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(style.glassStroke, lineWidth: 0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(style.glassStroke, lineWidth: 0.7))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                }
                .padding(12)
            }
        }
        .environment(\.cockpitStyle, style)
        .foregroundStyle(style.text)
    }

    /// The same thin strip as the Cockpit: mode switch, live counts, sidebar toggle, and the time.
    private func studioStrip(_ style: CockpitThemeSettings) -> some View {
        func chip(_ label: String, _ value: String, _ color: Color) -> some View {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).foregroundStyle(style.secondaryText)
                Text(value)
            }
        }
        let live = store.workspaceTerminals.count
        return HStack(spacing: 16) {
            ModeSwitch(selection: $appMode, text: style.text, highlight: style.accent.opacity(0.32), track: style.glassFill).fixedSize()
            HStack(spacing: 6) {
                Text("CLAUDEDESK OS").foregroundStyle(style.accent)
                Text("· STUDIO").foregroundStyle(style.secondaryText)
            }
            chip("RUNNER", store.runnerEnabled ? "ON" : "OFF", store.runnerEnabled ? style.good : style.secondaryText.opacity(0.5))
            chip("DESK", "\(store.pendingInboxCount)", store.pendingInboxCount == 0 ? style.secondaryText.opacity(0.5) : style.accent)
            chip("AGENTS", "\(store.agents.count)", style.constellationColor)
            chip("SESSIONS", live == 0 ? "NONE" : "\(live) LIVE", live == 0 ? style.secondaryText.opacity(0.5) : style.warning)
            Spacer(minLength: 8)
            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sidebarShown.toggle() } } label: {
                Image(systemName: "sidebar.left").foregroundStyle(sidebarShown ? style.accent : style.secondaryText)
            }
            .keyboardShortcut("0", modifiers: .command).help(sidebarShown ? "Hide the sidebar (⌘0)" : "Show the sidebar (⌘0)")
            TimelineView(.periodic(from: .now, by: 30)) { context in Text(context.date.formatted(date: .omitted, time: .shortened)) }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .buttonStyle(.plain)
        .padding(.horizontal, 16).frame(height: 44)
        .background(style.background.opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(style.glassStroke).frame(height: 0.5) }
    }

    /// Projects / Agents / Skills as a pill switch, matching the Cockpit's controls.
    private var workspaceSwitch: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceMode.allCases) { mode in
                let selected = store.mode == mode
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.mode = mode } } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color(nsColor: theme.foreground) : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background(selected ? theme.accent.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07), lineWidth: 0.7))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
    }

    private func summaryColor(_ tone: RoutineSummary.Tone) -> Color {
        switch tone {
        case .off: return .secondary.opacity(0.6)
        case .ok: return .green
        case .waiting: return .orange
        case .attention: return .red
        }
    }

    /// A labeled row at the top of the sidebar for app-wide tools, with live status on the right.
    private func toolRow<Trailing: View>(_ title: String, icon: String, selected: Bool, help: String, action: @escaping () -> Void,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(theme.accent).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 6)
                trailing()
            }.padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                .background(selected ? theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(help)
    }

    private var skillsSidebar: some View {
        Group {
            if store.librarySkills.isEmpty {
                Text(store.libraryURL == nil ? "Set a workspace folder in Settings to start a skill library." : "No skills yet. Create one below, or approve one an agent proposes in the Inbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.librarySkills) { skill in
                Button { store.selectedSkillName = skill.name } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                        if !skill.description.isEmpty { Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                        .background(skill.name == store.selectedSkillName ? theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
            if let library = store.libraryURL {
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.path) } label: { Label("Library folder", systemImage: "folder") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var agentsSidebar: some View {
        Group {
            ForEach(store.agents) { item in
                selectionRow(item.name, icon: "person.crop.square", selected: item.id == store.selectedAgentID, mascotColor: agentColor(item.id)) { store.selectedAgentID = item.id }
            }
            if let agent {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 9) {
                        ClaudeMascot(color: agentColor(agent.id)).frame(width: 25, height: 20)
                        Text(agent.name).font(.headline)
                        Spacer()
                    }
                    if !agent.purpose.isEmpty {
                        Text(agent.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(agent.purpose)
                    }
                    Button { store.launchAgent(agent) } label: {
                        HStack {
                            Image(systemName: "plus")
                            Text("New conversation").fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption)
                        }.padding(.horizontal, 12).padding(.vertical, 11)
                    }.buttonStyle(SidebarActionStyle(prominent: true))
                    HStack(spacing: 8) {
                        sidebarTile("Continue", icon: "arrow.turn.down.right") {
                            store.launchAgent(agent, title: "\(agent.name) · continued", arguments: ["--continue"])
                        }.help("Continue this agent’s latest conversation")
                        sidebarTile("History", icon: "clock.arrow.circlepath") {
                            store.launchAgent(agent, title: "\(agent.name) · from history", arguments: ["--resume"])
                        }.help("Choose a past conversation in Claude")
                    }
                    HStack(spacing: 14) {
                        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: agent.path + "/files") } label: {
                            Label("Files", systemImage: "folder")
                        }
                        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: agent.path) } label: {
                            Label("Agent folder", systemImage: "arrow.up.forward.square")
                        }.help(agent.path)
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.vertical, 2)
                    Divider().padding(.vertical, 2)
                    sectionLabel("AGENT TOOLS")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        sidebarTile("Memory", icon: "brain") { document = SidebarDocument(agent: agent, document: .memory) }
                        sidebarTile("Instructions", icon: "text.alignleft") { document = SidebarDocument(agent: agent, document: .instructions) }
                        sidebarTile("MCP servers", icon: "point.3.connected.trianglepath.dotted") { document = SidebarDocument(agent: agent, document: .mcp) }
                        sidebarTile("Plugins", icon: "puzzlepiece.extension") { integrationsTarget = agent.id.uuidString; integrations = true }
                        sidebarTile("Settings", icon: "slider.horizontal.3") { document = SidebarDocument(agent: agent, document: .settings) }
                        sidebarTile("Overrides", icon: "switch.2") { document = SidebarDocument(agent: agent, document: .localSettings) }
                    }
                    sectionLabel("SKILLS").padding(.top, 4)
                    AgentSkillsMenu(agent: agent)
                        .padding(.horizontal, 9).frame(height: 35)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }

            }
        }
    }

    private var projectsSidebar: some View {
        Group {
            ForEach(store.projects) { item in
                selectionRow(item.name, icon: "folder", selected: item.id == store.selectedID) { store.selectedID = item.id }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path) }
                        Button("Remove project…", role: .destructive) { removingProject = item }
                    }
            }
            if let project {
                Divider()
                HStack {
                    Text(project.name).font(.headline).lineLimit(1)
                    Spacer()
                    Button { integrationsTarget = project.id.uuidString; integrations = true } label: { Image(systemName: "puzzlepiece.extension") }
                        .help("Plugins and MCP servers for this project")
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) } label: { Image(systemName: "folder") }.help(project.path)
                }
                ForEach(project.sessions) { session in
                    HStack {
                        Button { launch(session, project: project) } label: { Label(session.name, systemImage: "play.fill").lineLimit(1) }.buttonStyle(.plain)
                        Spacer()
                        Menu {
                            Button("Edit") { editingProject = project.id; editing = session }
                            Button("Duplicate") { store.update(DeskSession(name: session.name + " copy", prompt: session.prompt), in: project.id) }
                            Button("Remove shortcut", role: .destructive) { store.removeSession(session.id, from: project.id) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                    }.padding(.vertical, 5)
                }
                Button { editingProject = project.id; editing = DeskSession(name: "New session") } label: { Label("New session shortcut", systemImage: "plus") }
                Button("Open all sessions") { Task { await store.launch(project.sessions, in: project, executableOverride: executable) } }.disabled(project.sessions.isEmpty || store.launching)
            }
        }
    }

    private func sidebarTile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(theme.accent).frame(width: 15)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 9).frame(height: 35).frame(maxWidth: .infinity)
        }.buttonStyle(SidebarActionStyle())
    }

    private func launch(_ session: DeskSession, project: Project) {
        Task { await store.launch([session], in: project, executableOverride: executable) }
    }
    private func selectionRow(_ title: String, icon: String, selected: Bool, mascotColor: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if icon == "person.crop.square" {
                    ClaudeMascot(color: (mascotColor ?? theme.accent).opacity(selected ? 1 : 0.85)).frame(width: 22, height: 18)
                } else { Image(systemName: icon).frame(width: 22) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(9).background(selected ? theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}

private struct SidebarActionStyle: ButtonStyle {
    @Environment(\.deskTheme) private var theme
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarActionBody(label: configuration.label, pressed: configuration.isPressed, prominent: prominent, theme: theme)
    }
}

private struct SidebarActionBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let prominent: Bool
    let theme: DeskTheme
    @State private var hovered = false
    var body: some View {
        label
            .foregroundStyle(prominent ? Color(nsColor: theme.foreground) : Color.primary)
            .background(prominent ? theme.accent.opacity(pressed ? 0.55 : hovered ? 0.40 : 0.28) : Color.primary.opacity(pressed ? 0.12 : hovered ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(prominent ? theme.accent.opacity(0.5) : Color.primary.opacity(hovered ? 0.16 : 0.07)).allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
}
