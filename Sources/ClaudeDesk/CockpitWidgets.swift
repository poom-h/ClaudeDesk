import SwiftUI
import AppKit

func formatTokens(_ value: Int) -> String {
    switch value {
    case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: return String(format: "%.0fk", Double(value) / 1_000)
    default: return "\(value)"
    }
}

/// The content of one widget, chosen by its kind.
struct WidgetBody: View {
    let config: WidgetConfig
    var onAddShortcut: () -> Void

    var body: some View {
        switch config.kind {
        case .today: TodayWidget()
        case .activity: ActivityWidget()
        case .inbox: InboxWidget(limit: Int(config.settings["count"] ?? "") ?? 4)
        case .agent: AgentWidgetBody(config: config)
        case .mail: MailWidget(full: false)
        case .schedule: ScheduleWidget(full: false)
        case .news: EmptyView()   // migrated to an agent widget when the Cockpit opens
        case .routines: RoutinesTodayWidget()
        case .tokens: TokenUsageWidget(days: Int(config.settings["days"] ?? "") ?? 1)
        case .limits: PlanLimitsWidget()
        case .shortcuts: ShortcutsWidget(onAdd: onAddShortcut)
        case .capture: CaptureWidget(agent: config.settings["agent"] ?? "atlas")
        case .agents: AgentsWidget()
        case .vault: VaultHealthWidget()
        }
    }
}

// MARK: - Today

struct TodayWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    var body: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let summary = store.routineSummary()
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting).font(.system(size: 22, weight: .semibold))
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.caption).foregroundStyle(style.secondaryText)
            Label("\(store.pendingInboxCount) on your Desk", systemImage: "tray.full").foregroundStyle(store.pendingInboxCount > 0 ? style.warning : style.secondaryText)
            Label("Routines: \(summary.text)", systemImage: "clock").foregroundStyle(summary.tone == .attention ? style.danger : style.secondaryText)
            if let five = store.planLimits?.fiveHour { Label("5h limit \(Int(five.used.rounded()))%", systemImage: "gauge.with.dots.needle.33percent").foregroundStyle(five.used > 80 ? style.warning : style.secondaryText) }
        }.font(.caption)
    }
}

// MARK: - Activity

struct ActivityWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    @State private var detail: LiveRun?

    var body: some View {
        let activity = store.activity()
        VStack(alignment: .leading, spacing: 9) {
                ForEach(activity.agents) { row in agentRow(row) }
                if !activity.projects.isEmpty {
                    Text("PROJECTS").font(.caption2.weight(.semibold)).foregroundStyle(style.secondaryText).padding(.top, 4)
                    ForEach(activity.projects) { row in agentRow(row) }
                }
                if activity.agents.isEmpty && activity.projects.isEmpty {
                    Text("No agents yet. Create one in the Studio.").foregroundStyle(style.secondaryText)
                }
        }
        .popover(item: $detail) { run in RunDetail(run: run).environmentObject(store).frame(width: 420, height: 320) }
    }

    private func color(_ state: AgentActivity.State) -> Color {
        switch state {
        case .running: return style.warning
        case .conversation: return style.good
        case .waiting: return style.accent
        case .idle: return style.secondaryText.opacity(0.5)
        }
    }

    private func agentRow(_ row: AgentActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(color(row.state)).frame(width: 7, height: 7)
                Text(row.title).font(.system(size: 13, weight: .medium))
                Text(row.detail).font(.system(size: 12)).foregroundStyle(style.secondaryText).lineLimit(1)
                Spacer(minLength: 4)
                if let since = row.since { Text(since, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(style.secondaryText) }
                if let run = row.run {
                    Button("Stop") { store.stopRun(run) }.buttonStyle(.plain).font(.caption).foregroundStyle(style.danger)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let run = row.run { detail = run } else if let pane = row.terminalID { store.openInStudio(terminal: pane) }
            }
            ForEach(row.finishedRuns.prefix(2)) { run in
                Button { detail = run } label: {
                    HStack(spacing: 6) {
                        Image(systemName: run.status == "ok" ? "checkmark.circle" : run.status == "stopped" ? "stop.circle" : "exclamationmark.triangle")
                            .foregroundStyle(run.status == "ok" ? style.good : run.status == "stopped" ? style.secondaryText : style.danger)
                        Text("\(run.title): \(run.result.isEmpty ? run.status : run.result)").lineLimit(1)
                    }.font(.caption).foregroundStyle(style.secondaryText)
                }.buttonStyle(.plain).padding(.leading, 15)
            }
        }
    }
}

struct RunDetail: View {
    @EnvironmentObject var store: DeskStore
    let run: LiveRun
    var body: some View {
        let current = store.liveRuns.first { $0.runID == run.runID } ?? run
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(current.title).font(.headline)
                Spacer()
                Text(current.status).font(.caption.weight(.semibold))
            }
            Text("Started \(current.started.formatted(date: .omitted, time: .shortened)) · run \(String(current.runID.prefix(8)))").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(current.steps.enumerated()), id: \.offset) { _, step in Label(step, systemImage: "arrow.turn.down.right").font(.callout) }
            if !current.result.isEmpty {
                Divider()
                ScrollView { Text(current.result).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Spacer()
            HStack {
                if current.status == "running" { Button("Stop", role: .destructive) { store.stopRun(current) } }
                Spacer()
                if let agent = store.agents.first(where: { $0.id.uuidString == current.agentID }) {
                    Button("Open conversation") {
                        store.openInStudio()
                        store.launchAgent(agent, arguments: ["--resume", current.runID])
                    }
                }
            }
        }.padding(16)
    }
}

// MARK: - Inbox

struct InboxWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    let limit: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if store.inboxItems.isEmpty { Text("Your Desk is clear.").foregroundStyle(style.secondaryText) }
            ForEach(store.inboxItems.prefix(limit)) { item in
                HStack(spacing: 8) {
                    Image(systemName: InboxItemDetail.symbol(item.kind)).foregroundStyle(item.kind == "alert" ? style.danger : style.accent).frame(width: 16)
                    Text(item.title).lineLimit(1).font(.system(size: 12))
                    Spacer(minLength: 4)
                    if item.problem == nil && (item.kind == "message" || item.kind == "alert") {
                        Button("Done") { store.resolve(item, decision: .done, note: "", enabled: []) }.buttonStyle(.plain).foregroundStyle(style.accent)
                    } else if item.problem == nil && item.kind == "routine" {
                        Button("Approve") { store.resolve(item, decision: .approve, note: "", enabled: Set(item.onApprove.map(\.index))) }
                            .buttonStyle(.plain).foregroundStyle(style.good)
                    } else {
                        Button("Open") { store.openInStudio(inbox: true) }.buttonStyle(.plain).foregroundStyle(style.secondaryText)
                    }
                }.font(.caption)
            }
            if store.inboxItems.count > limit {
                Button("\(store.inboxItems.count - limit) more…") { store.openInStudio(inbox: true) }.buttonStyle(.plain).font(.caption).foregroundStyle(style.secondaryText)
            }
        }
    }
}

// MARK: - Mail and schedule

/// A colour per connected Google account, in the order they were added.
func accountColor(_ account: String, in accounts: [String]) -> Color {
    let palette: [Color] = [Color(red: 0.42, green: 0.62, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.32), Color(red: 0.45, green: 0.86, blue: 0.58),
                            Color(red: 0.86, green: 0.5, blue: 1.0), Color(red: 1.0, green: 0.45, blue: 0.5), Color(red: 0.35, green: 0.85, blue: 0.88)]
    return palette[(accounts.firstIndex(of: account) ?? 0) % palette.count]
}

/// Mail across accounts in Jev's order. The compact card shows the top few; focus mode adds filters and snippets.
struct MailWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    var full: Bool
    @State private var category = "all"
    @State private var account = "all"

    var body: some View {
        if !store.mailConnected {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your mail to see it here, sorted by Jev.").font(.caption).foregroundStyle(style.secondaryText)
                SettingsLink { Label("Open Settings › Integrations", systemImage: "key") }.buttonStyle(.plain).font(.caption).foregroundStyle(style.accent)
            }
        } else {
            let ordered = JevTriage.ordered(store.mailMessages)
            let triaged = ordered.compactMap(\.triage)
            let shown = ordered.filter { (category == "all" || $0.triage?.category == category) && (account == "all" || $0.account == account) }
            VStack(alignment: .leading, spacing: full ? 10 : 6) {
                HStack(spacing: 10) {
                    badge("\(triaged.filter(JevTriage.isUrgent).count) urgent", style.danger)
                    badge("\(triaged.filter(JevTriage.needsReply).count) reply", style.warning)
                    let suspicious = triaged.filter(JevTriage.isSuspicious).count
                    if suspicious > 0 { badge("\(suspicious) suspicious", style.danger).help("Jev's text screen flagged these as possible phishing. It isn't sender authentication: check before acting.") }
                    Spacer()
                    if store.mailRefreshing { ProgressView().controlSize(.mini) }
                    else { Button { store.refreshMail() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(style.secondaryText).help("Refresh mail") }
                }
                if full { filters(ordered) }
                if shown.isEmpty { Text(store.mailRefreshing ? "Fetching mail…" : "Nothing here.").font(.caption).foregroundStyle(style.secondaryText) }
                ForEach(Array(shown.prefix(full ? 60 : 6))) { message in row(message) }
                if !full, ordered.count > 6 { Text("\(ordered.count - 6) more · double-click for all").font(.caption2).foregroundStyle(style.secondaryText) }
                if !store.mailStatus.isEmpty { Text(store.mailStatus).font(.caption2).foregroundStyle(style.secondaryText).lineLimit(2) }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(color)
    }

    @ViewBuilder private func filters(_ messages: [MailMessage]) -> some View {
        HStack(spacing: 6) {
            ForEach([("all", "All")] + JevTriage.categories.map { ($0.key, $0.label) }, id: \.0) { key, label in
                let count = key == "all" ? messages.count : messages.filter { $0.triage?.category == key }.count
                if count > 0 || key == "all" {
                    Button { category = key } label: {
                        Text("\(label) \(count)").font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(category == key ? style.accent.opacity(0.3) : style.glassFill, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            if store.mailAccountList.count > 1 {
                Picker("Account", selection: $account) {
                    Text("All accounts").tag("all")
                    ForEach(store.mailAccountList, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 200)
            }
        }
    }

    private func row(_ message: MailMessage) -> some View {
        let triage = message.triage
        return Button { if let url = message.webURL { NSWorkspace.shared.open(url) } } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(accountColor(message.account, in: store.mailAccountList)).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(message.sender).font(.system(size: full ? 12.5 : 11.5, weight: message.unread ? .semibold : .regular)).lineLimit(1)
                        if let triage {
                            if JevTriage.isSuspicious(triage) { Image(systemName: "exclamationmark.shield.fill").font(.system(size: 10)).foregroundStyle(style.danger) }
                            else if JevTriage.isUrgent(triage) { Text("URGENT").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(style.danger) }
                            else if JevTriage.needsReply(triage) { Text("REPLY").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(style.warning) }
                        }
                        Spacer(minLength: 4)
                        Text(message.date.formatted(Calendar.current.isDateInToday(message.date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(style.secondaryText)
                    }
                    HStack(spacing: 5) {
                        if let triage {
                            Text(JevTriage.label(for: triage.category)).font(.system(size: 9.5)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(style.glassFill, in: Capsule()).foregroundStyle(style.secondaryText)
                        }
                        Text(message.subject).font(.system(size: full ? 12 : 11)).foregroundStyle(style.text.opacity(0.85)).lineLimit(1)
                    }
                    if full, !message.snippet.isEmpty {
                        Text(message.snippet).font(.system(size: 11)).foregroundStyle(style.secondaryText).lineLimit(2)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(triage.map { "Jev: \(JevTriage.label(for: $0.category)) (\(Int($0.confidence * 100))% sure) · urgent \(Int($0.urgent * 100))% · reply \(Int($0.replyNeeded * 100))% · suspicious \(Int($0.suspicious * 100))%. Click to open in Gmail." } ?? "Not sorted yet. Click to open in Gmail.")
    }
}

/// Today's events across accounts (and tomorrow's in focus mode), with what's next.
struct ScheduleWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    var full: Bool

    var body: some View {
        if !store.mailConnected {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your calendar to see your day here.").font(.caption).foregroundStyle(style.secondaryText)
                SettingsLink { Label("Open Settings › Integrations", systemImage: "key") }.buttonStyle(.plain).font(.caption).foregroundStyle(style.accent)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now = context.date, calendar = Calendar.current
                let today = store.calendarEvents.filter { calendar.isDate($0.start, inSameDayAs: now) || ($0.allDay && $0.start <= now && $0.end > now) }
                let tomorrow = store.calendarEvents.filter { calendar.isDateInTomorrow($0.start) }
                let next = today.first { !$0.allDay && $0.end > now }
                VStack(alignment: .leading, spacing: 6) {
                    if let next {
                        let minutes = Int(next.start.timeIntervalSince(now) / 60)
                        Text(minutes <= 0 ? "Now: \(next.title)" : minutes < 90 ? "Next: \(next.title) in \(minutes) min" : "Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    } else {
                        Text(today.isEmpty ? "Nothing scheduled today." : "Done for today.").font(.system(size: 12.5, weight: .semibold))
                    }
                    ForEach(today) { event in row(event, now: now) }
                    if full {
                        Text("TOMORROW").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(style.secondaryText).padding(.top, 6)
                        if tomorrow.isEmpty { Text("Nothing yet.").font(.caption).foregroundStyle(style.secondaryText) }
                        ForEach(tomorrow) { event in row(event, now: now) }
                    } else if !tomorrow.isEmpty {
                        Text("Tomorrow: \(tomorrow.count) event\(tomorrow.count == 1 ? "" : "s"), first at \(tomorrow.first { !$0.allDay }?.start.formatted(date: .omitted, time: .shortened) ?? "all day")")
                            .font(.caption2).foregroundStyle(style.secondaryText)
                    }
                }
            }
        }
    }

    private func row(_ event: CalendarEvent, now: Date) -> some View {
        let past = event.end <= now, current = event.start <= now && event.end > now
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(accountColor(event.account, in: store.mailAccountList)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 11.5, weight: current ? .semibold : .regular)).lineLimit(1)
                Text(event.allDay ? "All day" : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))\(event.location.isEmpty ? "" : " · " + event.location)")
                    .font(.system(size: 10)).foregroundStyle(style.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let link = event.meetLink, let url = URL(string: link), !past {
                Button("Join") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(style.accent)
            }
        }
        .opacity(past ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let link = event.webLink, let url = URL(string: link) { NSWorkspace.shared.open(url) } }
        .help(event.webLink == nil ? event.account : "\(event.account) · double-click to open in Google Calendar")
    }
}

// MARK: - Agent widgets

/// A widget an agent designs in `<agent>/widgets/<name>.md`. The card shows here; focus mode adds the full part.
struct AgentWidgetBody: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    let config: WidgetConfig
    var full = false

    var body: some View {
        if let widget = store.agentWidget(for: config) {
            MarkdownView(blocks: full ? widget.card + widget.full : widget.card, context: context(for: widget))
                .foregroundStyle(style.text)
        } else {
            let agent = store.agents.matching(config.settings["agent"] ?? "")?.name ?? config.settings["agent"] ?? "The agent"
            Text("Waiting for \(agent) to write widgets/\(config.settings["widget"] ?? "widget").md.")
                .font(.caption).foregroundStyle(style.secondaryText)
        }
    }

    private func context(for widget: AgentWidget) -> MarkdownContext {
        let actions = MarkdownActions(
            run: { title, instruction, skill, webFetch in store.runWidgetAction(widget, title: title, instruction: instruction, skill: skill, webFetch: webFetch) },
            toggle: { line, checked in store.setWidgetChecked(widget, line: line, checked: checked) },
            agentName: widget.agentName)
        return MarkdownContext(base: widget.folder, root: widget.folder, actions: actions,
                               fontSize: full ? 14 : 12, maxImageHeight: full ? 320 : 150, accent: style.accent)
    }
}

// MARK: - Routines

/// Today's routines as they actually happened: every run (scheduled or manual), what's running or queued now,
/// what's still due, what needs the user, and what comes next.
struct RoutinesTodayWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    @State private var hovered: String?
    @State private var detail: RoutineRunRecord?

    private enum Entry: Identifiable {
        case run(RoutineRunRecord)
        case slot(name: String, time: Date)
        case queued(name: String)
        var id: String {
            switch self {
            case .run(let record): return record.runID
            case .slot(let name, let time): return "slot-\(name)-\(time.timeIntervalSince1970)"
            case .queued(let name): return "queued-\(name)"
            }
        }
        var name: String {
            switch self { case .run(let record): return record.routine; case .slot(let name, _), .queued(let name): return name }
        }
    }

    var body: some View {
        let liveRuns = store.workspaceURL.map { LiveRun.load(in: $0) } ?? []
        let anyRunning = liveRuns.contains { $0.kind == "routine" && $0.status == "running" }
        // Tick every second only while something runs, for the elapsed time; otherwise twice a minute.
        TimelineView(.periodic(from: .now, by: anyRunning ? 1 : 30)) { context in
            content(now: context.date)
        }
        .popover(item: $detail) { record in RoutineRunDetail(record: record).environmentObject(store) }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let attention = attentionRows()
        let all = timeline(now: now)
        // Keep the card short: the latest five entries, with the rest in focus mode.
        let entries = Array(all.suffix(5))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attention, id: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(style.warning).font(.caption)
                    Text(row.name).font(.system(size: 12, design: .monospaced))
                    Text(row.reason).font(.caption).foregroundStyle(style.warning).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Review", action: row.action).buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(style.accent)
                }
            }
            if !attention.isEmpty && !entries.isEmpty { Divider().overlay(style.glassStroke) }
            if entries.isEmpty && attention.isEmpty {
                Text(store.runnerEnabled ? "No routines today." : "Background routines are off.").font(.caption).foregroundStyle(style.secondaryText)
            }
            if all.count > entries.count {
                Text("\(all.count - entries.count) earlier · double-click for the full day").font(.caption2).foregroundStyle(style.secondaryText)
            }
            ForEach(entries) { entry in row(entry, now: now) }
            if let next = nextUp(now: now) {
                Text("Next: \(next.name) · \(Self.day(next.time, now: now)) \(next.time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(style.secondaryText)
            }
            Button("Open routines") { store.showRoutines = true }.buttonStyle(.plain).font(.caption).foregroundStyle(style.accent)
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ entry: Entry, now: Date) -> some View {
        let routine = store.routineList.first { $0.name == entry.name }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time(of: entry).formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit())
                .foregroundStyle(style.secondaryText).frame(width: 58, alignment: .leading)
            // One line when name and status fit; otherwise the status wraps under the name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { title(entry); status(of: entry, now: now, compact: true).fixedSize() }
                VStack(alignment: .leading, spacing: 2) { title(entry); status(of: entry, now: now, compact: true) }
            }
            Spacer(minLength: 2)
            if case .run(let record) = entry, let live = liveRun(record), live.status == "running" {
                HeaderButton(symbol: "stop.fill", help: "Stop this run") { store.stopRun(live) }
            } else if hovered == entry.id {
                if let routine { HeaderButton(symbol: "play.fill", help: runHelp(routine)) { store.runNow(routine) }.disabled(!canRun(routine)) }
                if case .run(let record) = entry { HeaderButton(symbol: "list.bullet.rectangle", help: "Show steps and result") { detail = record } }
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil } }
        .onTapGesture { if case .run(let record) = entry { detail = record } }
    }

    private func title(_ entry: Entry) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(of: entry)).frame(width: 7, height: 7)
            Text(entry.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).fixedSize()
            if case .run(let record) = entry, record.manual {
                Text("manual").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(style.glassStroke, in: Capsule()).foregroundStyle(style.secondaryText)
            }
        }
    }

    /// Compact rows leave out how long a finished run took; it's in the tooltip, the steps popover, and focus mode.
    @ViewBuilder private func status(of entry: Entry, now: Date, compact: Bool = false) -> some View {
        switch entry {
        case .queued:
            Label("starting…", systemImage: "hourglass").font(.caption).foregroundStyle(style.accent)
        case .slot(_, let time):
            Text(time < now ? "due · not run yet" : "next").font(.caption).foregroundStyle(time < now ? style.warning : style.secondaryText)
        case .run(let record):
            if let live = liveRun(record), live.status == "running" {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Running · \(RoutineHistory.duration(Int(now.timeIntervalSince(live.started))))").font(.caption).foregroundStyle(style.accent)
                }
                if let step = live.steps.last { Text(step).font(.caption2).foregroundStyle(style.secondaryText).lineLimit(1) }
            } else if record.outcome == "running" {
                Text("interrupted").font(.caption).foregroundStyle(style.danger)
            } else {
                let took = record.seconds.map { " · " + RoutineHistory.duration($0) } ?? ""
                Text("\(Self.outcomeText(record.outcome))\(compact ? "" : took) · \(Self.ago(record.finished ?? record.started, now: now))")
                    .font(.caption).foregroundStyle(record.succeeded ? style.secondaryText : style.danger).lineLimit(1)
                    .help(record.seconds.map { "Took \(RoutineHistory.duration($0))" } ?? "")
            }
        }
    }

    private func time(of entry: Entry) -> Date {
        switch entry {
        case .run(let record): return record.started
        case .slot(_, let time): return time
        case .queued: return Date()
        }
    }

    private func color(of entry: Entry) -> Color {
        switch entry {
        case .queued: return style.accent
        case .slot(_, let time): return time < Date() ? style.warning : style.secondaryText.opacity(0.5)
        case .run(let record):
            if liveRun(record)?.status == "running" { return style.accent }
            return record.outcome == "running" || !record.succeeded ? style.danger : style.good
        }
    }

    private func liveRun(_ record: RoutineRunRecord) -> LiveRun? {
        store.workspaceURL.flatMap { Routines.load(LiveRun?.self, from: LiveRun.file(in: $0, runID: record.runID), default: nil) }
    }

    // MARK: Building the day

    /// Today's runs, plus scheduled times not yet run and anything queued, in time order.
    private func timeline(now: Date) -> [Entry] {
        let calendar = Calendar.current
        let today = store.routineRuns.filter { calendar.isDate($0.started, inSameDayAs: now) }
        var entries = today.map(Entry.run)
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        for routine in store.routineList where routine.problem == nil && routine.enabled && reasons(routine).isEmpty {
            guard let schedule = routine.schedule,
                  let occurrence = schedule.lastOccurrence(atOrBefore: endOfDay), calendar.isDate(occurrence, inSameDayAs: now) else { continue }
            let covered = today.contains { $0.routine == routine.name && !$0.manual && $0.started >= occurrence.addingTimeInterval(-60) }
            if !covered { entries.append(.slot(name: routine.name, time: occurrence)) }
        }
        if let workspace = store.workspaceURL {
            for routine in store.routineList where Routines.busy(routine.name, workspace: workspace, now: now) == "queued" {
                entries.append(.queued(name: routine.name))
            }
        }
        return entries.sorted { time(of: $0) < time(of: $1) }
    }

    private struct Attention { let name: String; let reason: String; let action: () -> Void }

    /// Routines that need the user: broken, waiting for approval, or whose latest run failed.
    private func attentionRows() -> [Attention] {
        let approvals = store.workspaceURL.map { Routines.load(RoutineApprovals.self, from: Routines.approvalsFile(in: $0), default: RoutineApprovals()) } ?? RoutineApprovals()
        return store.routineList.compactMap { routine in
            if routine.problem != nil { return Attention(name: routine.name, reason: "needs fixing", action: { store.showRoutines = true }) }
            guard routine.enabled else { return nil }
            if !Routines.approvalReasons(routine, grant: approvals.grants[routine.name]).isEmpty {
                guard approvals.rejected[routine.name] != routine.fingerprint else { return nil }
                return Attention(name: routine.name, reason: "waiting for approval", action: { store.openInStudio(inbox: true) })
            }
            if let last = store.routineRuns.last(where: { $0.routine == routine.name }), last.outcome != "running", !last.succeeded,
               !Calendar.current.isDateInToday(last.started) {
                // Today's failures already show in the timeline; older ones would otherwise be invisible.
                return Attention(name: routine.name, reason: "last run \(Self.outcomeText(last.outcome))", action: { detail = last })
            }
            return nil
        }
    }

    private func reasons(_ routine: Routine) -> [String] {
        let approvals = store.workspaceURL.map { Routines.load(RoutineApprovals.self, from: Routines.approvalsFile(in: $0), default: RoutineApprovals()) } ?? RoutineApprovals()
        return Routines.approvalReasons(routine, grant: approvals.grants[routine.name])
    }

    /// The soonest scheduled run after now, shown once nothing else is left today.
    private func nextUp(now: Date) -> (name: String, time: Date)? {
        guard let workspace = store.workspaceURL else { return nil }
        let state = Routines.load(RunnerState.self, from: Routines.stateFile(in: workspace), default: RunnerState())
        let upcoming = store.routineList.compactMap { routine -> (String, Date)? in
            guard routine.problem == nil, routine.enabled, reasons(routine).isEmpty,
                  let next = routine.schedule?.next(after: now, lastRun: state.routines[routine.name]?.lastRun) else { return nil }
            return (routine.name, next)
        }.min { $0.1 < $1.1 }
        guard let upcoming, !Calendar.current.isDate(upcoming.1, inSameDayAs: now) else { return nil }
        return (upcoming.0, upcoming.1)
    }

    private func canRun(_ routine: Routine) -> Bool {
        guard let workspace = store.workspaceURL else { return false }
        return store.runnerEnabled && routine.problem == nil && routine.enabled && reasons(routine).isEmpty && Routines.busy(routine.name, workspace: workspace) == nil
    }

    private func runHelp(_ routine: Routine) -> String {
        if let busy = store.workspaceURL.flatMap({ Routines.busy(routine.name, workspace: $0) }) { return "Already \(busy)" }
        return canRun(routine) ? "Run \(routine.name) now" : "Can't run now: check it in Open routines"
    }

    // MARK: Wording

    static func outcomeText(_ outcome: String) -> String {
        ["ok": "done", "failed": "failed", "timed-out": "timed out", "turn-limit": "hit turn limit", "stopped": "stopped",
         "no-agent": "no agent", "running": "running"][outcome] ?? outcome
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// One routine run: its steps and result when the run record still exists, otherwise what the log recorded.
struct RoutineRunDetail: View {
    @EnvironmentObject var store: DeskStore
    let record: RoutineRunRecord

    var body: some View {
        let live = store.workspaceURL.flatMap { Routines.load(LiveRun?.self, from: LiveRun.file(in: $0, runID: record.runID), default: nil) }
        VStack(alignment: .leading, spacing: 10) {
            if let live {
                RunDetail(run: live)
            } else {
                Text(record.routine).font(.headline)
                Text("Started \(record.started.formatted(date: .abbreviated, time: .shortened)) · run \(String(record.runID.prefix(8)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Outcome").foregroundStyle(.secondary); Text(RoutinesTodayWidget.outcomeText(record.outcome)) }
                GridRow { Text("Started by").foregroundStyle(.secondary); Text(record.manual ? "you (manual run)" : "schedule") }
                if let seconds = record.seconds { GridRow { Text("Took").foregroundStyle(.secondary); Text(RoutineHistory.duration(seconds)) } }
                if let cost = record.cost { GridRow { Text("Cost").foregroundStyle(.secondary); Text(String(format: "≈ $%.2f API-equivalent", cost)) } }
                if !record.items.isEmpty { GridRow { Text("Desk").foregroundStyle(.secondary); Text("\(record.items.count) item\(record.items.count == 1 ? "" : "s") sent") } }
            }.font(.caption)
        }
        .padding(16).frame(width: 440, alignment: .leading)
    }
}

/// Focus mode for Routines: runs over today or the last 7 days, filterable by routine, with totals.
struct RoutinesFocus: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    @State private var days = 1
    @State private var filter = "all"
    @State private var detail: RoutineRunRecord?

    var body: some View {
        let start = Calendar.current.date(byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let runs = store.routineRuns.filter { $0.started >= start && (filter == "all" || $0.routine == filter) }.reversed()
        let finished = runs.filter { $0.outcome != "running" }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("", selection: $days) { Text("Today").tag(1); Text("7 days").tag(7) }.pickerStyle(.segmented).frame(width: 180)
                Picker("Routine", selection: $filter) {
                    Text("All routines").tag("all")
                    ForEach(Array(Set(store.routineRuns.map(\.routine)).union(store.routineList.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 240)
                Spacer()
                Button("Manage routines…") { store.showRoutines = true }
            }
            HStack(spacing: 24) {
                summary("RUNS", "\(runs.count)")
                summary("SUCCEEDED", finished.isEmpty ? "–" : "\(finished.filter(\.succeeded).count) of \(finished.count)")
                summary("TIME", RoutineHistory.duration(finished.compactMap(\.seconds).reduce(0, +)))
                summary("COST", String(format: "≈ $%.2f", finished.compactMap(\.cost).reduce(0, +)))
            }
            Divider().overlay(style.glassStroke)
            if runs.isEmpty {
                Text("No routine runs in this range.").foregroundStyle(style.secondaryText)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                        GridRow {
                            ForEach(["WHEN", "ROUTINE", "STARTED BY", "OUTCOME", "TOOK", "COST", "INBOX"], id: \.self) {
                                Text($0).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(style.secondaryText)
                            }
                        }
                        ForEach(Array(runs)) { run in
                            GridRow {
                                Text(run.started.formatted(days == 1 ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())).monospacedDigit()
                                Text(run.routine).font(.system(size: 13, design: .monospaced))
                                Text(run.manual ? "you" : "schedule").foregroundStyle(style.secondaryText)
                                Text(RoutinesTodayWidget.outcomeText(run.outcome)).foregroundStyle(run.outcome == "running" ? style.accent : run.succeeded ? style.good : style.danger)
                                Text(run.seconds.map(RoutineHistory.duration) ?? "–").monospacedDigit()
                                Text(run.cost.map { String(format: "$%.2f", $0) } ?? "–").monospacedDigit()
                                Button(run.items.isEmpty ? "Steps" : "\(run.items.count) · Steps") { detail = run }.buttonStyle(.plain).foregroundStyle(style.accent)
                            }
                            .font(.system(size: 13))
                        }
                    }
                }
            }
        }
        .padding(22)
        .popover(item: $detail) { record in RoutineRunDetail(record: record).environmentObject(store) }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(style.secondaryText)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
        }
    }
}

// MARK: - Usage and limits

struct TokenUsageWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    let days: Int
    var body: some View {
        let totals = store.usage[days] ?? UsageTotals()
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatTokens(totals.tokens)).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(days == 1 ? "today" : "\(days) days").font(.caption).foregroundStyle(style.secondaryText)
            }
            Text("\(formatTokens(totals.output)) output · the rest is mostly cached context")
                .font(.caption2).foregroundStyle(style.secondaryText).lineLimit(1)
            ForEach(totals.bySource.sorted { $0.value > $1.value }.prefix(3), id: \.key) { source, value in
                HStack(spacing: 6) {
                    Text(source).font(.caption).lineLimit(1)
                    Spacer()
                    Text(totals.tokens > 0 ? "\(Int((Double(value) / Double(totals.tokens) * 100).rounded()))%" : "").font(.caption.monospacedDigit()).foregroundStyle(style.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Text(totals.costSessions > 0 ? String(format: "≈ $%.2f API-equivalent", totals.costUSD) : "Cost estimate starts with new sessions")
                .font(.caption2).foregroundStyle(style.secondaryText)
        }
    }
}

struct PlanLimitsWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    var body: some View {
        if let limits = store.planLimits {
            VStack(alignment: .leading, spacing: 8) {
                if let five = limits.fiveHour { gauge("5-hour", five) }
                if let seven = limits.sevenDay { gauge("7-day", seven) }
                Spacer(minLength: 0)
                Text("As of \(limits.captured.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(style.secondaryText)
            }
        } else {
            Text("Appears after your next Claude conversation or run.").font(.caption).foregroundStyle(style.secondaryText)
        }
    }

    private func gauge(_ title: String, _ window: PlanWindow) -> some View {
        let tint = window.used >= 80 ? style.danger : window.used >= 60 ? style.warning : style.good
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(Int(window.used.rounded()))%").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
            }
            ProgressView(value: min(100, window.used), total: 100).tint(tint)
            Text("Resets \(window.resetsAt.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(style.secondaryText)
        }
    }
}

// MARK: - Shortcuts and capture

struct ShortcutsWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    var onAdd: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
                ForEach(store.cockpitLayout.shortcuts) { shortcut in
                    HStack {
                        Button { store.runShortcut(shortcut) } label: {
                            Label(shortcut.title, systemImage: "play.fill").frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(style.glassFill, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.glassStroke))
                        }.buttonStyle(.plain).help("\(shortcut.skill) with \(store.agent(matching: shortcut.agent)?.name ?? shortcut.agent), in the background")
                        Menu {
                            Button("Remove shortcut", role: .destructive) {
                                store.cockpitLayout.shortcuts.removeAll { $0.id == shortcut.id }; store.saveCockpitLayout()
                            }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }.font(.caption)
                }
                Button(action: onAdd) { Label("Add shortcut", systemImage: "plus") }.buttonStyle(.plain).font(.caption).foregroundStyle(style.accent)
        }
    }
}

struct CaptureWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    let agent: String
    @State private var text = ""
    var body: some View {
        let target = store.agent(matching: agent) ?? store.agents.first
        HStack(spacing: 10) {
            TextField("Tell \(target?.name ?? "an agent")… for example “save this to my vault: …”", text: $text, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...3).font(.system(size: 14))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(style.glassFill, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(style.glassStroke))
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)) }
                .buttonStyle(.plain).foregroundStyle(style.accent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target == nil)
        }
    }

    private func send() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, let target = store.agent(matching: agent) ?? store.agents.first else { return }
        let title = request.count > 40 ? String(request.prefix(40)) + "…" : request
        store.startManualRun(ManualRun(kind: "capture", title: title, agent: URL(fileURLWithPath: target.path).lastPathComponent, request: request))
        text = ""
    }
}

// MARK: - Agents and vault

struct AgentsWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    var body: some View {
        let state = store.workspaceURL.map { Routines.load(RunnerState.self, from: Routines.stateFile(in: $0), default: RunnerState()) } ?? RunnerState()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.agents) { agent in
                let skills = store.librarySkills.filter { store.attachment(of: $0, to: .agent(agent)) == .attached }.count
                let heartbeat = store.routineList.first { $0.skill == "heartbeat" && store.agent(matching: $0.agent)?.id == agent.id }
                    .flatMap { state.routines[$0.name] }
                HStack(spacing: 8) {
                    ClaudeMascot(color: style.accent).frame(width: 20, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name).font(.system(size: 13, weight: .medium))
                        Text("\(skills) skills" + (heartbeat?.lastRun.map { " · heartbeat \($0.formatted(.relative(presentation: .named))) (\(heartbeat?.lastOutcome ?? ""))" } ?? ""))
                            .font(.caption).foregroundStyle(style.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    Button("Talk") { store.openInStudio(); store.launchAgent(agent) }.buttonStyle(.plain).font(.caption).foregroundStyle(style.accent)
                }
            }
        }
    }
}

struct VaultHealthWidget: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.cockpitStyle) private var style
    var body: some View {
        let nodes = store.vaultGraph.nodes
        let fresh = nodes.filter { Calendar.current.isDateInToday($0.modified) }.count
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(nodes.filter { $0.kind == .note }.count)").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("notes · \(nodes.filter { $0.kind == .map }.count) maps").font(.caption).foregroundStyle(style.secondaryText)
            }
            Text("\(fresh) changed today").font(.caption)
            Spacer(minLength: 0)
            Text(store.vaultCheck.isEmpty ? "Checking…" : "Checker: \(store.vaultCheck)").font(.caption2)
                .foregroundStyle(store.vaultCheck.hasPrefix("OK") ? style.good : style.warning).lineLimit(2)
        }
    }
}

// MARK: - Settings and shortcut editor

struct WidgetSettingsView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    let config: WidgetConfig
    @State private var settings: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(config.kind.title) settings").font(.title3.bold())
            Form {
                switch config.kind {
                case .tokens:
                    Picker("Range", selection: binding("days", default: "1")) { Text("Today").tag("1"); Text("7 days").tag("7"); Text("30 days").tag("30") }
                case .capture:
                    Picker("Agent", selection: binding("agent", default: "atlas")) {
                        ForEach(store.agents) { Text($0.name).tag(URL(fileURLWithPath: $0.path).lastPathComponent) }
                        Text("atlas").tag("atlas")
                    }
                case .inbox: Stepper("Show \(binding("count", default: "4").wrappedValue) items", value: Binding(
                    get: { Int(settings["count"] ?? "4") ?? 4 }, set: { settings["count"] = String($0) }), in: 1...12)
                default: Text("No settings.")
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let index = store.cockpitLayout.widgets.firstIndex(where: { $0.id == config.id }) {
                        store.cockpitLayout.widgets[index].settings = settings
                        store.saveCockpitLayout()
                    }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 420).onAppear { settings = config.settings }
    }

    private func binding(_ key: String, default value: String) -> Binding<String> {
        Binding(get: { settings[key] ?? value }, set: { settings[key] = $0 })
    }
}

struct ShortcutEditor: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @State private var shortcut = SkillShortcut(title: "", skill: "", agent: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add skill shortcut").font(.title3.bold())
            Text("Runs the skill with the agent in the background, with the same restrictions as routines.").font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Skill", selection: $shortcut.skill) {
                    Text("Choose…").tag("")
                    ForEach(store.librarySkills) { Text($0.name).tag($0.name) }
                }
                Picker("Agent", selection: $shortcut.agent) {
                    Text("Choose…").tag("")
                    ForEach(store.agents) { Text($0.name).tag(URL(fileURLWithPath: $0.path).lastPathComponent) }
                }
                TextField("Button label", text: $shortcut.title, prompt: Text(shortcut.skill.isEmpty ? "Heartbeat" : shortcut.skill))
                TextField("Extra instruction (optional)", text: $shortcut.instruction, axis: .vertical).lineLimit(2...4)
                Toggle("Allow opening web pages (web-fetch)", isOn: $shortcut.webFetch)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add shortcut") {
                    if shortcut.title.trimmingCharacters(in: .whitespaces).isEmpty { shortcut.title = shortcut.skill }
                    store.cockpitLayout.shortcuts.append(shortcut)
                    store.saveCockpitLayout()
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(shortcut.skill.isEmpty || shortcut.agent.isEmpty)
            }
        }.padding(22).frame(width: 480)
    }
}
