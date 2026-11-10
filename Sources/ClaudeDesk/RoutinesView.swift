import SwiftUI
import AppKit

/// Lists routines from routines.md with their approval and run status. The files stay the source of truth.
struct RoutinesView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    private var workspace: URL? { store.workspaceURL }
    private var approvals: RoutineApprovals {
        workspace.map { Routines.load(RoutineApprovals.self, from: Routines.approvalsFile(in: $0), default: RoutineApprovals()) } ?? RoutineApprovals()
    }
    private var state: RunnerState {
        workspace.map { Routines.load(RunnerState.self, from: Routines.stateFile(in: $0), default: RunnerState()) } ?? RunnerState()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Routines").font(.title2.bold())
                Spacer()
                Button("Edit routines.md") { editing = true }.disabled(workspace == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Toggle(isOn: Binding(get: { store.runnerEnabled }, set: { store.setRunner(enabled: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run routines in the background").font(.headline)
                    Text("Checks every 5 minutes while your Mac is awake, even with ClaudeDesk closed. Missed times run once after waking.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).disabled(workspace == nil)
            statusLine
            Divider()
            if store.routineList.isEmpty {
                ContentUnavailableView("No routines yet", systemImage: "clock",
                                       description: Text("Add a ## section to routines.md, or ask an agent to set one up for you."))
            } else {
                ScrollView {
                    VStack(spacing: 10) { ForEach(store.routineList) { row($0) } }
                }
            }
        }
        .padding(24).frame(width: 720, height: 560)
        .onAppear { store.refreshRoutines() }
        .sheet(isPresented: $editing) {
            if let workspace { RoutinesFileEditor(url: Routines.file(in: workspace)).environmentObject(store) }
        }
    }

    private var statusLine: some View {
        let state = self.state
        return HStack(spacing: 14) {
            Text(state.lastPass.map { "Last check \($0.formatted(.relative(presentation: .named)))" } ?? "The runner hasn't run yet")
            Text("Runs today: \(state.day == todayKey ? state.runsToday : 0) of \(Routines.maxRunsPerDay)")
            Spacer()
            if let workspace {
                Button("Runner log") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Routines.runnerFolder(in: workspace).path)
                }.buttonStyle(.borderless)
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var todayKey: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func row(_ routine: Routine) -> some View {
        let grant = approvals.grants[routine.name]
        let reasons = routine.problem == nil ? Routines.approvalReasons(routine, grant: grant) : []
        let runState = state.routines[routine.name]
        let status: (String, Color) = {
            if routine.problem != nil { return ("Needs fixing", .orange) }
            if !routine.enabled { return ("Switched off", .secondary) }
            if !reasons.isEmpty { return (approvals.rejected[routine.name] == routine.fingerprint ? "Rejected" : "Waiting for approval", .orange) }
            return ("Approved", .green)
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(routine.name).font(.system(.headline, design: .monospaced))
                Text(status.0).font(.caption.weight(.semibold)).foregroundStyle(status.1)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(status.1.opacity(0.12), in: Capsule())
                Spacer()
                RoutineRunButton(routine: routine, canRun: routine.problem == nil && reasons.isEmpty && routine.enabled && store.runnerEnabled)
            }
            HStack(spacing: 14) {
                Label(store.agent(matching: routine.agent)?.name ?? routine.agent, systemImage: "person.crop.square")
                Label(routine.scheduleText, systemImage: "calendar")
                if let next = routine.schedule?.next(after: Date(), lastRun: runState?.lastRun), reasons.isEmpty, routine.enabled {
                    Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                }
                if let last = runState?.lastRun {
                    Text("Last: \(last.formatted(.relative(presentation: .named))) · \(runState?.lastOutcome ?? "")")
                }
            }.font(.caption).foregroundStyle(.secondary)
            RoutineRunStatus(routine: routine)
            if let problem = routine.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            if !reasons.isEmpty && routine.problem == nil {
                Text("Needs approval on your Desk: \(reasons.joined(separator: "; ")).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Run now, showing Queued and Running… straight from the queue and live-run files, so a click always visibly lands.
private struct RoutineRunButton: View {
    @EnvironmentObject var store: DeskStore
    let routine: Routine
    let canRun: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let busy = store.workspaceURL.flatMap { Routines.busy(routine.name, workspace: $0) }
            Button { store.runNow(routine) } label: {
                HStack(spacing: 6) {
                    if busy != nil { ProgressView().controlSize(.small) }
                    Text(busy == "running" ? "Running…" : busy == "queued" ? "Starting…" : "Run now")
                }
            }
            .disabled(busy != nil || !canRun)
            .help(busy != nil ? "Already \(busy!); it won't run twice" : store.runnerEnabled ? "Runs it once now" : "Switch on background routines first")
        }
    }
}

/// The routine's current or latest run: queued, running with its latest step and Stop, or the finished result.
private struct RoutineRunStatus: View {
    @EnvironmentObject var store: DeskStore
    let routine: Routine
    @State private var detail: LiveRun?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            if let workspace = store.workspaceURL {
                let busy = Routines.busy(routine.name, workspace: workspace, now: context.date)
                let run = LiveRun.load(in: workspace, now: context.date, recent: 900)
                    .first { $0.kind == "routine" && $0.title == routine.name }
                if busy == "queued" && run?.status != "running" {
                    // The runner does one pass at a time, so a queued routine waits for any routine already running.
                    let ahead = LiveRun.load(in: workspace, now: context.date).first { $0.kind == "routine" && $0.status == "running" && $0.title != routine.name }
                    Label(ahead.map { "Queued. It starts after \($0.title) finishes." } ?? "Queued. Starting in a few seconds…", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.blue)
                } else if let run {
                    line(run, now: context.date)
                }
            }
        }
        .popover(item: $detail) { run in RunDetail(run: run).environmentObject(store).padding(16).frame(width: 440) }
    }

    @ViewBuilder private func line(_ run: LiveRun, now: Date) -> some View {
        let seconds = Int((run.finished ?? now).timeIntervalSince(run.started))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        HStack(spacing: 8) {
            if run.status == "running" {
                ProgressView().controlSize(.mini)
                Text("Running · \(elapsed)\(run.steps.last.map { " · " + $0 } ?? "")").lineLimit(1)
                Spacer(minLength: 4)
                Button("Stop", role: .destructive) { store.stopRun(run) }.buttonStyle(.borderless)
            } else {
                let ok = run.status == "ok" || run.status == "stopped"
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
                Text("\(run.status == "ok" ? "Finished" : run.status.capitalized) \(run.finished.map { $0.formatted(.relative(presentation: .named)) } ?? "") · took \(elapsed)\(run.result.isEmpty ? "" : " · " + run.result.replacingOccurrences(of: "\n", with: " "))")
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            Button("Show steps") { detail = run }.buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((run.status == "running" ? Color.blue : run.status == "ok" ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Edits routines.md with the same stale-write protection as the other editors.
struct RoutinesFileEditor: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var text = ""
    @State private var original = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("routines.md").font(.title3.bold())
            Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).border(.secondary.opacity(0.3))
            let parsed = Routines.parse(text)
            Text(parsed.isEmpty ? "No routines in this draft." : parsed.map { "\($0.name): \($0.problem ?? "OK")" }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(parsed.contains { $0.problem != nil } ? .orange : .secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    guard current == original else { problem = "routines.md changed outside the editor. Copy your draft, close, and reopen."; return }
                    do {
                        try text.write(to: url, atomically: true, encoding: .utf8)
                        store.log("routines.edited", subject: url.lastPathComponent)
                        store.refreshRoutines()
                        dismiss()
                    } catch { problem = error.localizedDescription }
                }.keyboardShortcut("s").disabled(text == original)
            }
        }.padding(22).frame(width: 720, height: 560)
        .onAppear {
            original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text = original
        }
    }
}
