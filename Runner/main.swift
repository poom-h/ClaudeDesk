import Foundation

// claudedesk-runner
//   (no mode)            one pass over the workspace's routines; launchd runs this every 5 minutes
//                        while "Run routines in the background" is switched on in ClaudeDesk Settings
//   --run-request FILE   run one Cockpit shortcut or quick capture now, then delete FILE
//   --statusline         Claude Code status line: record plan limits and session cost, print a short line
// Inside ClaudeDesk.app the runner shares the app's bundle ID, so its standard defaults are the app's settings.
let preferences = Bundle.main.bundleIdentifier == "local.claudedesk.app" ? UserDefaults.standard : UserDefaults(suiteName: "local.claudedesk.app")
var workspacePath = preferences?.string(forKey: "workspacePath") ?? ""
let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
if let path = value(after: "--workspace") { workspacePath = path }
guard !workspacePath.isEmpty, FileManager.default.fileExists(atPath: workspacePath) else {
    if !arguments.contains("--statusline") { FileHandle.standardError.write(Data("claudedesk-runner: no workspace folder is set.\n".utf8)) }
    exit(0)
}
let workspace = URL(fileURLWithPath: workspacePath)

if arguments.contains("--statusline") {
    print(StatusLine.handle(input: FileHandle.standardInput.readDataToEndOfFile(), workspace: workspace))
    exit(0)
}

guard let claude = RoutineRunner.findClaude(override: preferences?.string(forKey: "claudeExecutable")) else {
    FileHandle.standardError.write(Data("claudedesk-runner: Claude CLI not found.\n".utf8))
    exit(1)
}
let runner = RoutineRunner(workspace: workspace, agents: RoutineRunner.loadAgents(), executable: claude)

if let file = value(after: "--run-request") {
    let url = URL(fileURLWithPath: file)
    guard let manual = Routines.load(ManualRun?.self, from: url, default: nil) else {
        FileHandle.standardError.write(Data("claudedesk-runner: unreadable run request \(file)\n".utf8))
        exit(1)
    }
    try? FileManager.default.removeItem(at: url)
    _ = runner.run(manual)
    exit(0)
}

runner.pass()
