import SwiftUI

extension Notification.Name {
    static let workspaceAction = Notification.Name("ClaudeDesk.workspaceAction")
}

struct TerminalWorkspace: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskTheme) var theme
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @State private var focused: UUID?
    @State private var closing: RunningTerminal?
    @State private var showLayouts = false
    @State private var dragged: UUID?
    @State private var dropTarget: UUID?
    @State private var dropEdge = SnapEdge.center
    @State private var dividerStarts: [UUID: Double] = [:]

    private var terminals: [RunningTerminal] { store.workspaceTerminals }
    private var tree: PaneTree? {
        store.mode == .agents ? store.agentLayout : store.projectLayout
    }
    private func setTree(_ value: PaneTree?) {
        if store.mode == .agents { store.agentLayout = value } else { store.projectLayout = value }
    }
    private var active: UUID? {
        terminals.contains(where: { $0.id == store.activeTerminalID }) ? store.activeTerminalID : terminals.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            sessionStrip
            GeometryReader { proxy in
                let geometry = tree?.geometry() ?? PaneGeometry(panes: [:], dividers: [])
                let width = focused == nil ? max(proxy.size.width, geometry.panes.values.map { 290 / max(0.05, $0.width) }.max() ?? 0) : proxy.size.width
                let height = focused == nil ? max(proxy.size.height, geometry.panes.values.map { 190 / max(0.05, $0.height) }.max() ?? 0) : proxy.size.height
                let size = CGSize(width: width, height: height)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        ForEach(terminals) { terminal in
                            let normal = scaled(geometry.panes[terminal.id] ?? CGRect(x: 0, y: 0, width: 1, height: 1), size: size)
                            let rect = focused == terminal.id ? CGRect(origin: .zero, size: size) : normal
                            terminalPane(terminal, size: size, geometry: geometry)
                                .frame(width: max(1, rect.width - 8), height: max(1, rect.height - 8))
                                .position(x: rect.midX, y: rect.midY)
                                .opacity(focused == nil || focused == terminal.id ? 1 : 0)
                                .allowsHitTesting(focused == nil || focused == terminal.id)
                                .accessibilityHidden(focused != nil && focused != terminal.id)
                        }
                        if focused == nil {
                            ForEach(geometry.dividers) { divider in dividerHandle(divider, size: size) }
                        }
                        if let target = dropTarget, let normalized = geometry.panes[target], dragged != nil {
                            let preview = SnapTarget.preview(scaled(normalized, size: size), edge: dropEdge).insetBy(dx: 6, dy: 6)
                            RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.22))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accent, lineWidth: 2))
                                .overlay(Text(dropEdge == .center ? "Swap panes" : "Snap \(dropEdge.rawValue)")
                                    .font(.callout.bold()).padding(8).background(theme.panel, in: Capsule()))
                                .frame(width: max(1, preview.width), height: max(1, preview.height))
                                .position(x: preview.midX, y: preview.midY).allowsHitTesting(false)
                        }
                    }.frame(width: size.width, height: size.height).coordinateSpace(name: "terminalCanvas")
                }
            }
            HStack(spacing: 14) {
                Image(systemName: "circle.grid.2x2").foregroundStyle(theme.accent)
                Text("Drag header to snap · Shift-scroll for history")
                Spacer()
                Text("⌘1–9 select   ⇧⌘↵ focus")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .background(Color(nsColor: theme.background))
        .onAppear(perform: reconcile)
        .onChange(of: store.mode) { _, _ in focused = nil; reconcile() }
        .onChange(of: terminals.map(\.id)) { _, _ in reconcile() }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceAction)) { notification in
            guard let action = notification.object as? String else { return }
            handleAction(action)
        }
        .alert("Stop and close this instance?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("Cancel", role: .cancel) { closing = nil }
            Button("Stop and close", role: .destructive) {
                if let terminal = closing { store.closeTerminal(terminal) }
                closing = nil
            }
        } message: { Text("This ends this Claude process. Other instances and saved shortcuts are kept.") }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(theme.accent)
            Text(store.mode == .agents ? "Agent workspace" : "Workspace").font(.system(.headline, design: .monospaced))
            Text("\(terminals.count)").font(.caption.monospacedDigit()).padding(.horizontal, 7).padding(.vertical, 3).background(theme.panel, in: Capsule())
            Spacer()
            Button { showLayouts.toggle() } label: { Label("Snap layout", systemImage: "rectangle.split.2x2") }
                .popover(isPresented: $showLayouts) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Snap layouts").font(.headline)
                        Text("Choose a starting arrangement, then drag dividers to adjust.").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.fixed(140)), GridItem(.fixed(140))], spacing: 10) {
                            ForEach(SnapPreset.allCases) { preset in
                                Button {
                                    apply(preset)
                                    showLayouts = false
                                } label: {
                                    VStack(spacing: 8) {
                                        LayoutThumbnail(preset: preset).frame(width: 115, height: 60)
                                        Text(preset.rawValue).font(.caption)
                                    }.padding(10).background(theme.panel, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                        Button("Reset divider sizes") { apply(.balanced); showLayouts = false }
                    }.padding(18)
                }
            Button { toggleFocus(active) } label: { Image(systemName: focused == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") }
                .help("Focus active pane (⇧⌘Return)")
            Menu {
                Button("Larger text") { fontSize = min(32, fontSize + 1) }
                Button("Smaller text") { fontSize = max(6, fontSize - 1) }
                Button("Reset text size") { fontSize = 13 }
            } label: { Image(systemName: "textformat.size") }.menuStyle(.borderlessButton).fixedSize()

        }.controlSize(.small).buttonStyle(.bordered).padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                    Button { select(terminal.id) } label: {
                        HStack(spacing: 6) {
                            ClaudeSessionMark(color: sessionColor(terminal.colorIndex)).frame(width: 14, height: 14)
                            Text("\(index + 1)").foregroundStyle(.secondary).font(.caption.monospacedDigit())
                            Text(terminal.session.name).lineLimit(1)
                            Text(terminal.shortLabel).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(active == terminal.id ? theme.accent.opacity(0.18) : theme.panel, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(active == terminal.id ? theme.accent.opacity(0.6) : .clear))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func terminalPane(_ terminal: RunningTerminal, size: CGSize, geometry: PaneGeometry) -> some View {
        TerminalPane(terminal: terminal, color: sessionColor(terminal.colorIndex), selected: active == terminal.id, focused: focused == terminal.id,
                     focus: { toggleFocus(terminal.id) }, close: {
                         if terminal.running { closing = terminal } else { store.closeTerminal(terminal) }
                     }, activate: { store.activeTerminalID = terminal.id },
                     dragChanged: { localPoint in
                         let pane = scaled(geometry.panes[terminal.id] ?? .zero, size: size)
                         let point = CGPoint(x: pane.minX + 13 + localPoint.x, y: pane.minY + 4 + localPoint.y)
                         guard focused == nil else { return }
                         dragged = terminal.id
                         dropTarget = geometry.panes.first(where: { $0.key != terminal.id && scaled($0.value, size: size).contains(point) })?.key
                         if let target = dropTarget, let rect = geometry.panes[target] {
                             dropEdge = SnapTarget.edge(at: point, in: scaled(rect, size: size))
                         }
                     }, dragEnded: {
                         if let source = dragged, let target = dropTarget { setTree(tree?.docking(source, beside: target, edge: dropEdge)) }
                         dragged = nil; dropTarget = nil
                     }, dock: { edge in
                         let ids = tree?.leaves ?? terminals.map(\.id)
                         guard let index = ids.firstIndex(of: terminal.id), ids.count > 1 else { return }
                         let target = ids[(index + 1) % ids.count]
                         setTree(tree?.docking(terminal.id, beside: target, edge: edge))
                     })
    }

    private func dividerHandle(_ divider: PaneDivider, size: CGSize) -> some View {
        let rect = scaled(divider.rect, size: size)
        let x = divider.horizontal ? rect.minX + rect.width * divider.ratio : rect.midX
        let y = divider.horizontal ? rect.midY : rect.minY + rect.height * divider.ratio
        return RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.25))
            .frame(width: divider.horizontal ? 4 : max(1, rect.width - 12), height: divider.horizontal ? max(1, rect.height - 12) : 4)
            .padding(divider.horizontal ? .horizontal : .vertical, 2)
            .contentShape(Rectangle())
            .overlay(PaneDragSurface(cursor: divider.horizontal ? .resizeLeftRight : .resizeUpDown,
                                     changed: { _, translation in
                if dividerStarts[divider.id] == nil { dividerStarts[divider.id] = divider.ratio }
                let delta = divider.horizontal ? translation.width / rect.width : translation.height / rect.height
                setTree(tree?.settingRatio(divider.id, to: (dividerStarts[divider.id] ?? divider.ratio) + delta))
            }, ended: { dividerStarts.removeValue(forKey: divider.id) }))
            .help("Drag to resize adjacent panes")
            .accessibilityLabel(divider.horizontal ? "Resize columns" : "Resize rows")
            .accessibilityAdjustableAction { direction in
                setTree(tree?.settingRatio(divider.id, to: divider.ratio + (direction == .increment ? 0.05 : -0.05)))
            }
            .position(x: x, y: y)
    }

    private func scaled(_ rect: CGRect, size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }
    private func reconcile() {
        let ids = terminals.map(\.id)
        setTree(tree?.reconciled(with: ids) ?? PaneTree.make(ids, preset: .balanced))
        if let focused, !ids.contains(focused) { self.focused = nil }
        if !ids.contains(store.activeTerminalID ?? UUID()) { store.activeTerminalID = ids.first }
    }
    private func apply(_ preset: SnapPreset) {
        focused = nil
        setTree(PaneTree.make(tree?.leaves ?? terminals.map(\.id), preset: preset))
    }
    private func select(_ id: UUID) {
        store.activeTerminalID = id
        if focused != nil { focused = id }
        if let terminal = terminals.first(where: { $0.id == id }) { terminal.view.window?.makeFirstResponder(terminal.view) }
    }
    private func toggleFocus(_ id: UUID?) {
        guard let id else { return }
        focused = focused == id ? nil : id
        select(id)
    }
    private func handleAction(_ action: String) {
        if action == "focus" { toggleFocus(active) }
        else if action == "reset" { apply(.balanced) }
        else if action == "next" || action == "previous" {
            guard !terminals.isEmpty else { return }
            let current = terminals.firstIndex { $0.id == active } ?? 0
            select(terminals[(current + (action == "next" ? 1 : terminals.count - 1)) % terminals.count].id)
        } else if let index = Int(action), terminals.indices.contains(index) { select(terminals[index].id) }
    }
}

private struct TerminalPane: View {
    @Environment(\.deskTheme) var theme
    @ObservedObject var terminal: RunningTerminal
    let color: Color
    let selected: Bool
    let focused: Bool
    let focus: () -> Void
    let close: () -> Void
    let activate: () -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: () -> Void
    let dock: (SnapEdge) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.secondary)
                    ClaudeSessionMark(color: terminal.running ? color : .gray).frame(width: 16, height: 16)
                    Text(terminal.session.name).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                    Text("· " + (terminal.session.name.hasPrefix(terminal.project.name) ? "" : terminal.project.name + " · ") + terminal.shortLabel)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        .help(terminal.sessionID.map { "Claude session \($0)" } ?? "Session ID not known (chosen from history)")
                    Spacer(minLength: 2)
                }.frame(maxHeight: .infinity)
                    .overlay(PaneDragSurface(click: { count in
                        activate()
                        if count == 2 { focus() }
                    }, changed: { point, _ in activate(); dragChanged(point) }, ended: dragEnded))
                    .help("Drag to an edge to split; drop in the center to swap. Double-click to focus.")
                Menu {
                    Text(terminal.status + " · " + (terminal.sessionID ?? "session ID not known"))
                    if let sessionID = terminal.sessionID {
                        Button("Copy session ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sessionID, forType: .string)
                        }
                    }
                    ForEach(SnapEdge.allCases, id: \.self) { edge in
                        Button(edge == .center ? "Swap with next pane" : "Snap \(edge.rawValue) of next pane") { dock(edge) }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 15)
                Button { terminal.attachFiles() } label: { Image(systemName: "paperclip") }.help("Insert file paths into chat draft").disabled(!terminal.running)
                Button(action: focus) { Image(systemName: focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.help("Toggle focus")
                Button(action: close) { Image(systemName: "xmark") }.help("Close instance")
            }.font(.system(size: 10)).buttonStyle(.borderless).padding(.horizontal, 9).frame(height: 32)
                .background(selected ? theme.accent.opacity(0.10) : theme.panel)
            TerminalSurface(terminal: terminal)

                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Color(nsColor: theme.background))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? theme.accent.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
    }
}

private struct LayoutThumbnail: View {
    @Environment(\.deskTheme) var theme
    let preset: SnapPreset
    private static let sampleIDs = (0..<4).map { _ in UUID() }
    var body: some View {
        GeometryReader { proxy in
            let rects = PaneTree.make(Self.sampleIDs, preset: preset)!.geometry().panes
            ZStack(alignment: .topLeading) {
                ForEach(Self.sampleIDs, id: \.self) { id in
                    if let r = rects[id] {
                        RoundedRectangle(cornerRadius: 3).fill(theme.accent.opacity(0.35)).overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent.opacity(0.8)))
                            .frame(width: max(1, r.width * proxy.size.width - 4), height: max(1, r.height * proxy.size.height - 4))
                            .position(x: r.midX * proxy.size.width, y: r.midY * proxy.size.height)
                    }
                }
            }
        }
    }
}
