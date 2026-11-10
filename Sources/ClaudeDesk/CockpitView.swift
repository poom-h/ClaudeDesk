import SwiftUI
import AppKit

/// Draws a widget at the global widget size. Scaling doesn't change layout size, so the card measures its own
/// height and takes the scaled size, which keeps the side columns' stacking and scrolling right.
private struct ScaledCard<Content: View>: View {
    let width: CGFloat
    let scale: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { height = proxy.size.height.rounded() }
                    .onChange(of: proxy.size.height) { _, value in if value.rounded() != height { height = value.rounded() } }
            })
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width * scale, height: height * scale, alignment: .topLeading)
    }
}

/// The everyday overview: the memory graph alone in the middle, with widgets in a scrolling column on each side.
struct CockpitView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("appMode") private var appMode = "cockpit"
    @AppStorage("cockpitReduceMotion") private var reduceMotionSetting = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var layout = ConstellationLayout()
    @State private var hovered: String?
    @State private var hoverLocation: CGPoint = .zero
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    /// The widget a dragged one would land before, or "end-0" / "end-1" for the end of a side.
    @State private var dropTarget: String?
    @State private var settingsFor: WidgetConfig?
    @State private var addingShortcut = false
    @State private var arrived = false
    /// The widget shown large in focus mode, if any.
    @State private var focused: WidgetConfig?
    @State private var showingGallery = false

    private let stripHeight: CGFloat = 44
    private let margin: CGFloat = 16
    private var theme: CockpitTheme { CockpitThemes.named(store.cockpitLayout.theme) }
    private var reduceMotion: Bool { reduceMotionSetting || systemReduceMotion }
    @State private var clearWidth: CGFloat?
    @State private var canvasSize: CGSize = .zero
    @State private var glide: GraphViewport.Glide?
    /// The graph view (2D, 3D sphere, or orbits), remembered between launches.
    @AppStorage("cockpitGraphMode") private var graphModeSetting = GraphMode.flat.rawValue
    @State private var morph: GraphViewport.Morph?
    @State private var yaw: Double = 0
    @State private var pitch: Double = 0.35
    @State private var orbitStart: (yaw: Double, pitch: Double)?
    private var graphMode: GraphMode { GraphMode(rawValue: graphModeSetting) ?? .flat }
    // Quick search over the memory graph
    @State private var query = ""
    @State private var searchIndex: [VaultSearch.Entry] = []
    @State private var results: [VaultSearch.Result] = []
    @State private var selected = 0
    @State private var searchChanged: Double = 0
    @FocusState private var searchFocused: Bool
    /// The search box stays hidden until Return (or ⌘F) pops it up.
    @State private var searchVisible = false
    @State private var keyMonitor: Any?
    /// Notes open in the built-in viewer, newest last, for Back.
    @State private var viewing: [String] = []
    // Ask panel: talk to an agent (Atlas by default) from the Cockpit, opened with Shift+Return
    @State private var askVisible = false
    @State private var askText = ""
    @State private var askTurns: [AskTurn] = []
    @State private var askAgent = "atlas"
    @FocusState private var askFocused: Bool
    @State private var askInfo = false

    private var viewport: GraphViewport {
        let search = results.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty ? nil :
            GraphSearch(matches: Dictionary(results.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }),
                        focused: results.indices.contains(selected) ? results[selected].id : nil, changed: searchChanged)
        return GraphViewport(zoom: zoom, pan: pan, colors: clusterColors(), fitWidth: clearWidth, glide: glide, search: search,
                             mode: graphMode, yaw: yaw, pitch: pitch, morph: morph)
    }

    var body: some View {
        let style = theme.settings
        GeometryReader { proxy in
            let size = proxy.size
            let rail = railWidth
            ZStack(alignment: .topLeading) {
                theme.background(graph: store.vaultGraph, layout: layout, view: viewport, pulses: store.vaultPulses, reads: store.vaultReads,
                                 reduceMotion: reduceMotion, hovered: hovered)
                graphControls(size: size)
                statusStrip(style)
                if searchVisible {
                    searchBar(style, width: min(380, max(240, size.width - 2 * rail - 48)))
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, stripHeight + 14)
                        .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: .top).combined(with: .opacity),
                                                removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity)))
                        .zIndex(3)
                }
                if !askVisible && !searchVisible && viewing.isEmpty && focused == nil {
                    // A quiet reminder of the two keyboard entry points.
                    Text("↵ search memory    ⇧↵ ask \(askTarget?.name ?? "Atlas")")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(style.secondaryText.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 14)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(2)
                }
                if askVisible {
                    askPanel(style, width: min(580, max(300, size.width - 2 * rail - 48)), height: size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        .zIndex(3)
                }
                if let id = viewing.last, let node = store.vaultGraph.nodes.first(where: { $0.id == id }) {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .onTapGesture { closeViewer() }
                        .transition(.opacity).zIndex(7)
                    NoteViewer(node: node, graph: store.vaultGraph, vault: store.workspaceURL.map(Workspace.vault(in:)),
                               canGoBack: viewing.count > 1,
                               onFollow: { showNote($0) }, onBack: { withAnimation(.smooth(duration: 0.25)) { _ = viewing.popLast() } },
                               onClose: closeViewer, onObsidian: { open(node) })
                        .frame(width: min(820, size.width - 80), height: min(760, size.height - 70))
                        .position(x: size.width / 2, y: size.height / 2 + 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(8)
                }
                ForEach([0, 1], id: \.self) { side in
                    sideColumn(side, style: style)
                        .frame(width: rail, height: max(0, size.height - stripHeight))
                        .offset(x: side == 0 ? 0 : size.width - rail, y: stripHeight)
                        .opacity(arrived ? 1 : 0)
                        .offset(x: arrived ? 0 : (side == 0 ? -24 : 24))
                        .animation(reduceMotion ? .none : .spring(response: 0.55, dampingFraction: 0.85).delay(0.1), value: arrived)
                        .zIndex(1)
                }
                if let config = focused {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture { closeFocus() }
                        .transition(.opacity).zIndex(5)
                    FocusPanel(config: config, onClose: closeFocus, onAddShortcut: { addingShortcut = true })
                        .frame(width: min(960, size.width - 96), height: min(680, size.height - 96))
                        .position(x: size.width / 2, y: size.height / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .zIndex(6)
                }
                if let id = hovered, focused == nil, let node = store.vaultGraph.nodes.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title).font(.system(size: 12, weight: .semibold))
                        Text(node.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(style.secondaryText)
                        Text("Click to read it").font(.system(size: 10)).foregroundStyle(style.secondaryText)
                    }.padding(8).background(style.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.glassStroke))
                        .offset(x: hoverLocation.x + 14, y: hoverLocation.y + 10).allowsHitTesting(false).zIndex(3)
                }
            }
            .onAppear { clearWidth = max(200, size.width - 2 * rail); canvasSize = size }
            .onChange(of: size.width - 2 * rail) { _, width in clearWidth = max(200, width) }
            .onChange(of: size) { _, value in canvasSize = value }
        }
        .environment(\.cockpitStyle, style)
        .foregroundStyle(style.text)
        .preferredColorScheme(.dark)
        .onAppear {
            layout.update(store.vaultGraph)
            rebuildSearchIndex(store.vaultGraph)
            installKeyMonitor()
            store.startCockpit()
            // Launch argument for checking the gallery without clicking (`open --args -debugOpenWidgetGallery YES`); never saved.
            if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["debugOpenWidgetGallery"] != nil { showingGallery = true }
            if let text = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["debugSearch"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSearch(); query = text }
            }
            if let view = (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["debugGraphMode"] as? String).flatMap(GraphMode.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { switchView(to: view) }
            }
            if let text = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["debugAsk"] as? String {
                // Opens the panel with text filled in, without sending it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showAsk(); askText = text }
            }
            if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["debugOpenSettings"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openSettings() }
            }
            if let note = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["debugOpenNote"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showNote(note) }
            }
            arrived = reduceMotion
            DispatchQueue.main.async { arrived = true }
        }
        .onDisappear {
            store.stopCockpit(); arrived = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: store.vaultGraph) { _, graph in layout.update(graph); rebuildSearchIndex(graph) }
        .onChange(of: query) { _, text in runSearch(text) }
        .onChange(of: store.liveRuns) { _, runs in collectAnswers(runs) }
        .sheet(item: $settingsFor) { config in WidgetSettingsView(config: config).environmentObject(store) }
        .sheet(isPresented: $addingShortcut) { ShortcutEditor().environmentObject(store) }
        .sheet(isPresented: $store.showRoutines) { RoutinesView().environmentObject(store) }
        .sheet(isPresented: $showingGallery) {
            WidgetGallery(onAddKind: { add($0) }, onAddAgentWidget: { add($0) })
                .environmentObject(store).environment(\.cockpitStyle, theme.settings)
        }
    }

    // MARK: Status strip

    private func statusStrip(_ style: CockpitThemeSettings) -> some View {
        let running = store.liveRuns.filter { $0.status == "running" }.count
        func chip(_ label: String, _ value: String, _ color: Color) -> some View {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).foregroundStyle(style.secondaryText)
                Text(value)
            }
        }
        return HStack(spacing: 16) {
            ModeSwitch(selection: $appMode, text: style.text, highlight: style.accent.opacity(0.32), track: style.glassFill).fixedSize()
            Text("CLAUDEDESK OS").foregroundStyle(style.accent)
            chip("RUNNER", store.runnerEnabled ? "ON" : "OFF", store.runnerEnabled ? style.good : style.secondaryText.opacity(0.5))
            chip("RUNS", running == 0 ? "IDLE" : "\(running) LIVE", running == 0 ? style.secondaryText.opacity(0.5) : style.warning)
            chip("DESK", "\(store.pendingInboxCount)", store.pendingInboxCount == 0 ? style.secondaryText.opacity(0.5) : style.accent)
            if let limits = store.planLimits {
                let five = limits.fiveHour.map { Int($0.used.rounded()) }, seven = limits.sevenDay.map { Int($0.used.rounded()) }
                chip("LIMITS", "5H \(five.map(String.init) ?? "–")% · 7D \(seven.map(String.init) ?? "–")%", (five ?? 0) >= 80 ? style.danger : style.good)
            }
            chip("BRAIN", "\(store.vaultGraph.nodes.count) · \(store.vaultGraph.edges.count) LINKS", style.constellationColor)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 30)) { context in Text(context.date.formatted(date: .omitted, time: .shortened)) }
            HStack(spacing: 0) {
                ForEach(GraphMode.allCases) { mode in
                    Button { switchView(to: mode) } label: {
                        Text(mode.label).padding(.horizontal, 7).frame(height: 22)
                            .background(graphMode == mode ? style.accent.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(graphMode == mode ? style.text : style.secondaryText)
                            .contentShape(Rectangle())
                    }
                    .help(mode.title + (mode == .sphere ? ": drag to turn it" : ""))
                }
            }
            .padding(2)
            .background(style.glassFill, in: RoundedRectangle(cornerRadius: 7))
            .fixedSize()
            Button { glideCamera(zoom: max(0.5, zoom / 1.25), pan: pan) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Button { glideCamera(zoom: 1, pan: .zero) } label: { Text("FIT") }.help("Recentre the memory graph")
            Button { glideCamera(zoom: min(4, zoom * 1.25), pan: pan) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button { showingGallery = true } label: {
                HStack(spacing: 4) {
                    Text("+ WIDGET")
                    if !store.unplacedAgentWidgets.isEmpty { Circle().fill(style.accent).frame(width: 6, height: 6) }
                }
            }
            .help(store.unplacedAgentWidgets.isEmpty ? "Browse widgets to add" : "An agent made a new widget for you to place")
            HStack(spacing: 2) {
                Button { stepScale(-1) } label: { Text("−").frame(width: 18, height: 22).contentShape(Rectangle()) }
                    .keyboardShortcut("-", modifiers: [.command]).help("Smaller widgets (⌘−)").disabled(scale <= CockpitLayout.scales.first!)
                Text("\(Int((scale * 100).rounded()))%").frame(minWidth: 34).help("Widget size")
                Button { stepScale(1) } label: { Text("+").frame(width: 18, height: 22).contentShape(Rectangle()) }
                    .keyboardShortcut("=", modifiers: [.command]).help("Larger widgets (⌘+)").disabled(scale >= CockpitLayout.scales.last!)
            }
            .padding(.horizontal, 4)
            .background(style.glassFill, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
            Menu {
                Toggle("Reduce motion", isOn: $reduceMotionSetting)
                Picker("Widget size", selection: Binding(get: { store.cockpitLayout.scale }, set: { setScale($0) })) {
                    ForEach(CockpitLayout.scales, id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
                }
                Button("Reset to default widgets and sides") { withAnimation { store.cockpitLayout.widgets = CockpitLayout.standard.widgets }; store.saveCockpitLayout() }
                Divider()
                Text("Theme: \(theme.name)")
            } label: { Image(systemName: "slider.horizontal.3") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .buttonStyle(.plain)
        .padding(.horizontal, margin).frame(height: stripHeight)
        .background(style.background.opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(style.glassStroke).frame(height: 0.5) }
        .zIndex(4)
    }

    // MARK: Quick search

    /// The search field over the graph, with its results underneath while there's a query.
    private func searchBar(_ style: CockpitThemeSettings, width: CGFloat) -> some View {
        let cyan = SpaceBackground.searchColor
        let active = !query.isEmpty
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 11)).foregroundStyle(active || searchFocused ? cyan : style.secondaryText)
                TextField("Search memory", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .focused($searchFocused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                    .onKeyPress(.upArrow) { step(-1); return .handled }
                    .onKeyPress(.escape) { clearSearch(); return .handled }
                if active {
                    Text(results.isEmpty ? "no match" : "\(results.count) found").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(results.isEmpty ? style.warning : cyan)
                    Button { clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(style.secondaryText) }
                        .buttonStyle(.plain).help("Clear (Esc)")
                } else {
                    Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(style.secondaryText)
                }
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(style.background.opacity(0.75), in: Capsule())
            .overlay(Capsule().stroke(active || searchFocused ? cyan.opacity(0.7) : style.glassStroke, lineWidth: active || searchFocused ? 1.2 : 0.7))
            .shadow(color: (active ? cyan : .clear).opacity(0.35), radius: 12)
            .onTapGesture { searchFocused = true }
            if active && !results.isEmpty {
                // Four rows around the selection, so stepping with ↑↓ past the fourth keeps it in view.
                let shown = Self.window(of: results.count, around: selected, size: 4)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown, id: \.self) { index in resultRow(results[index], index: index, style: style) }
                    if results.count > shown.count {
                        Text("\(selected + 1) of \(results.count) · ↑↓ for more, all lit on the graph")
                            .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(style.secondaryText).padding(.horizontal, 8).padding(.vertical, 3)
                    }
                }
                .padding(4)
                .background(style.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(cyan.opacity(0.35), lineWidth: 0.8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: width)
        .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.85), value: results.map(\.id))
    }

    private func resultRow(_ result: VaultSearch.Result, index: Int, style: CockpitThemeSettings) -> some View {
        let cyan = SpaceBackground.searchColor
        let isSelected = index == selected
        let kind = store.vaultGraph.nodes.first { $0.id == result.id }?.kind
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .home ? "house" : kind == .map ? "map" : "doc.text")
                .font(.system(size: 10.5)).foregroundStyle(isSelected ? cyan : style.secondaryText).frame(width: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                // Only the selected row shows its snippet, which keeps the list short.
                if isSelected, !result.snippet.isEmpty {
                    Text(result.snippet).font(.system(size: 10)).foregroundStyle(style.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isSelected { Text("↵").font(.system(size: 10, design: .monospaced)).foregroundStyle(cyan) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isSelected ? cyan.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selected = index; openSelected() }
        .onTapGesture { select(index) }
        .help("Click to fly to it, double-click (or Return) to read it")
    }

    /// `size` consecutive indices out of `count`, keeping `index` inside and as centred as the ends allow.
    static func window(of count: Int, around index: Int, size: Int) -> [Int] {
        guard count > size else { return Array(0..<count) }
        let start = min(max(0, index - size / 2), count - size)
        return Array(start..<(start + size))
    }

    private func rebuildSearchIndex(_ graph: VaultGraph) {
        searchIndex = graph.nodes.map { VaultSearch.entry(id: $0.id, title: $0.title, url: $0.url) }
        if !query.isEmpty { results = VaultSearch.search(query, in: searchIndex) }
    }

    private func runSearch(_ text: String) {
        results = VaultSearch.search(text, in: searchIndex)
        selected = 0
        searchChanged = Date().timeIntervalSinceReferenceDate
        if let first = results.first { fly(to: first.id) } else if text.trimmingCharacters(in: .whitespaces).isEmpty { glideCamera(zoom: 1, pan: .zero) }
    }

    private func step(_ offset: Int) {
        guard !results.isEmpty else { return }
        select((selected + offset + results.count) % results.count)
    }

    private func select(_ index: Int) {
        selected = index
        if results.indices.contains(index) { fly(to: results[index].id) }
    }

    private func openSelected() {
        guard results.indices.contains(selected) else { return }
        showNote(results[selected].id)
    }

    /// Hides the search box and clears it, gliding back to the full graph.
    private func clearSearch() {
        query = ""
        results = []
        searchFocused = false
        withAnimation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.85)) { searchVisible = false }
        glideCamera(zoom: 1, pan: .zero)
    }

    private func showSearch() {
        withAnimation(reduceMotion ? .none : .spring(response: 0.35, dampingFraction: 0.72)) { searchVisible = true }
        DispatchQueue.main.async { searchFocused = true }
    }

    /// Return pops the search up (and ⌘F anywhere in the Cockpit); Esc closes the viewer or the search. Keys typed
    /// into a text field, a sheet, or focus mode are left alone.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard appMode == "cockpit", focused == nil, let window = event.window, !window.isSheet, window.attachedSheet == nil else { return event }
            let typing = window.firstResponder is NSTextView
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 3, flags == .command {                          // ⌘F
                if !viewing.isEmpty { closeViewer() }
                showSearch(); return nil
            }
            if event.keyCode == 53, !viewing.isEmpty { closeViewer(); return nil }   // Esc closes the viewer first
            if (event.keyCode == 36 || event.keyCode == 76), flags.subtracting([.numericPad, .function, .capsLock]) == .shift, !typing {
                showAsk(); return nil                                                // Shift+Return: ask Atlas
            }
            if event.keyCode == 53, askVisible, !typing { hideAsk(); return nil }
            // Plain keys only: Return with ⌘ or ⌥ is someone else's shortcut. The keypad's Enter also counts.
            guard !typing, flags.subtracting([.numericPad, .function, .capsLock]).isEmpty else { return event }
            if (event.keyCode == 36 || event.keyCode == 76), viewing.isEmpty, !searchVisible, !askVisible { showSearch(); return nil }   // Return
            if event.keyCode == 53, searchVisible { clearSearch(); return nil }
            return event
        }
    }

    // MARK: Ask panel

    private var askTarget: AgentProfile? { store.agents.matching(askAgent) ?? store.agents.first }

    /// The chat with an agent: your questions, its live steps while it works, and its answers.
    private func askPanel(_ style: CockpitThemeSettings, width: CGFloat, height: CGFloat) -> some View {
        let accent = style.accent
        let name = askTarget?.name ?? "an agent"
        return VStack(spacing: 8) {
            if !askTurns.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollViewReader { reader in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(askTurns) { turn in askTurnView(turn, style: style).id(turn.id) }
                            }
                            .padding(14)
                        }
                        .onChange(of: askTurns.map { ($0.answer ?? "") + $0.id }) { _, _ in
                            if let last = askTurns.last { withAnimation { reader.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                    .frame(maxHeight: min(420, height * 0.5))
                    Divider().overlay(style.glassStroke)
                    HStack(spacing: 14) {
                        if let last = askTurns.last, askTarget != nil {
                            Button { continueInStudio(last) } label: { Label("Continue in Studio", systemImage: "terminal") }
                                .help("Reopen this exact session as a conversation pane")
                        }
                        if let answer = askTurns.last?.answer, !answer.isEmpty {
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string) } label: {
                                Label("Copy answer", systemImage: "doc.on.doc")
                            }
                        }
                        Spacer()
                        Button { withAnimation { askTurns = [] } } label: { Label("New chat", systemImage: "square.and.pencil") }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(style.secondaryText)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .background(style.background.opacity(0.88), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.35), lineWidth: 0.8))
            }
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    ForEach(store.agents) { agent in
                        Button(agent.name) { askAgent = URL(fileURLWithPath: agent.path).lastPathComponent }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").foregroundStyle(accent)
                        Text(name).font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().help("Who to ask")
                TextField("Ask \(name)…", text: $askText, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .focused($askFocused)
                    .onSubmit(sendAsk)
                    .onKeyPress(.escape) { hideAsk(); return .handled }
                Button { askInfo.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(style.secondaryText)
                }
                .buttonStyle(.plain).help("How asking works")
                .popover(isPresented: $askInfo, arrowEdge: .top) { askExplainer(name: name) }
                Button(action: sendAsk) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(askText.trimmingCharacters(in: .whitespaces).isEmpty ? style.secondaryText : accent)
                }
                .buttonStyle(.plain).disabled(askText.trimmingCharacters(in: .whitespaces).isEmpty).help("Send (Return)")
            }
            .help("Ask \(name) anything. It answers as a background run with its own memory, skills and the Memory Vault. Return sends · Esc hides · ⓘ for details")
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(style.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(askFocused ? 0.75 : 0.4), lineWidth: askFocused ? 1.2 : 0.8))
            .shadow(color: accent.opacity(0.3), radius: 14)
        }
        .frame(width: width)
    }

    @ViewBuilder private func askTurnView(_ turn: AskTurn, style: CockpitThemeSettings) -> some View {
        let run = store.liveRuns.first { $0.runID == turn.id }
        HStack {
            Spacer(minLength: 60)
            Text(turn.question).font(.system(size: 12.5)).textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(style.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(style.accent)
                Text(turn.agentName).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(style.secondaryText)
            }
            if let answer = turn.answer {
                if turn.outcome == "ok" || turn.outcome == "stopped" {
                    MarkdownView(answer.isEmpty ? "_(No answer text.)_" : answer,
                                 context: MarkdownContext(base: URL(fileURLWithPath: NSHomeDirectory()), root: URL(fileURLWithPath: NSHomeDirectory()),
                                                          fontSize: 12.5, accent: style.accent))
                } else {
                    Label("\(turn.agentName) couldn't finish (\(turn.outcome)). \(answer)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(style.warning)
                }
            } else {
                // Working: the latest step, refreshed as the run streams.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(run?.steps.last ?? "Starting…").font(.system(size: 11.5)).foregroundStyle(style.secondaryText).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(RoutineHistory.duration(Int(context.date.timeIntervalSince(run?.started ?? turn.asked))))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(style.secondaryText)
                        if let run, run.status == "running" {
                            Button("Stop") { store.stopRun(run) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(style.danger)
                        }
                    }
                }
            }
        }
    }

    /// What happens when you ask, in plain terms.
    private func askExplainer(name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Asking \(name)").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Label("Runs Claude Code headless (`claude -p`) as \(name): its own folder, profile, CLAUDE.md, memory and skills, with access to the Memory Vault.", systemImage: "terminal")
                Label("Same restricted setup as routines and shortcuts: only allowed tools, edits only in its own folders, no permission prompts, turn and time limits.", systemImage: "lock.shield")
                Label("You see its latest step while it works, and notes it reads light up on the graph. Its final message is the answer.", systemImage: "sparkles")
                Label("Follow-ups include your last few questions and answers. Continue in Studio reopens the same session as a full conversation.", systemImage: "arrow.turn.down.right")
                Label("Uses your Claude plan like any conversation; it shows under \(name) in Token usage.", systemImage: "chart.bar")
            }
            .font(.system(size: 12))
            .labelStyle(.titleAndIcon)
            Divider()
            Text("⇧↵ open · ↵ send · esc hide").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 380)
    }

    private func showAsk() {
        if searchVisible { clearSearch() }
        withAnimation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.82)) { askVisible = true }
        DispatchQueue.main.async { askFocused = true }
    }

    private func hideAsk() {
        askFocused = false
        withAnimation(reduceMotion ? .none : .smooth(duration: 0.25)) { askVisible = false }
    }

    private func sendAsk() {
        let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let agent = askTarget else { return }
        let history = askTurns.compactMap { turn in turn.answer.map { (question: turn.question, answer: $0) } }
        let runID = store.ask(question, agent: agent, history: history)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            askTurns.append(AskTurn(id: runID, question: question, agentName: agent.name, asked: Date()))
        }
        askText = ""
    }

    /// Fills in answers as runs finish (finished runs only stay in the live list for a few minutes).
    private func collectAnswers(_ runs: [LiveRun]) {
        for index in askTurns.indices where askTurns[index].answer == nil {
            guard let run = runs.first(where: { $0.runID == askTurns[index].id }), run.status != "running" else { continue }
            askTurns[index].answer = run.result
            askTurns[index].outcome = run.status
        }
    }

    private func continueInStudio(_ turn: AskTurn) {
        guard let agent = askTarget, store.launchAgent(agent, title: "Ask: " + String(turn.question.prefix(30)), arguments: ["--resume", turn.id]) else { return }
        hideAsk()
        store.openInStudio()
    }

    // MARK: Note viewer

    private func showNote(_ id: String) {
        guard store.vaultGraph.nodes.contains(where: { $0.id == id }) else { return }
        withAnimation(reduceMotion ? .none : .spring(response: 0.32, dampingFraction: 0.86)) {
            if viewing.last != id { viewing.append(id) }
        }
        searchFocused = false
    }

    private func closeViewer() {
        withAnimation(reduceMotion ? .none : .smooth(duration: 0.25)) { viewing = [] }
    }

    /// Glides the camera so the star sits in the middle of the clear area, zoomed in.
    private func fly(to id: String) {
        let arrival = Date().timeIntervalSinceReferenceDate + GraphViewport.glideDuration
        let target = max(1.8, zoom)
        let probe = GraphViewport(zoom: target, pan: .zero, fitWidth: clearWidth, mode: graphMode, yaw: yaw, pitch: pitch)
        guard canvasSize.width > 0, let p = probe.point(id, layout: layout, size: canvasSize, time: reduceMotion ? 0 : arrival) else { return }
        // Land it in the open space below the results list, not behind it.
        let landing = CGPoint(x: canvasSize.width / 2, y: canvasSize.height * 0.7)
        glideCamera(zoom: target, pan: CGSize(width: landing.x - p.x, height: landing.y - p.y))
    }

    /// Switches the graph view. Every star morphs from where it was to its place in the new view, and the camera
    /// eases back to the full view.
    private func switchView(to mode: GraphMode) {
        guard mode != graphMode else { return }
        let now = Date().timeIntervalSinceReferenceDate
        morph = reduceMotion ? nil : GraphViewport.Morph(from: graphMode, start: now)
        graphModeSetting = mode.rawValue
        if query.isEmpty { glideCamera(zoom: 1, pan: .zero) } else if results.indices.contains(selected) { fly(to: results[selected].id) }
    }

    /// Moves the camera, easing from wherever it is now (even mid-glide). With Reduce motion it jumps.
    private func glideCamera(zoom target: CGFloat, pan offset: CGSize) {
        if reduceMotion { glide = nil; zoom = target; pan = offset; return }
        let now = Date().timeIntervalSinceReferenceDate
        let current = viewport.camera(at: now)
        glide = GraphViewport.Glide(pan: current.pan, zoom: current.zoom, start: now)
        zoom = target
        pan = offset
    }

    /// Ends a glide where the camera is right now, so dragging or pinching takes over smoothly.
    private func settleGlide() {
        let current = viewport.camera(at: Date().timeIntervalSinceReferenceDate)
        glide = nil
        zoom = current.zoom
        pan = current.pan
    }

    // MARK: Graph interaction

    private func graphControls(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case .active(let location) = phase else { if hovered != nil { hovered = nil }; return }
                // Only touch state when the hovered star changes, so moving the mouse doesn't re-render the Cockpit.
                let id = nearest(to: location, size: size)?.id
                if id != hovered { hovered = id; if id != nil { hoverLocation = location } }
            }
            .onTapGesture { location in
                if let node = nearest(to: location, size: size) { showNote(node.id) }
                else if searchVisible { clearSearch() }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if glide != nil { settleGlide() }
                    if graphMode == .sphere {
                        // Drag turns the sphere: sideways spins it, up and down tilts it.
                        let start = orbitStart ?? (yaw, pitch)
                        orbitStart = start
                        yaw = start.yaw + Double(value.translation.width) * 0.008
                        pitch = min(1.3, max(-1.3, start.pitch + Double(value.translation.height) * 0.008))
                        return
                    }
                    let start = panStart ?? pan
                    panStart = start
                    pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in panStart = nil; orbitStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if glide != nil { settleGlide() }
                    let start = zoomStart ?? zoom
                    zoomStart = start
                    zoom = min(4, max(0.5, start * value.magnification))
                }
                .onEnded { _ in zoomStart = nil })
    }

    private func nearest(to location: CGPoint, size: CGSize) -> VaultNode? {
        let time = reduceMotion ? 0 : Date().timeIntervalSinceReferenceDate
        let view = viewport
        return store.vaultGraph.nodes.compactMap { node -> (VaultNode, CGFloat)? in
            guard let p = view.point(node.id, layout: layout, size: size, time: time) else { return nil }
            return (node, hypot(p.x - location.x, p.y - location.y))
        }.filter { $0.1 < 16 }.min { $0.1 < $1.1 }?.0
    }

    private func open(_ node: VaultNode) {
        var components = URLComponents()
        components.scheme = "obsidian"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: node.url.path)]
        if let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(node.url) }
    }

    /// One colour per map; notes take the colour of the first map that links to them.
    private func clusterColors() -> [String: Color] {
        let palette: [Color] = [Color(red: 0.42, green: 0.56, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.30),
                                Color(red: 0.44, green: 0.86, blue: 0.56), Color(red: 0.96, green: 0.42, blue: 0.42),
                                Color(red: 0.74, green: 0.56, blue: 1.0), Color(red: 0.36, green: 0.84, blue: 0.86)]
        let maps = store.vaultGraph.nodes.filter { $0.kind == .map }.sorted { $0.id < $1.id }
        var colors: [String: Color] = [:]
        for (index, map) in maps.enumerated() { colors[map.id] = palette[index % palette.count] }
        for (a, b) in store.vaultGraph.edges {
            if let color = colors[a], colors[b] == nil, !maps.contains(where: { $0.id == b }) { colors[b] = color }
            if let color = colors[b], colors[a] == nil, !maps.contains(where: { $0.id == a }) { colors[a] = color }
        }
        return colors
    }

    // MARK: Widget placement

    private var scale: CGFloat { CGFloat(store.cockpitLayout.scale) }

    private func setScale(_ value: Double) {
        withAnimation(reduceMotion ? .none : .smooth(duration: 0.3)) { store.cockpitLayout.widgetScale = value }
        store.saveCockpitLayout()
    }

    private func stepScale(_ direction: Int) {
        let scales = CockpitLayout.scales
        let index = scales.firstIndex { $0 >= store.cockpitLayout.scale - 0.001 } ?? 2
        setScale(scales[min(scales.count - 1, max(0, index + direction))])
    }

    /// Every widget in a side column has the same width, scaled by the global widget size.
    private let cardWidth: CGFloat = 330
    private var railWidth: CGFloat { cardWidth * scale + 2 * margin }

    /// One side: its widgets stacked in a vertical scroll. Drag a widget by its header onto another to put it there,
    /// or onto the end of either side.
    private func sideColumn(_ side: Int, style: CockpitThemeSettings) -> some View {
        let items = store.cockpitLayout.widgets.filter { $0.column == side }
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12 * scale) {
                ForEach(items) { config in
                    VStack(alignment: .leading, spacing: 6) {
                        if dropTarget == config.id.uuidString { dropLine(style) }
                        ScaledCard(width: cardWidth, scale: scale) {
                            WidgetCard(config: config, onSettings: { settingsFor = config }, onAddShortcut: { addingShortcut = true },
                                       onCollapse: { toggleCollapsed(config.id) }, onFocus: { openFocus(config) },
                                       onMove: { move(config, by: $0) }, onSwitchSide: { moveToSide(config, side: 1 - side) },
                                       side: side)
                        }
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        drop(ids.first, before: config.id, side: side); return true
                    } isTargeted: { inside in
                        if inside { dropTarget = config.id.uuidString } else if dropTarget == config.id.uuidString { dropTarget = nil }
                    }
                }
                // The end of the column: drop here to put a widget last on this side.
                VStack(spacing: 6) {
                    if dropTarget == "end-\(side)" { dropLine(style) }
                    Text(items.isEmpty ? "Drag widgets here" : " ").font(.caption).foregroundStyle(style.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: items.isEmpty ? 120 : 60)
                        .background(items.isEmpty ? style.glassFill : .clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    drop(ids.first, before: nil, side: side); return true
                } isTargeted: { inside in
                    if inside { dropTarget = "end-\(side)" } else if dropTarget == "end-\(side)" { dropTarget = nil }
                }
            }
            .padding(.horizontal, margin).padding(.vertical, margin)
        }
        .scrollIndicators(.automatic)
        // Fade the top and bottom edges so cards scrolling under the strip don't look cut off.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.02),
                                     .init(color: .black, location: 0.97), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }

    private func dropLine(_ style: CockpitThemeSettings) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(style.accent).frame(height: 3).frame(maxWidth: .infinity).transition(.opacity)
    }

    /// Moves a dragged widget before `target` on `side`, or to the end of that side when `target` is nil.
    private func drop(_ id: String?, before target: UUID?, side: Int) {
        dropTarget = nil
        guard let id, let uuid = UUID(uuidString: id), uuid != target,
              let from = store.cockpitLayout.widgets.firstIndex(where: { $0.id == uuid }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            var widget = store.cockpitLayout.widgets.remove(at: from)
            widget.side = side
            if let target, let index = store.cockpitLayout.widgets.firstIndex(where: { $0.id == target }) {
                store.cockpitLayout.widgets.insert(widget, at: index)
            } else if let last = store.cockpitLayout.widgets.lastIndex(where: { $0.column == side }) {
                store.cockpitLayout.widgets.insert(widget, at: last + 1)
            } else {
                store.cockpitLayout.widgets.append(widget)
            }
        }
        store.saveCockpitLayout()
    }

    /// Moves a widget one place up or down within its side.
    private func move(_ config: WidgetConfig, by offset: Int) {
        let side = store.cockpitLayout.widgets.filter { $0.column == config.column }
        guard let position = side.firstIndex(where: { $0.id == config.id }), side.indices.contains(position + offset) else { return }
        let neighbour = side[position + offset]
        guard let a = store.cockpitLayout.widgets.firstIndex(where: { $0.id == config.id }),
              let b = store.cockpitLayout.widgets.firstIndex(where: { $0.id == neighbour.id }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.cockpitLayout.widgets.swapAt(a, b) }
        store.saveCockpitLayout()
    }

    private func moveToSide(_ config: WidgetConfig, side: Int) { drop(config.id.uuidString, before: nil, side: side) }

    private func openFocus(_ config: WidgetConfig) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { focused = config }
    }

    private func closeFocus() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { focused = nil }
    }

    private func toggleCollapsed(_ id: UUID) {
        guard let index = store.cockpitLayout.widgets.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.smooth(duration: 0.25)) { store.cockpitLayout.widgets[index].collapsed = !(store.cockpitLayout.widgets[index].collapsed ?? false) }
        store.saveCockpitLayout()
    }

    private func add(_ kind: WidgetKind) {
        store.cockpitLayout.widgets.append(WidgetConfig(kind: kind, size: .small, side: shorterSide))
        store.saveCockpitLayout()
    }

    /// New widgets go at the end of the side with fewer widgets.
    private var shorterSide: Int {
        let left = store.cockpitLayout.widgets.filter { $0.column == 0 }.count
        return left <= store.cockpitLayout.widgets.count - left ? 0 : 1
    }

    private func add(_ widget: AgentWidget) {
        store.cockpitLayout.widgets.append(WidgetConfig(kind: .agent, size: .small,
                                                        settings: ["agent": widget.agentFolder, "widget": widget.name, "title": widget.title],
                                                        side: shorterSide))
        store.saveCockpitLayout()
    }
}

// MARK: - Widget chrome

struct WidgetCard: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    let config: WidgetConfig
    var onSettings: () -> Void
    var onAddShortcut: () -> Void
    var onCollapse: () -> Void
    var onFocus: () -> Void
    var onMove: (Int) -> Void
    var onSwitchSide: () -> Void
    var side: Int

    var body: some View {
        let collapsed = config.collapsed ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: store.symbol(of: config)).font(.system(size: 11)).foregroundStyle(style.accent)
                Text(store.title(of: config).uppercased()).lineLimit(1)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(0.8)
                Spacer(minLength: 4)
                HeaderButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open in focus mode (or double-click the title)", action: onFocus)
                HeaderButton(symbol: collapsed ? "chevron.down" : "chevron.up", help: collapsed ? "Show content" : "Collapse to title", action: onCollapse)
                Menu {
                    if [.tokens, .capture, .inbox].contains(config.kind) { Button("Settings…", action: onSettings) }
                    if let widget = store.agentWidget(for: config) {
                        Button("Show widget file") { NSWorkspace.shared.activateFileViewerSelecting([widget.url]) }
                    }
                    Divider()
                    Button("Move up") { onMove(-1) }
                    Button("Move down") { onMove(1) }
                    Button(side == 0 ? "Move to right side" : "Move to left side", action: onSwitchSide)
                    Divider()
                    Button("Remove widget", role: .destructive) {
                        withAnimation { store.cockpitLayout.widgets.removeAll { $0.id == config.id } }
                        store.saveCockpitLayout()
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(style.secondaryText)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
            }
            .contentShape(Rectangle())
            // Drag the header to reorder, or onto the other side. The payload is the widget's ID.
            .draggable(config.id.uuidString) {
                Label(store.title(of: config), systemImage: store.symbol(of: config))
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(style.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(style.text)
            }
            .help("Drag to reorder or move to the other side · double-click to focus")
            if !collapsed {
                WidgetBody(config: config, onAddShortcut: onAddShortcut)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(style.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .background(style.glassFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.glassStroke, lineWidth: 0.7))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // Double-clicking anywhere on the card focuses it; Quick capture is excluded so double-clicking a word still selects it.
        .simultaneousGesture(TapGesture(count: 2).onEnded { onFocus() }, including: config.kind == .capture ? .subviews : .all)
    }
}

/// A widget header button with a comfortable 28-point click area and a hover highlight.
struct HeaderButton: View {
    @Environment(\.cockpitStyle) private var style
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? style.text : style.secondaryText)
                .frame(width: 28, height: 28)
                .background(hovering ? style.glassStroke : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Focus mode

/// One widget shown large over the dimmed Cockpit, with detail the compact widget leaves out.
struct FocusPanel: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    let config: WidgetConfig
    var onClose: () -> Void
    var onAddShortcut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: store.symbol(of: config)).foregroundStyle(style.accent)
                Text(store.title(of: config).uppercased()).font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(1)
                if let widget = store.agentWidget(for: config) {
                    Text("by \(widget.agentName)").font(.caption).foregroundStyle(style.secondaryText)
                }
                Spacer()
                HeaderButton(symbol: "xmark", help: "Close (Esc)", action: onClose)
                Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(style.glassStroke)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(style.background.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(style.glassStroke, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var content: some View {
        switch config.kind {
        case .inbox: InboxView()
        case .agent:
            ScrollView { AgentWidgetBody(config: config, full: true).padding(24).frame(maxWidth: 820, alignment: .topLeading) }
        case .tokens: TokensFocus()
        case .routines: RoutinesFocus()
        case .mail: ScrollView { MailWidget(full: true).padding(22).frame(maxWidth: .infinity, alignment: .topLeading) }
        case .schedule: ScrollView { ScheduleWidget(full: true).padding(22).frame(maxWidth: .infinity, alignment: .topLeading) }
        default:
            ScrollView {
                WidgetBody(config: config, onAddShortcut: onAddShortcut)
                    .font(.system(size: 14))
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Token usage for today, 7 days, and 30 days side by side, with every source.
struct TokensFocus: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                ForEach([1, 7, 30], id: \.self) { days in
                    let totals = store.usage[days] ?? UsageTotals()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(days == 1 ? "TODAY" : "\(days) DAYS").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(style.secondaryText)
                        Text(formatTokens(totals.tokens)).font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text("\(formatTokens(totals.output)) output").font(.caption).foregroundStyle(style.secondaryText)
                        Divider().overlay(style.glassStroke)
                        ForEach(totals.bySource.sorted { $0.value > $1.value }, id: \.key) { source, value in
                            HStack {
                                Text(source).font(.system(size: 12))
                                Spacer()
                                Text(formatTokens(value)).font(.system(size: 12).monospacedDigit())
                                Text(totals.tokens > 0 ? "\(Int((Double(value) / Double(totals.tokens) * 100).rounded()))%" : "")
                                    .font(.caption.monospacedDigit()).foregroundStyle(style.secondaryText).frame(width: 36, alignment: .trailing)
                            }
                            ProgressView(value: Double(value), total: Double(max(1, totals.tokens))).tint(style.accent)
                        }
                        Divider().overlay(style.glassStroke)
                        Text(totals.costSessions > 0 ? String(format: "≈ $%.2f API-equivalent across %d sessions with cost data", totals.costUSD, totals.costSessions)
                                                     : "No cost data yet in this range").font(.caption).foregroundStyle(style.secondaryText)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(style.glassFill, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(20)
            Text("Totals include cached context re-reads, which dominate long conversations. Output tokens show how much Claude actually wrote.")
                .font(.caption).foregroundStyle(style.secondaryText).padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
}

/// One question in the Ask panel. The run ID is also the Claude session ID, so it can be resumed in the Studio.
struct AskTurn: Identifiable, Equatable {
    var id: String
    var question: String
    var agentName: String
    var asked: Date
    var answer: String?
    var outcome = "running"
}

// MARK: - Note viewer

/// A vault note read inside ClaudeDesk: rendered Markdown with wikilinks you can follow, its properties,
/// and the notes it links to and from.
struct NoteViewer: View {
    @Environment(\.cockpitStyle) private var style
    let node: VaultNode
    let graph: VaultGraph
    let vault: URL?
    let canGoBack: Bool
    var onFollow: (String) -> Void
    var onBack: () -> Void
    var onClose: () -> Void
    var onObsidian: () -> Void

    var body: some View {
        let text = (try? String(contentsOf: node.url, encoding: .utf8)) ?? ""
        let stems = VaultNotes.stems(graph.nodes.map { (id: $0.id, url: $0.url) })
        let content = VaultNotes.body(of: text, title: node.title)
        let outgoing = VaultNotes.outgoing(content, stems: stems)
        let incoming = graph.nodes.filter { other in
            other.id != node.id && VaultNotes.outgoing((try? String(contentsOf: other.url, encoding: .utf8)) ?? "", stems: stems).contains(node.id)
        }.map(\.id)
        let properties = Frontmatter.parse(text).fields.compactMap { key, value -> (String, String)? in
            switch value {
            case .text(let string): return string.isEmpty ? nil : (key, string)
            case .list(let items): return items.isEmpty ? nil : (key, items.map { item in
                switch item { case .text(let s): return s; case .pair(let a, let b): return "\(a): \(b)" } }.joined(separator: ", "))
            }
        }.sorted { $0.0 < $1.0 }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if canGoBack { HeaderButton(symbol: "chevron.left", help: "Back (⌘[)", action: onBack).keyboardShortcut("[", modifiers: .command) }
                Image(systemName: node.kind == .home ? "house" : node.kind == .map ? "map" : "doc.text").foregroundStyle(style.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(node.id + " · edited " + node.modified.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(style.secondaryText).lineLimit(1)
                }
                Spacer()
                Button { onObsidian() } label: { Label("Open in Obsidian", systemImage: "arrow.up.right.square") }.buttonStyle(.borderless)
                HeaderButton(symbol: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                HeaderButton(symbol: "xmark", help: "Close (Esc)", action: onClose)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(style.glassStroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !properties.isEmpty {
                        FlowChips(items: properties.map { "\($0.0): \($0.1)" }, style: style)
                    }
                    MarkdownView(VaultNotes.linkified(content, stems: stems), context: MarkdownContext(
                        base: node.url.deletingLastPathComponent(), root: vault ?? node.url.deletingLastPathComponent(),
                        fontSize: 14, accent: style.accent,
                        openLink: { url in
                            guard let id = VaultNotes.noteID(from: url) else { return false }
                            onFollow(id); return true
                        }))
                    if !outgoing.isEmpty || !incoming.isEmpty {
                        Divider().overlay(style.glassStroke)
                        linkList("LINKS TO", outgoing)
                        linkList("LINKED FROM", incoming)
                    }
                }
                .padding(.horizontal, 26).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(style.background.opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(style.glassStroke, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 30)
    }

    @ViewBuilder private func linkList(_ title: String, _ ids: [String]) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(style.secondaryText)
                FlowChips(items: ids.compactMap { id in graph.nodes.first { $0.id == id }?.title }, style: style) { title in
                    if let id = graph.nodes.first(where: { $0.title == title })?.id { onFollow(id) }
                }
            }
        }
    }
}

/// Small rounded labels that wrap onto new lines; tappable when given an action.
private struct FlowChips: View {
    let items: [String]
    let style: CockpitThemeSettings
    var onTap: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item).font(.system(size: 11.5)).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(onTap == nil ? style.glassFill : style.accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(onTap == nil ? style.secondaryText : style.text)
                    .contentShape(Capsule())
                    .onTapGesture { onTap?(item) }
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new row when one doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (index, x) in row.items { subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified) }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width > 0, rows[rows.count - 1].width + spacing + size.width > width {
                let previous = rows[rows.count - 1]
                rows.append(Row(y: previous.y + previous.height + spacing))
            }
            let x = rows[rows.count - 1].width == 0 ? 0 : rows[rows.count - 1].width + spacing
            rows[rows.count - 1].items.append((index, x))
            rows[rows.count - 1].width = x + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Widget gallery

/// Every widget you can add, each shown as a live preview with what it does.
struct WidgetGallery: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    @Environment(\.dismiss) private var dismiss
    var onAddKind: (WidgetKind) -> Void
    var onAddAgentWidget: (AgentWidget) -> Void
    @State private var added: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ADD A WIDGET").font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            Divider().overlay(style.glassStroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("FROM YOUR AGENTS")
                    if store.agentWidgets.isEmpty {
                        Text("No agent widgets yet. Ask an agent to design one, for example “Make a Cockpit widget for …” — it follows the widget-instructions skill.")
                            .font(.callout).foregroundStyle(style.secondaryText)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(store.agentWidgets) { widget in
                                let config = WidgetConfig(kind: .agent, size: .small, settings: ["agent": widget.agentFolder, "widget": widget.name, "title": widget.title])
                                let placed = !store.unplacedAgentWidgets.contains(widget)
                                tile(title: widget.title, symbol: widget.validSymbol, summary: "By \(widget.agentName) · widgets/\(widget.name).md",
                                     preview: AnyView(AgentWidgetBody(config: config)), width: widget.width,
                                     state: placed ? "On your Cockpit" : added.contains(widget.id) ? "Added" : nil) {
                                    onAddAgentWidget(widget); added.insert(widget.id)
                                }
                            }
                        }
                    }
                    section("BUILT IN")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(WidgetKind.builtIn) { kind in
                            let count = store.cockpitLayout.widgets.filter { $0.kind == kind }.count
                            tile(title: kind.title, symbol: kind.symbol, summary: kind.summary,
                                 preview: AnyView(WidgetBody(config: WidgetConfig(kind: kind, size: .small), onAddShortcut: {})),
                                 width: kind == .capture ? 460 : kind == .activity || kind == .routines ? 320 : 270,
                                 state: added.contains(kind.rawValue) ? "Added" : count > 0 ? "On your Cockpit\(count > 1 ? " ×\(count)" : "")" : nil) {
                                onAddKind(kind); added.insert(kind.rawValue)
                            }
                        }
                    }
                }.padding(22)
            }
        }
        .frame(width: 1000, height: 700)
        .background(style.background)
        .foregroundStyle(style.text)
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(style.secondaryText)
    }

    /// A preview of the real widget (not clickable), its description, and Add. Widgets already placed can be added again.
    private func tile(title: String, symbol: String, summary: String, preview: AnyView, width: Double, state: String?, add: @escaping () -> Void) -> some View {
        let previewScale = min(1, 300 / width)
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(style.accent)
                        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(0.8).lineLimit(1)
                    }
                    preview
                }
                .padding(12)
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .scaleEffect(previewScale, anchor: .topLeading)
                // Scaling doesn't shrink the layout size, so the tile takes the scaled width explicitly.
                .frame(width: width * previewScale, alignment: .topLeading)
                .allowsHitTesting(false)
            }
            .frame(height: 190, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .background(style.glassFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.glassStroke, lineWidth: 0.7))
            Text(summary).font(.caption).foregroundStyle(style.secondaryText).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let state { Label(state, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(style.good) }
                Spacer()
                Button(state == nil ? "Add" : "Add another", action: add).buttonStyle(.borderedProminent).tint(style.accent).controlSize(.small)
            }
        }
        .padding(12)
        .background(style.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(style.glassStroke, lineWidth: 0.7))
    }
}

// MARK: - Cockpit | Studio switch

/// The two-way switch between the Cockpit and the Studio, shown at the top left of both screens.
struct ModeSwitch: View {
    @Binding var selection: String
    var text: Color
    var highlight: Color
    var track: Color
    @Namespace private var pill

    private let modes: [(id: String, title: String, symbol: String, key: String)] = [
        ("cockpit", "Cockpit", "sparkles", "⌘1"), ("studio", "Studio", "hammer", "⌘2")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.id) { mode in
                let selected = selection == mode.id
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = mode.id }
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(text.opacity(selected ? 1 : 0.65))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background {
                            if selected { Capsule().fill(highlight).matchedGeometryEffect(id: "selection", in: pill) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(mode.title) (\(mode.key))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(track, in: Capsule())
        .overlay(Capsule().stroke(text.opacity(0.14), lineWidth: 0.6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cockpit or Studio")
    }
}
