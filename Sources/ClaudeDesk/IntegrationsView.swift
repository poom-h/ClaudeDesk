import SwiftUI

struct IntegrationsView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    var initialTarget = "global"
    @State private var target = "global"
    @State private var plugin = ""
    @State private var marketplace = ""
    @State private var server = ""
    @State private var config = "{\n  \"type\": \"http\",\n  \"url\": \"https://example.com/mcp\"\n}"
    @State private var error: String?
    private var agent: AgentProfile? { store.agents.first { $0.id.uuidString == target } }
    private var project: Project? { store.projects.first { $0.id.uuidString == target } }
    private var scope: String { target == "global" ? "user" : "local" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Plugins & MCP").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Picker("Install into", selection: $target) {
                Text("Global · normal Claude profile").tag("global")
                ForEach(store.projects) { Text("Project · " + $0.name).tag($0.id.uuidString) }
                ForEach(store.agents) { Text("Agent · " + $0.name).tag($0.id.uuidString) }
            }
            Text(target == "global" ? "Available across normal project sessions. Agents have private profiles; select an agent to configure it separately." : "Only this project or agent. Local settings stay out of shared project configuration.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Plugins").font(.headline)
            HStack {
                TextField("plugin@marketplace", text: $plugin)
                Button("Install") { run(["plugin", "install", "--scope", scope, "--", plugin]) }.disabled(plugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("List") { run(["plugin", "list"]) }
            }
            HStack {
                TextField("Marketplace URL, path, or owner/repo", text: $marketplace)
                Button("Add marketplace") { run(["plugin", "marketplace", "add", "--scope", scope, "--", marketplace]) }.disabled(marketplace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            HStack {
                Text("MCP servers").font(.headline)
                Spacer()
                Button("List servers") { run(["mcp", "list"]) }
            }
            TextField("Server name", text: $server)
            Text("Paste one server configuration (HTTP, SSE, or stdio).").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $config).font(.system(size: 12, design: .monospaced)).frame(height: 150)
                .border(.secondary.opacity(0.3))
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text("Commands open in a terminal. Restart conversations to load changes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add MCP server") {
                    do {
                        guard let data = config.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              object["command"] is String || object["url"] is String else {
                            error = "Provide a JSON object with a command or URL."; return
                        }
                        run(["mcp", "add-json", "--scope", scope, "--", server, config])
                    } catch { self.error = error.localizedDescription }
                }.disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 650)
            .onAppear { target = initialTarget }
    }
    private func run(_ arguments: [String]) {
        guard target == "global" || agent != nil || project != nil else { error = "Select an available environment."; return }
        guard let executable = store.resolveExecutable(UserDefaults.standard.string(forKey: "claudeExecutable") ?? "") else {
            error = store.error; return
        }
        let destination = agent?.project ?? project ?? Project(name: "Global configuration", path: NSHomeDirectory())
        let terminal = RunningTerminal(project: destination, session: DeskSession(name: arguments.prefix(2).joined(separator: " ")))
        store.mode = agent == nil ? .projects : .agents
        store.terminals.append(terminal)
        terminal.start(executable: executable, arguments: arguments, environmentOverrides: agent.map { AgentEnvironment.environment(for: $0) } ?? [:])
        dismiss()
        DispatchQueue.main.async { store.showTerminals = true }
    }
}
