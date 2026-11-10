import AppKit
import SwiftUI

@MainActor
final class DeskStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published var launching = false
    @Published var notice: String?
    @Published var terminals: [RunningTerminal] = []
    @Published var showTerminals = false
    @Published var projectLayout: PaneTree?
    @Published var agentLayout: PaneTree?
    @Published var activeTerminalID: UUID?
    @Published var mode: WorkspaceMode = .projects
    @Published var agents: [AgentProfile] = []
    @Published var selectedAgentID: UUID?
    @Published var workspacePath = UserDefaults.standard.string(forKey: "workspacePath") ?? ""
    /// The agent folder chosen before workspaces existed; used until the user migrates.
    @Published var legacyAgentHostPath = UserDefaults.standard.string(forKey: "agentHostPath") ?? ""
    /// A suggested workspace for an older setup, shown once as a migration prompt.
    @Published var workspaceMigration: String?
    var agentHostPath: String {
        workspacePath.isEmpty ? legacyAgentHostPath : Workspace.agents(in: URL(fileURLWithPath: workspacePath)).path
    }
    @Published var showInbox = false
    @Published var inboxItems: [InboxItem] = []
    @Published var librarySkills: [LibrarySkill] = []
    @Published var selectedSkillName: String?
    /// Bumped whenever skill links may have changed, so attachment checkboxes re-read the disk.
    @Published var skillRevision = 0
    @Published var routineList: [Routine] = []
    @Published var showRoutines = false
    @Published var runnerEnabled = false
    @Published var cockpitLayout = CockpitLayout.standard
    @Published var vaultGraph = VaultGraph()
    /// Vault notes that changed recently, with when; the constellations pulse them.
    @Published var vaultPulses: [String: Date] = [:]
    /// Notes agents just read or searched, by vault-relative path, for the Cockpit's light flare.
    @Published var vaultReads: [String: VaultRead] = [:]
    let vaultTail = VaultActivity.Tail()
    // Google mail and calendar (read-only), triaged by Jev
    @Published var googleAccounts: [String] = UserDefaults.standard.stringArray(forKey: "googleAccounts") ?? []
    @Published var mailMessages: [MailMessage] = []
    @Published var calendarEvents: [CalendarEvent] = []
    @Published var mailStatus = ""
    @Published var mailRefreshing = false
    /// Where mail and calendar come from: "mac" (Apple Mail and macOS calendars, the default) or "google" (Google API).
    @Published var mailSource: String = UserDefaults.standard.string(forKey: "mailSource") ?? "mac" {
        didSet { UserDefaults.standard.set(mailSource, forKey: "mailSource") }
    }
    /// Set once you allow access to this Mac's mail and calendars in Settings.
    @Published var macMailConnected = UserDefaults.standard.bool(forKey: "macMailConnected") {
        didSet { UserDefaults.standard.set(macMailConnected, forKey: "macMailConnected") }
    }
    var mailLoaded = false
    @Published var liveRuns: [LiveRun] = []
    /// Widgets agents wrote in their own `widgets/` folders.
    @Published var agentWidgets: [AgentWidget] = []
    var agentWidgetSignature = ""
    /// Routine runs from the last 7 days, rebuilt from the activity log when it changes.
    @Published var routineRuns: [RoutineRunRecord] = []
    var routineRunSignature = ""
    @Published var planLimits: PlanLimits?
    @Published var usage: [Int: UsageTotals] = [:]     // keyed by days: 1, 7, 30
    @Published var vaultCheck = ""
    let usageScanner = UsageScanner()
    var cockpitTimers: [Timer] = []
    var folderWatchers: [DispatchSourceFileSystemObject] = []
    var activityObserver: NSObjectProtocol?
    var canSaveAgents = true
    var workspaceTerminals: [RunningTerminal] {
        terminals.filter { mode == .agents ? $0.project.agentID != nil : $0.project.agentID == nil }
    }
    private var canSave = true
    private let file: URL

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeDesk/projects.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                projects = try JSONDecoder().decode([Project].self, from: Data(contentsOf: file))
            } catch {
                canSave = false
                self.error = "Could not read saved projects. Your original file has been preserved at \(file.path). \(error.localizedDescription)"
            }
        }
        selectedID = projects.first?.id
        loadAgents()
        if workspacePath.isEmpty, !legacyAgentHostPath.isEmpty, !UserDefaults.standard.bool(forKey: "workspaceMigrationDeclined") {
            workspaceMigration = Workspace.migrationSuggestion(forAgentHost: legacyAgentHostPath)
        }
        startWorkspaceServices()
    }

    func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(projects).write(to: file, options: .atomic)
        } catch { self.error = "Could not save projects: \(error.localizedDescription)" }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add project"
        panel.message = "Choose the folder where Claude should work."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let existing = projects.first(where: { $0.path == url.path }) {
            selectedID = existing.id
            return
        }
        let project = Project(name: url.lastPathComponent, path: url.path)
        projects.append(project)
        selectedID = project.id
        save()
    }

    func update(_ session: DeskSession, in projectID: UUID) {
        guard let p = projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let s = projects[p].sessions.firstIndex(where: { $0.id == session.id }) {
            projects[p].sessions[s] = session
        } else { projects[p].sessions.append(session) }
        save()
    }

    func removeSession(_ sessionID: UUID, from projectID: UUID) {
        guard let p = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[p].sessions.removeAll { $0.id == sessionID }
        save()
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        selectedID = projects.first?.id
        save()
    }

    func launch(_ sessions: [DeskSession], in project: Project, executableOverride: String) async {
        guard !launching, !sessions.isEmpty else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "The project folder no longer exists: \(project.path)"
            return
        }
        guard let executable = resolveExecutable(executableOverride) else { return }
        for session in sessions {
            let sessionID = UUID().uuidString.lowercased()
            let terminal = RunningTerminal(project: project, session: session, sessionID: sessionID)
            terminals.append(terminal)
            terminal.start(executable: executable, arguments: ["--session-id", sessionID] + (session.prompt.isEmpty ? [] : ["--", session.prompt]))
            track(terminal, details: ["project": project.path, "shortcut": session.name, "session": sessionID])
            var updated = session
            updated.lastOpened = Date()
            update(updated, in: project.id)
        }
        showTerminals = true
    }

    func resolveExecutable(_ executableOverride: String) -> String? {
        let candidates = executableOverride.isEmpty ? [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude"
        ] : [NSString(string: executableOverride).expandingTildeInPath]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "Claude CLI was not found. Install Claude Code, or set its executable path in Settings (⌘,)."
            return nil
        }
        return executable
    }

    func closeTerminal(_ terminal: RunningTerminal) {
        if terminal.running {
            terminal.onExit = nil
            log("conversation.ended", subject: terminal.session.name, outcome: "stopped", details: ["pane": terminal.id.uuidString])
        }
        terminal.stop()
        terminals.removeAll { $0.id == terminal.id }
        if terminals.isEmpty { showTerminals = false }
    }

    func moveTerminal(_ id: UUID, to destination: UUID) {
        guard let from = terminals.firstIndex(where: { $0.id == id }),
              let to = terminals.firstIndex(where: { $0.id == destination }), from != to else { return }
        let item = terminals.remove(at: from)
        terminals.insert(item, at: to)
    }
}
