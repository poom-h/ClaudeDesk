import AppKit
import SwiftUI
import SwiftTerm



@MainActor
final class RunningTerminal: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    private static var nextColor = 0
    let colorIndex: Int
    let id = UUID()
    let started = Date()
    let project: Project
    let session: DeskSession
    let view: LocalProcessTerminalView
    @Published var status = "Starting"
    @Published var running = false
    /// Called once when the process exits on its own, with its exit status.
    var onExit: ((String) -> Void)?
    private var stopped = false

    /// Claude's own conversation ID, when known: assigned at launch or taken from --resume <id>.
    let sessionID: String?
    /// A short label for tabs: the start of Claude's session ID, or the pane's own ID when it isn't known.
    var shortLabel: String { sessionID.map { String($0.prefix(8)) } ?? String(id.uuidString.prefix(4)).lowercased() }

    init(project: Project, session: DeskSession, sessionID: String? = nil) {
        self.sessionID = sessionID
        colorIndex = Self.nextColor
        Self.nextColor += 1
        self.project = project
        self.session = session
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.075, green: 0.085, blue: 0.10, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 1)
    }

    func start(executable: String, arguments: [String]? = nil, environmentOverrides: [String: String] = [:]) {
        var environment = AgentEnvironment.withoutInheritedClaudeVariables(ProcessInfo.processInfo.environment)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "ClaudeDesk"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment.merge(environmentOverrides) { _, custom in custom }
        // A login shell loads the user's normal CLI environment. exec keeps one
        // process identity for Claude and preserves normal interactive signals.
        let args = arguments ?? (session.prompt.isEmpty ? [] : ["--", session.prompt])
        // Reapply agent environment after login-shell initialization so shell
        // dotfiles cannot redirect agent state into the user's normal profile.
        let assignments = environmentOverrides.sorted { $0.key < $1.key }.map { LaunchCommand.shellQuote("\($0.key)=\($0.value)") }
        let command = "cd -- " + LaunchCommand.shellQuote(project.path) + " && exec /usr/bin/env " + (assignments + [LaunchCommand.shellQuote(executable)] + args.map(LaunchCommand.shellQuote)).joined(separator: " ")
        view.startProcess(executable: "/bin/zsh", args: ["-lc", command],
                          environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: project.path)
        running = view.process.running
        status = running ? "Running" : "Failed to start"
    }

    func attachFiles() {
        guard running else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Insert file references"
        panel.message = "Adds paths to the current draft. Review the message before sending it to Claude."
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { url -> String in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try! encoder.encode(url.path)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: " ")
        view.pasteText(" " + paths + " ")
        view.window?.makeFirstResponder(view)
    }

    func stop() {
        guard running, !stopped else { return }
        stopped = true
        // The PTY child leads its own process group. Include helper processes.
        let pid = view.process.shellPid
        if pid > 0 { kill(-pid, SIGHUP) }
        view.terminate()
        if pid > 0 {
            // terminate() cancels SwiftTerm's exit monitor, so reap the child
            // here and bound shutdown for programs that ignore SIGTERM.
            DispatchQueue.global(qos: .utility).async {
                for _ in 0..<100 {
                    let result = waitpid(pid, nil, WNOHANG)
                    if result == pid || (result == -1 && errno == ECHILD) { return }
                    usleep(20_000)
                }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
            }
        }
        running = false
        status = "Stopped"
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        running = false
        if !stopped {
            if let code = exitCode {
                status = code == 0 ? "Finished" : "Exited (\(code >> 8))"
            } else { status = "Ended" }
            onExit?(status)
            onExit = nil
        }
    }
}

struct TerminalSurface: NSViewRepresentable {
    @Environment(\.deskTheme) var theme
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    let terminal: RunningTerminal
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = terminal.view
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        let view = terminal.view
        if !view.nativeBackgroundColor.isEqual(theme.background) { view.nativeBackgroundColor = theme.background }
        if !view.nativeForegroundColor.isEqual(theme.foreground) { view.nativeForegroundColor = theme.foreground }
        if !view.caretColor.isEqual(theme.foreground) { view.caretColor = theme.foreground }
        if view.font.pointSize != max(6, min(32, fontSize)) { view.font = .monospacedSystemFont(ofSize: max(6, min(32, fontSize)), weight: .regular) }
    }
}

final class AppLifecycle: NSObject, NSApplicationDelegate {
    static weak var store: DeskStore?
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One main window only: no window tabs, so the "+" tab button can't open a second copy.
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    /// Quits without asking: conversations are saved as they go, so Continue or History brings them back.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store else { return .terminateNow }
        let active = store.terminals.filter(\.running)
        for terminal in active {
            store.log("conversation.ended", actor: "app", subject: terminal.session.name, outcome: "app quit",
                      details: ["pane": terminal.id.uuidString, "session": terminal.sessionID ?? ""])
            terminal.onExit = nil
            terminal.stop()
        }
        return .terminateNow
    }
}
