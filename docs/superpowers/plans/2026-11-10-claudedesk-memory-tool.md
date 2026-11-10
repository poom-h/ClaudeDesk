# ClaudeDesk × atrium-memory Implementation Plan (Plan 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every ClaudeDesk agent use the bundled `atrium-memory` MCP server for the Memory Vault (approved for background runs, with direct vault edits blocked) and make the Cockpit's memory flare follow the tool's audit log.

**Architecture:** One new Swift file, `MemoryTool.swift`, holds every rule for connecting an agent: the `.mcp.json` server entry, the settings that approve the server and block direct edits, and the `CLAUDE.md` section. The app runs it at launch, next to the existing Inbox and widget connections. The routine runner grants the tools to connected agents. `VaultActivity` learns to read the audit log. `build-app.sh` builds and bundles a universal `atrium-memory` binary from a pinned version.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode (SwiftUI, macOS 14+). Plain `swiftc` test executables in `scripts/*-check.swift`, run by `scripts/test-*.sh`. Go (already installed) only to build the bundled binary.

**Spec:** `docs/superpowers/specs/2026-11-07-brainvault-design.md`, section "ClaudeDesk integration" (revised 2026-11-10).
**Plan 1 (done):** the tool itself, in `/Users/poomhirunwiwatkul/Documents/Code/BrainHub/brainvault` (GitHub `poom-h/atrium-memory`).

## Global Constraints

- Server name, binary name and `.mcp.json` key: `atrium-memory`. Bundled path: `Contents/MacOS/atrium-memory`.
- `.mcp.json` entry: `"command"` set to the bundled binary path, `"args": ["mcp"]`, `"env": {"ATRIUM_MEMORY_PATH": "<workspace>/MemoryVault", "ATRIUM_MEMORY_ACTOR": "<agent name>"}`.
- An entry counts as written by the app only when `args == ["mcp"]` and the command ends in `/atrium-memory`. Only such an entry, with a command that no longer exists, may be repaired. Any other entry, and every other server, is never changed.
- Settings added once per agent to `.claude/settings.local.json`: `"atrium-memory"` in `enabledMcpjsonServers`, `"mcp__atrium-memory"` in `permissions.allow`, and `"Edit(/<vault path>/**)"` in `permissions.deny`. The vault path starts with `/`, so the rule begins `Edit(//`.
- `CLAUDE.md` section marker: `<!-- claudedesk:memory-tool -->`, appended once.
- The once-per-agent UserDefaults key is `workspaceConnectedAgents.memory.v1`. The server entry is checked on every launch.
- The audit log is at `<vault>/.atrium-memory/audit.jsonl`. Only `vault_read` (field `id`) and `vault_search` (field `results`) with `outcome == "ok"` light notes. The `actor` field is the label.
- The pinned tool version is in `Resources/atrium-memory.version`, initially `0.1.0`. The development build comes from `ATRIUM_MEMORY_SRC` (default `../brainvault`), with version `<pinned>-dev`.
- Files the user wrote are never rewritten wholesale: JSON files are changed by adding keys only, and a file that isn't a JSON object is reported, not replaced.
- ClaudeDesk is a local git repository created in Task 1, with no remote. Don't push anywhere.
- Every commit message ends with the Co-Authored-By attribution line your own harness gives you.

## Preconditions

- PR `poom-h/atrium-memory#1` (the rename) is merged, and `../brainvault` is on `main` with `cmd/atrium-memory/` present. Check with `ls ../brainvault/cmd/atrium-memory/main.go`. If it's missing, stop and report it.

## File Structure

```
Sources/ClaudeDesk/MemoryTool.swift      NEW  connect an agent: server entry, settings, instructions; project config
Sources/ClaudeDesk/RoutineRunner.swift   MOD  arguments(... vault:) grants mcp__atrium-memory, blocks vault edits
Sources/ClaudeDesk/VaultActivity.swift   MOD  auditReads(in:) and auditLog(in:)
Sources/ClaudeDesk/CockpitStore.swift    MOD  refreshVaultReads() also follows the audit log
Sources/ClaudeDesk/InboxStore.swift      MOD  connectAgentsToInbox() also connects atrium-memory
Sources/ClaudeDesk/App.swift             MOD  Settings › General: "Copy MCP config"
Resources/atrium-memory.version          NEW  pinned tool version
Resources/VaultTemplate/Notes/Second-Brain-Framework.md  MOD  retrieval and capture use the vault_* tools
scripts/memory-tool-check.swift          NEW  checks for everything above
scripts/test-memory-tool.sh              NEW  compiles and runs the checks
scripts/build-app.sh                     MOD  builds, bundles and signs atrium-memory; adds MemoryTool.swift to the runner
scripts/test-{agents,routines,cockpit,skills,agent-runtime}.sh  MOD  compile MemoryTool.swift
README.md, docs/design/cockpit.md        MOD  version notes
.gitignore                               MOD  ignore build output
```

---

### Task 1: Put ClaudeDesk under version control

**Files:**
- Modify: `.gitignore`

**Interfaces:**
- Produces: a git repo on branch `main` with one baseline commit, so later tasks can be reviewed as diffs.

- [ ] **Step 1: Check the baseline tests pass before changing anything**

```bash
cd /Users/poomhirunwiwatkul/Documents/Code/BrainHub/ManageMyClaude
for t in test test-agents test-routines test-cockpit test-skills test-agent-runtime; do bash scripts/$t.sh || echo "FAILED: $t"; done
```

Expected: each script prints its `Passed: …` line, and nothing prints `FAILED`. If any fails, stop and report it. Don't fix it as part of this plan.

- [ ] **Step 2: Write `.gitignore`**

Replace the file's contents with:

```
.DS_Store
/.build/
/dist/
```

- [ ] **Step 3: Create the repository and the baseline commit**

```bash
git init -b main
git add -A
git status --short | grep -E '\.build/|dist/' && echo "BUILD OUTPUT STAGED - stop" || echo "clean"
git commit -q -m "chore: baseline before the atrium-memory integration" -m "<your harness Co-Authored-By line>"
git log --oneline
```

Expected: `clean`, then one commit.

---

### Task 2: Add and repair the server entry in each agent's `.mcp.json`

**Files:**
- Create: `Sources/ClaudeDesk/MemoryTool.swift`, `scripts/memory-tool-check.swift`, `scripts/test-memory-tool.sh`
- Modify: `scripts/build-app.sh` (the RUNNER_SOURCES line), `scripts/test-agents.sh`, `scripts/test-routines.sh`, `scripts/test-cockpit.sh`, `scripts/test-skills.sh`, `scripts/test-agent-runtime.sh`

**Interfaces:**
- Consumes: `AgentProfile` (`name`, `path`), `AgentEnvironment.create(name:purpose:host:)` and `AgentEnvironment.Failure(message:)` from `AgentEnvironment.swift`.
- Produces:
  - `enum MemoryTool` with `static let serverName = "atrium-memory"`, `static let toolPermission = "mcp__atrium-memory"` and `static let instructionsMarker = "<!-- claudedesk:memory-tool -->"`.
  - `static var bundledExecutable: URL?`.
  - `static func vaultEditRule(_ vault: URL) -> String`.
  - `static func serverEntry(executable: String, vault: URL, actor: String) -> [String: Any]`.
  - `enum Change: Equatable { case added, repaired, unchanged }`.
  - `static func connectServer(_ agent: AgentProfile, executable: String, vault: URL) throws -> Change`.
  - `static func isAppWritten(_ entry: [String: Any]) -> Bool` and `static func isConnected(_ agent: AgentProfile) -> Bool`.

- [ ] **Step 1: Write the test script and the failing check**

`scripts/test-memory-tool.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/compiler-env.sh
swiftc -parse-as-library "${COMPILER_FLAGS[@]}" Sources/ClaudeDesk/Models.swift Sources/ClaudeDesk/AgentEnvironment.swift Sources/ClaudeDesk/MemoryTool.swift \
    Sources/ClaudeDesk/Workspace.swift Sources/ClaudeDesk/Frontmatter.swift Sources/ClaudeDesk/ActivityLog.swift Sources/ClaudeDesk/SkillLibrary.swift \
    Sources/ClaudeDesk/Inbox.swift Sources/ClaudeDesk/RunSteps.swift Sources/ClaudeDesk/CockpitData.swift Sources/ClaudeDesk/Routines.swift \
    Sources/ClaudeDesk/RoutineRunner.swift Sources/ClaudeDesk/VaultActivity.swift scripts/memory-tool-check.swift -o .build/memory-tool-checks
.build/memory-tool-checks
```

`scripts/memory-tool-check.swift`:

```swift
import Foundation

@main
struct MemoryToolChecks {
    static func main() throws {
        let host = FileManager.default.temporaryDirectory.appendingPathComponent("claudedesk-memory-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: host) }
        try checkServer(host: host)
        print("Passed: atrium-memory server entry added, kept, repaired after a move, user entries left alone, invalid files reported.")
    }

    /// A fake bundled binary at <host>/<app>/Contents/MacOS/atrium-memory.
    static func makeExecutable(host: URL, app: String) throws -> URL {
        let folder = host.appendingPathComponent(app + "/Contents/MacOS")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("atrium-memory")
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func mcpURL(_ agent: AgentProfile) -> URL {
        URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
    }

    static func servers(_ agent: AgentProfile) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: mcpURL(agent))) as! [String: Any]
        return object["mcpServers"] as! [String: Any]
    }

    static func checkServer(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Atlas", purpose: "Test", host: host)
        let vault = host.appendingPathComponent("MemoryVault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let exe = try makeExecutable(host: host, app: "ClaudeDesk.app")
        precondition(!MemoryTool.isConnected(agent))

        // Added to a fresh agent, with the exact entry from the spec.
        let added = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        precondition(added == .added)
        let entry = try servers(agent)["atrium-memory"] as! [String: Any]
        precondition(entry["command"] as? String == exe.path && entry["args"] as? [String] == ["mcp"])
        let env = entry["env"] as! [String: String]
        precondition(env == ["ATRIUM_MEMORY_PATH": vault.path, "ATRIUM_MEMORY_ACTOR": "Atlas"])
        precondition(MemoryTool.isConnected(agent) && MemoryTool.isAppWritten(entry))

        // Running again changes nothing.
        let again = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        precondition(again == .unchanged)

        // Other servers are kept.
        var withOther = try servers(agent)
        withOther["example"] = ["type": "http", "url": "https://example.com/mcp"]
        try JSONSerialization.data(withJSONObject: ["mcpServers": withOther]).write(to: mcpURL(agent))
        _ = try MemoryTool.connectServer(agent, executable: exe.path, vault: vault)
        let kept = try servers(agent)
        precondition(kept["example"] != nil, "other servers must be kept")

        // The app moved: the old binary is gone, so the app's own entry is repointed. Nothing else changes.
        let moved = try makeExecutable(host: host, app: "Moved/ClaudeDesk.app")
        try FileManager.default.removeItem(at: exe)
        let repaired = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
        precondition(repaired == .repaired)
        let after = try servers(agent)["atrium-memory"] as! [String: Any]
        precondition(after["command"] as? String == moved.path && after["env"] as? [String: String] == env)

        // A command that still exists is not replaced, even if the app offers another path.
        let elsewhere = try makeExecutable(host: host, app: "Third/ClaudeDesk.app")
        let stays = try MemoryTool.connectServer(agent, executable: elsewhere.path, vault: vault)
        precondition(stays == .unchanged)

        // An entry the user changed is left alone, even when its command is missing.
        try "{\"mcpServers\": {\"atrium-memory\": {\"command\": \"/opt/missing/wrapper\", \"args\": [\"mcp\", \"--actor\", \"me\"]}}}"
            .write(to: mcpURL(agent), atomically: true, encoding: .utf8)
        let userEntry = try String(contentsOf: mcpURL(agent), encoding: .utf8)
        let left = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
        precondition(left == .unchanged)
        let userAfter = try String(contentsOf: mcpURL(agent), encoding: .utf8)
        precondition(userAfter == userEntry)

        // Files that aren't usable JSON are reported and not rewritten.
        for invalid in ["not JSON", "[]", "{\"mcpServers\": []}"] {
            try invalid.write(to: mcpURL(agent), atomically: true, encoding: .utf8)
            do {
                _ = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
                fatalError("invalid .mcp.json should be reported: \(invalid)")
            } catch is AgentEnvironment.Failure {}
            let unchanged = try String(contentsOf: mcpURL(agent), encoding: .utf8)
            precondition(unchanged == invalid)
        }

        // A missing .mcp.json is created.
        try FileManager.default.removeItem(at: mcpURL(agent))
        let created = try MemoryTool.connectServer(agent, executable: moved.path, vault: vault)
        precondition(created == .added && MemoryTool.isConnected(agent))
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/test-memory-tool.sh`
Expected: compile failure, with `cannot find 'MemoryTool' in scope` (or the file `MemoryTool.swift` not found).

- [ ] **Step 3: Write `Sources/ClaudeDesk/MemoryTool.swift`**

```swift
import Foundation

/// Connects agents to atrium-memory, the Memory Vault MCP server that ships inside ClaudeDesk.
/// Every change is additive: other servers, other settings, and anything the user changed are kept.
enum MemoryTool {
    static let serverName = "atrium-memory"
    /// The permission name that allows every atrium-memory tool.
    static let toolPermission = "mcp__atrium-memory"
    static let instructionsMarker = "<!-- claudedesk:memory-tool -->"

    /// The binary bundled next to the app's executable (Contents/MacOS/atrium-memory), when present.
    static var bundledExecutable: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: serverName),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The rule that stops direct file edits inside the vault. Claude permission rules write an absolute path with a
    /// leading "//", so a path that starts with "/" gets one more.
    static func vaultEditRule(_ vault: URL) -> String { "Edit(/" + vault.path + "/**)" }

    static func serverEntry(executable: String, vault: URL, actor: String) -> [String: Any] {
        ["command": executable, "args": ["mcp"],
         "env": ["ATRIUM_MEMORY_PATH": vault.path, "ATRIUM_MEMORY_ACTOR": actor]]
    }

    enum Change: Equatable { case added, repaired, unchanged }

    /// Makes sure the agent's .mcp.json has the atrium-memory server. Adds it when missing. When the app wrote it and
    /// its command no longer exists (the app was moved), points it at `executable`. Anything else is left as it is.
    @discardableResult
    static func connectServer(_ agent: AgentProfile, executable: String, vault: URL) throws -> Change {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw AgentEnvironment.Failure(message: "\(agent.name)'s .mcp.json is not a JSON object, so the Memory Vault tools were not added.")
            }
            config = object
        }
        guard var servers = (config["mcpServers"] ?? [String: Any]()) as? [String: Any] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .mcp.json has a mcpServers value that is not an object, so the Memory Vault tools were not added.")
        }
        let change: Change
        if let existing = servers[serverName] {
            guard var entry = existing as? [String: Any], isAppWritten(entry),
                  let command = entry["command"] as? String, command != executable,
                  !FileManager.default.fileExists(atPath: command) else { return .unchanged }
            entry["command"] = executable
            servers[serverName] = entry
            change = .repaired
        } else {
            servers[serverName] = serverEntry(executable: executable, vault: vault, actor: agent.name)
            change = .added
        }
        config["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
        return change
    }

    /// An entry the app wrote: run as `<…>/atrium-memory mcp`. Entries the user changed don't match, so they're never touched.
    static func isAppWritten(_ entry: [String: Any]) -> Bool {
        (entry["args"] as? [String]) == ["mcp"] && ((entry["command"] as? String)?.hasSuffix("/" + serverName) ?? false)
    }

    /// Whether the agent's .mcp.json lists the atrium-memory server.
    static func isConnected(_ agent: AgentProfile) -> Bool {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }
}
```

- [ ] **Step 4: Run it to see it pass**

Run: `bash scripts/test-memory-tool.sh`
Expected: `Passed: atrium-memory server entry added, kept, repaired after a move, user entries left alone, invalid files reported.`
If compilation fails with a missing type from another source file, add that file to the swiftc line, as `scripts/test-cockpit.sh` does, and note it in your report.

- [ ] **Step 5: Add `MemoryTool.swift` to the runner build and every test script that compiles `AgentEnvironment.swift`**

`RoutineRunner` will use `MemoryTool` from Task 4, so the file must be in every list now:

```bash
for f in scripts/build-app.sh scripts/test-agents.sh scripts/test-routines.sh scripts/test-cockpit.sh scripts/test-skills.sh scripts/test-agent-runtime.sh; do
  sed -i '' 's#Sources/ClaudeDesk/AgentEnvironment.swift#Sources/ClaudeDesk/AgentEnvironment.swift Sources/ClaudeDesk/MemoryTool.swift#' "$f"
done
grep -c "MemoryTool.swift" scripts/build-app.sh scripts/test-agents.sh scripts/test-routines.sh scripts/test-cockpit.sh scripts/test-skills.sh scripts/test-agent-runtime.sh
```

Expected: every file reports `1`. In `build-app.sh`, the match must be on the `RUNNER_SOURCES` line. The main app compile uses `Sources/ClaudeDesk/*.swift` and picks the file up by itself.

- [ ] **Step 6: Run the existing tests and commit**

```bash
for t in test-agents test-routines test-cockpit test-skills test-agent-runtime test-memory-tool; do bash scripts/$t.sh || echo "FAILED: $t"; done
git add Sources/ClaudeDesk/MemoryTool.swift scripts/
git commit -q -m "feat: add the atrium-memory server to agents' .mcp.json" -m "<your harness Co-Authored-By line>"
```

Expected: no `FAILED` lines.

---

### Task 3: Approve the server, block direct vault edits, and teach the agent

**Files:**
- Modify: `Sources/ClaudeDesk/MemoryTool.swift`, `scripts/memory-tool-check.swift`

**Interfaces:**
- Consumes: everything from Task 2.
- Produces:
  - `static func connectSettings(_ agent: AgentProfile, vault: URL) throws`.
  - `static func instructionsSection(vault: URL) -> String` and `static func connectInstructions(_ agent: AgentProfile, vault: URL) throws`.
  - `static func connect(_ agent: AgentProfile, executable: URL, vault: URL, firstTime: Bool) throws -> Change`.
  - `static func projectConfig(executable: URL, vault: URL) -> String`.

- [ ] **Step 1: Add the failing checks**

In `scripts/memory-tool-check.swift`, add `try checkSettingsAndInstructions(host: host)` after `try checkServer(host: host)` in `main()`. Change the printed line to `"Passed: atrium-memory server entry, settings approval and edit block, instructions, project config."`. Add these functions to the struct:

```swift
    static func settings(_ agent: AgentProfile) throws -> [String: Any] {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func checkSettingsAndInstructions(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Scout", purpose: "Find things", host: host)
        let vault = host.appendingPathComponent("MemoryVault")
        let exe = try makeExecutable(host: host, app: "Settings.app")
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        let claudeURL = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")

        // Existing settings are kept; the three entries are added once.
        let existing: [String: Any] = ["permissions": ["additionalDirectories": [vault.path], "allow": ["WebSearch"]], "model": "opus"]
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)
        try MemoryTool.connectSettings(agent, vault: vault)
        try MemoryTool.connectSettings(agent, vault: vault)
        let s = try settings(agent)
        let permissions = s["permissions"] as! [String: Any]
        precondition(s["model"] as? String == "opus")
        precondition(s["enabledMcpjsonServers"] as? [String] == ["atrium-memory"])
        precondition(permissions["allow"] as? [String] == ["WebSearch", "mcp__atrium-memory"])
        precondition(permissions["deny"] as? [String] == ["Edit(/" + vault.path + "/**)"])
        precondition(MemoryTool.vaultEditRule(vault).hasPrefix("Edit(//"))
        precondition(permissions["additionalDirectories"] as? [String] == [vault.path])

        // Settings that aren't usable are reported and not rewritten.
        for invalid in ["not JSON", "{\"permissions\": {\"allow\": \"Read\"}}"] {
            try invalid.write(to: settingsURL, atomically: true, encoding: .utf8)
            do {
                try MemoryTool.connectSettings(agent, vault: vault)
                fatalError("unusable settings should be reported: \(invalid)")
            } catch is AgentEnvironment.Failure {}
            let unchanged = try String(contentsOf: settingsURL, encoding: .utf8)
            precondition(unchanged == invalid)
        }
        try "{}".write(to: settingsURL, atomically: true, encoding: .utf8)

        // The CLAUDE.md section is appended once, and the existing text is kept.
        let before = try String(contentsOf: claudeURL, encoding: .utf8)
        try MemoryTool.connectInstructions(agent, vault: vault)
        try MemoryTool.connectInstructions(agent, vault: vault)
        let text = try String(contentsOf: claudeURL, encoding: .utf8)
        precondition(text.hasPrefix(before))
        precondition(text.components(separatedBy: MemoryTool.instructionsMarker).count == 2, "section added exactly once")
        for phrase in ["## Memory Vault tools", vault.path, "vault_read", "vault_search", "vault_edit", "stale_version", ".tools/vault_check.py"] {
            precondition(text.contains(phrase), "instructions should mention \(phrase)")
        }

        // connect(firstTime: false) only checks the server entry.
        let other = try AgentEnvironment.create(name: "Later", purpose: "x", host: host)
        let otherSettings = URL(fileURLWithPath: other.path).appendingPathComponent(".claude/settings.local.json")
        let otherClaude = URL(fileURLWithPath: other.path).appendingPathComponent("CLAUDE.md")
        let settingsBefore = try String(contentsOf: otherSettings, encoding: .utf8)
        let claudeBefore = try String(contentsOf: otherClaude, encoding: .utf8)
        let change = try MemoryTool.connect(other, executable: exe, vault: vault, firstTime: false)
        precondition(change == .added && MemoryTool.isConnected(other))
        let settingsAfter = try String(contentsOf: otherSettings, encoding: .utf8)
        let claudeAfter = try String(contentsOf: otherClaude, encoding: .utf8)
        precondition(settingsAfter == settingsBefore && claudeAfter == claudeBefore)
        _ = try MemoryTool.connect(other, executable: exe, vault: vault, firstTime: true)
        let claudeConnected = try String(contentsOf: otherClaude, encoding: .utf8)
        precondition(claudeConnected.contains(MemoryTool.instructionsMarker))
        let otherSettingsConnected = try settings(other)
        precondition(otherSettingsConnected["enabledMcpjsonServers"] as? [String] == ["atrium-memory"])

        // The project config is the same entry, with actor "project".
        let project = MemoryTool.projectConfig(executable: exe, vault: vault)
        let parsed = try JSONSerialization.jsonObject(with: Data(project.utf8)) as! [String: Any]
        let entry = (parsed["mcpServers"] as! [String: Any])["atrium-memory"] as! [String: Any]
        precondition((entry["env"] as! [String: String])["ATRIUM_MEMORY_ACTOR"] == "project" && entry["command"] as? String == exe.path)
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/test-memory-tool.sh`
Expected: compile failure, with `type 'MemoryTool' has no member 'connectSettings'`.

- [ ] **Step 3: Add the code to `MemoryTool.swift`, inside the enum, after `isConnected`**

```swift
    /// Approves the server (Claude asks before using a project .mcp.json server, and background runs can't ask),
    /// allows its tools, and blocks direct file edits inside the vault. Only adds; existing settings are kept.
    static func connectSettings(_ agent: AgentProfile, vault: URL) throws {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json is not a JSON object, so the Memory Vault tools were not approved.")
            }
            settings = object
        }
        let original = NSDictionary(dictionary: settings)
        guard settings["permissions"] == nil || settings["permissions"] is [String: Any] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json has a permissions value that is not an object, so the Memory Vault tools were not approved.")
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        settings["enabledMcpjsonServers"] = try adding(serverName, to: settings["enabledMcpjsonServers"], in: agent)
        permissions["allow"] = try adding(toolPermission, to: permissions["allow"], in: agent)
        permissions["deny"] = try adding(vaultEditRule(vault), to: permissions["deny"], in: agent)
        settings["permissions"] = permissions
        guard NSDictionary(dictionary: settings) != original else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    private static func adding(_ value: String, to list: Any?, in agent: AgentProfile) throws -> [String] {
        guard list == nil || list is [String] else {
            throw AgentEnvironment.Failure(message: "\(agent.name)'s .claude/settings.local.json has a permission list that is not a list of strings, so the Memory Vault tools were not approved.")
        }
        var items = list as? [String] ?? []
        if !items.contains(value) { items.append(value) }
        return items
    }

    static func instructionsSection(vault: URL) -> String {
        """

        ## Memory Vault tools
        \(instructionsMarker)
        The Memory Vault at `\(vault.path)` is reached through the `atrium-memory` tools, which are built into ClaudeDesk. Use them instead of reading or editing vault files directly; direct edits in the vault are blocked.
        - Find notes: start from Home and follow the maps with `vault_read` (it returns each note's links), or use `vault_search`.
        - Change notes: `vault_read` first and keep its `version`. Then use `vault_edit` for one passage, `vault_append` to add to the end, or `vault_write` to create a note (no version) or replace a whole note (with the version).
        - On `stale_version`, the note changed since you read it: read it again, merge your change, and retry. On `exists`, read the note and update it instead.
        - `vault_list` lists a folder's notes, and `vault_backlinks` shows which notes link to one.
        - The vault checker still runs with `python3 \(vault.path)/.tools/vault_check.py`.

        """
    }

    /// Appends the Memory Vault tools section to CLAUDE.md once; the rest of the file is kept.
    static func connectInstructions(_ agent: AgentProfile, vault: URL) throws {
        let url = URL(fileURLWithPath: agent.path).appendingPathComponent("CLAUDE.md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !text.contains(instructionsMarker) else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += instructionsSection(vault: vault)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Connects an agent. The server entry is checked every time, so a moved app is repaired. Settings and
    /// instructions are added only the first time, so the user's later edits to those files are respected.
    @discardableResult
    static func connect(_ agent: AgentProfile, executable: URL, vault: URL, firstTime: Bool) throws -> Change {
        let change = try connectServer(agent, executable: executable.path, vault: vault)
        if firstTime {
            try connectSettings(agent, vault: vault)
            try connectInstructions(agent, vault: vault)
        }
        return change
    }

    /// The entry for the user's own Claude sessions (Projects), as JSON to paste into an .mcp.json.
    static func projectConfig(executable: URL, vault: URL) -> String {
        let object: [String: Any] = ["mcpServers": [serverName: serverEntry(executable: executable.path, vault: vault, actor: "project")]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
```

- [ ] **Step 4: Run it to see it pass**

Run: `bash scripts/test-memory-tool.sh`
Expected: `Passed: atrium-memory server entry, settings approval and edit block, instructions, project config.`

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeDesk/MemoryTool.swift scripts/memory-tool-check.swift
git commit -q -m "feat: approve atrium-memory, block direct vault edits, add agent instructions" -m "<your harness Co-Authored-By line>"
```

---

### Task 4: Let routines and Cockpit runs use the vault tools

**Files:**
- Modify: `Sources/ClaudeDesk/RoutineRunner.swift` (`arguments(for:agent:runID:prompt:)` around line 222, and its call site around line 156), `scripts/memory-tool-check.swift`

**Interfaces:**
- Consumes: `MemoryTool.isConnected(_:)`, `MemoryTool.toolPermission` and `MemoryTool.vaultEditRule(_:)`; `Routine(name:)` (memberwise, with defaults); `Workspace.vault(in:)`.
- Produces: `static func arguments(for routine: Routine, agent: AgentProfile, runID: String, prompt: String, vault: URL? = nil) -> [String]`.

- [ ] **Step 1: Add the failing check**

In `main()`, add `try checkRunnerArguments(host: host)` after the other checks, and change the printed line to `"Passed: atrium-memory server entry, settings approval and edit block, instructions, project config, runner arguments."`. Add:

```swift
    static func checkRunnerArguments(host: URL) throws {
        let agent = try AgentEnvironment.create(name: "Runner", purpose: "x", host: host)
        let vault = host.appendingPathComponent("RunnerVault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".tools"), withIntermediateDirectories: true)
        try "".write(to: vault.appendingPathComponent(".tools/vault_check.py"), atomically: true, encoding: .utf8)
        let settingsURL = URL(fileURLWithPath: agent.path).appendingPathComponent(".claude/settings.local.json")
        try JSONSerialization.data(withJSONObject: ["permissions": ["additionalDirectories": [vault.path]]]).write(to: settingsURL)
        let routine = Routine(name: "nightly")
        let vaultEdit = "Edit(/" + vault.path + "/**)"
        let checker = "Bash(python3 " + vault.appendingPathComponent(".tools/vault_check.py").path + ")"

        // Not connected: today's behaviour, unchanged.
        let before = RoutineRunner.arguments(for: routine, agent: agent, runID: "r1", prompt: "go", vault: vault)
        precondition(before.contains(vaultEdit) && !before.contains("mcp__atrium-memory") && !before.contains("--disallowedTools"))

        // Connected: the tools are allowed, vault edits are not granted and are explicitly disallowed.
        _ = try MemoryTool.connectServer(agent, executable: "/Applications/ClaudeDesk.app/Contents/MacOS/atrium-memory", vault: vault)
        let after = RoutineRunner.arguments(for: routine, agent: agent, runID: "r2", prompt: "go", vault: vault)
        let separator = after.firstIndex(of: "--")!
        precondition(after.contains("mcp__atrium-memory") && after.firstIndex(of: "mcp__atrium-memory")! < separator)
        let allowedStart = after.firstIndex(of: "--allowedTools")! + 1
        let disallowed = after.firstIndex(of: "--disallowedTools")!
        precondition(!after[allowedStart..<disallowed].contains(vaultEdit), "connected agents must not be granted Edit on the vault")
        precondition(after[disallowed + 1] == vaultEdit && disallowed < separator)
        precondition(after.contains(checker), "the vault checker stays allowed")
        precondition(after.contains("Edit(/" + agent.path + "/**)"), "the agent's own folder stays editable")
        precondition(after.last == "go" && after[separator + 1] == "go")

        // Without a vault (older callers), nothing changes for connected agents either.
        let noVault = RoutineRunner.arguments(for: routine, agent: agent, runID: "r3", prompt: "go")
        precondition(!noVault.contains("mcp__atrium-memory") && !noVault.contains("--disallowedTools"))
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/test-memory-tool.sh`
Expected: compile failure, with `extra argument 'vault' in call`.

- [ ] **Step 3: Change `arguments` in `Sources/ClaudeDesk/RoutineRunner.swift`**

Replace the whole function `static func arguments(for routine: Routine, agent: AgentProfile, runID: String, prompt: String) -> [String]`, including its doc comment, with:

```swift
    /// Restricted profile proven in the spike: default mode, no prompts, and only the listed tools allowed.
    /// Agents connected to atrium-memory also get its tools, and change the vault only through them.
    static func arguments(for routine: Routine, agent: AgentProfile, runID: String, prompt: String, vault: URL? = nil) -> [String] {
        var tools = ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "WebSearch", "Skill"]
        var allowed = ["Read", "Glob", "Grep", "WebSearch", "Skill"]
        if routine.tools.contains("web-fetch") { tools.append("WebFetch"); allowed.append("WebFetch") }
        let memoryVault = vault.flatMap { MemoryTool.isConnected(agent) ? $0 : nil }
        let vaultPaths = memoryVault.map { Set([$0.path, $0.resolvingSymlinksInPath().path]) } ?? []
        for directory in [agent.path] + additionalDirectories(of: agent) {
            if !vaultPaths.contains(directory) { allowed.append("Edit(/" + directory + "/**)") }
            let checker = URL(fileURLWithPath: directory).appendingPathComponent(".tools/vault_check.py").path
            if FileManager.default.fileExists(atPath: checker) {
                allowed.append("Bash(python3 \(checker))")
                allowed.append("Bash(python3 \(checker) *)")
            }
        }
        if memoryVault != nil { allowed.append(MemoryTool.toolPermission) }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--session-id", runID, "--max-turns", String(routine.maxTurns),
                         "--permission-mode", "default", "--permission-prompts", "none",
                         "--tools", tools.joined(separator: ","), "--allowedTools"] + allowed
        if let memoryVault { arguments += ["--disallowedTools", MemoryTool.vaultEditRule(memoryVault)] }
        return arguments + ["--", prompt]
    }
```

At the call site (around line 156), change:

```swift
        let arguments = Self.arguments(for: routine, agent: agent, runID: runID, prompt: text)
```

to:

```swift
        let arguments = Self.arguments(for: routine, agent: agent, runID: runID, prompt: text, vault: Workspace.vault(in: workspace))
```

- [ ] **Step 4: Run the checks and the existing routine tests**

```bash
bash scripts/test-memory-tool.sh && bash scripts/test-routines.sh && bash scripts/test-agent-runtime.sh
```

Expected: all three print their `Passed:` lines. The existing routines test uses an unconnected agent, so its argument assertions still hold.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeDesk/RoutineRunner.swift scripts/memory-tool-check.swift
git commit -q -m "feat: routines use atrium-memory and can't edit the vault directly" -m "<your harness Co-Authored-By line>"
```

---

### Task 5: The Cockpit flare follows the audit log

**Files:**
- Modify: `Sources/ClaudeDesk/VaultActivity.swift`, `Sources/ClaudeDesk/CockpitStore.swift` (`refreshVaultReads()` around lines 77–93), `scripts/memory-tool-check.swift`

**Interfaces:**
- Consumes: `VaultActivity.Tail` (`newLines(in:now:) -> [(URL, String)]`) and `VaultRead(date:agent:)`.
- Produces: `static func auditLog(in vault: URL) -> URL` and `static func auditReads(in line: String) -> (actor: String, notes: [String])?` on `VaultActivity`.

- [ ] **Step 1: Add the failing check**

In `main()`, add `try checkAuditFlare(host: host)` and change the printed line to `"Passed: atrium-memory server entry, settings approval and edit block, instructions, project config, runner arguments, audit flare."`. Add:

```swift
    static func checkAuditFlare(host: URL) throws {
        let read = VaultActivity.auditReads(in: #"{"time":"2026-11-10T09:00:00Z","actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"ok"}"#)
        precondition(read?.actor == "Atlas" && read?.notes == ["Notes/A.md"])
        let search = VaultActivity.auditReads(in: #"{"actor":"Scout","tool":"vault_search","query":"aws","results":["Notes/A.md","Maps/Tech.md"],"outcome":"ok"}"#)
        precondition(search?.actor == "Scout" && search?.notes == ["Notes/A.md", "Maps/Tech.md"])
        for ignored in [
            #"{"actor":"Atlas","tool":"vault_read","id":"Notes/A.md","outcome":"not_found"}"#,
            #"{"actor":"Atlas","tool":"vault_write","id":"Notes/A.md","outcome":"ok"}"#,
            #"{"actor":"Atlas","tool":"vault_search","outcome":"ok"}"#,
            "not json", ""
        ] {
            let result = VaultActivity.auditReads(in: ignored)
            precondition(result == nil || result!.notes.isEmpty, "should light nothing: \(ignored)")
        }
        let vault = host.appendingPathComponent("FlareVault")
        precondition(VaultActivity.auditLog(in: vault).path == vault.path + "/.atrium-memory/audit.jsonl")

        // A freshly created audit file is followed from the start, and appended lines arrive on the next call.
        let log = VaultActivity.auditLog(in: vault)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"actor":"Atlas","tool":"vault_read","id":"Home.md","outcome":"ok"}"# + "\n").write(to: log, atomically: true, encoding: .utf8)
        let tail = VaultActivity.Tail()
        let first = tail.newLines(in: [log]).compactMap { VaultActivity.auditReads(in: $0.1) }
        precondition(first.map(\.notes) == [["Home.md"]])
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"actor":"Atlas","tool":"vault_read","id":"Notes/B.md","outcome":"ok"}"# + "\n").utf8))
        try handle.close()
        let second = tail.newLines(in: [log]).compactMap { VaultActivity.auditReads(in: $0.1) }
        precondition(second.map(\.notes) == [["Notes/B.md"]])
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/test-memory-tool.sh`
Expected: compile failure, with `type 'VaultActivity' has no member 'auditReads'`.

- [ ] **Step 3: Add to `enum VaultActivity` in `Sources/ClaudeDesk/VaultActivity.swift`, after `notes(in:vaultPaths:)`**

```swift
    /// atrium-memory's call log inside the vault.
    static func auditLog(in vault: URL) -> URL {
        vault.appendingPathComponent(".atrium-memory/audit.jsonl")
    }

    /// Notes one atrium-memory audit line shows an agent looking at: the note of a successful `vault_read`, or the
    /// results of a successful `vault_search`, with the caller's name. Nil for other tools, failures, and other lines.
    static func auditReads(in line: String) -> (actor: String, notes: [String])? {
        struct Entry: Decodable { var actor: String?; var tool: String?; var id: String?; var results: [String]?; var outcome: String? }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)), entry.outcome == "ok" else { return nil }
        switch entry.tool {
        case "vault_read": return entry.id.map { (actor: entry.actor ?? "", notes: [$0]) }
        case "vault_search": return (actor: entry.actor ?? "", notes: entry.results ?? [])
        default: return nil
        }
    }
```

Also replace the doc comment on `enum VaultActivity` (the two `///` lines above `enum VaultActivity {`) with:

```swift
/// Finds which Memory Vault notes agents read or search: from atrium-memory's audit log, and, as a fallback, by
/// following their transcripts as they grow (direct reads and `@` imports put the note's full path in a transcript line).
```

- [ ] **Step 4: Follow the audit log in `refreshVaultReads()` in `Sources/ClaudeDesk/CockpitStore.swift`**

Replace this loop:

```swift
        for (file, line) in vaultTail.newLines(in: transcripts.map(\.1), now: now) where line.contains(vault.lastPathComponent) {
            for note in VaultActivity.notes(in: line, vaultPaths: roots) where notes.contains(note) {
                reads[note] = VaultRead(date: now, agent: owners[file.path] ?? "")
            }
        }
```

with:

```swift
        let audit = VaultActivity.auditLog(in: vault)
        let files = transcripts.map(\.1) + (FileManager.default.fileExists(atPath: audit.path) ? [audit] : [])
        for (file, line) in vaultTail.newLines(in: files, now: now) {
            if file.path == audit.path {
                if let seen = VaultActivity.auditReads(in: line) {
                    for note in seen.notes where notes.contains(note) { reads[note] = VaultRead(date: now, agent: seen.actor) }
                }
                continue
            }
            guard line.contains(vault.lastPathComponent) else { continue }
            for note in VaultActivity.notes(in: line, vaultPaths: roots) where notes.contains(note) {
                reads[note] = VaultRead(date: now, agent: owners[file.path] ?? "")
            }
        }
```

- [ ] **Step 5: Run the checks, the Cockpit tests and the app build**

```bash
bash scripts/test-memory-tool.sh && bash scripts/test-cockpit.sh && bash scripts/build-app.sh
```

Expected: both tests print `Passed:` lines, and the build reaches `Built …/dist/ClaudeDesk.app`. The full app compile checks the `CockpitStore` change.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeDesk/VaultActivity.swift Sources/ClaudeDesk/CockpitStore.swift scripts/memory-tool-check.swift
git commit -q -m "feat: Cockpit flare follows the atrium-memory audit log" -m "<your harness Co-Authored-By line>"
```

---

### Task 6: Build and bundle `atrium-memory` into the app

**Files:**
- Create: `Resources/atrium-memory.version`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Produces: `dist/ClaudeDesk.app/Contents/MacOS/atrium-memory`, a universal binary signed like the runner. Task 7 finds it through `MemoryTool.bundledExecutable`.

- [ ] **Step 1: Pin the version**

```bash
printf '0.1.0\n' > Resources/atrium-memory.version
```

- [ ] **Step 2: Build the binary in `scripts/build-app.sh`**

Insert this block right after the `swiftc … -o .build/release/claudedesk-runner` command and before `APP="${APP_PATH:-…}"`:

```bash
# atrium-memory, the Memory Vault MCP server, ships inside the app at the version in Resources/atrium-memory.version.
# Development builds compile it from the local checkout; otherwise the release is downloaded and its checksum checked.
MEMORY_VERSION="$(tr -d '[:space:]' < Resources/atrium-memory.version)"
MEMORY_SRC="${ATRIUM_MEMORY_SRC:-$PWD/../brainvault}"
MEMORY_OUT="$PWD/.build/atrium-memory"
rm -rf "$MEMORY_OUT" && mkdir -p "$MEMORY_OUT"
if [[ -f "$MEMORY_SRC/go.mod" ]]; then
    for arch in arm64 amd64; do
        (cd "$MEMORY_SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath \
            -ldflags "-s -w -X main.version=$MEMORY_VERSION-dev" -o "$MEMORY_OUT/atrium-memory-$arch" ./cmd/atrium-memory)
    done
else
    MEMORY_BASE="https://github.com/poom-h/atrium-memory/releases/download/v$MEMORY_VERSION"
    curl -fsSL "$MEMORY_BASE/checksums.txt" -o "$MEMORY_OUT/checksums.txt"
    for arch in arm64 amd64; do
        archive="atrium-memory_${MEMORY_VERSION}_darwin_${arch}.tar.gz"
        curl -fsSL "$MEMORY_BASE/$archive" -o "$MEMORY_OUT/$archive"
        (cd "$MEMORY_OUT" && grep " $archive\$" checksums.txt | shasum -a 256 -c -)
        tar -xzf "$MEMORY_OUT/$archive" -C "$MEMORY_OUT" atrium-memory
        mv "$MEMORY_OUT/atrium-memory" "$MEMORY_OUT/atrium-memory-$arch"
    done
fi
lipo -create "$MEMORY_OUT/atrium-memory-arm64" "$MEMORY_OUT/atrium-memory-amd64" -output "$MEMORY_OUT/atrium-memory"
```

After the line `cp .build/release/claudedesk-runner "$APP/Contents/MacOS/claudedesk-runner"`, add:

```bash
cp "$MEMORY_OUT/atrium-memory" "$APP/Contents/MacOS/atrium-memory"
```

Before the line `codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/claudedesk-runner"`, add:

```bash
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/atrium-memory"
```

- [ ] **Step 3: Build and check the bundle**

```bash
bash scripts/build-app.sh
B=dist/ClaudeDesk.app/Contents/MacOS/atrium-memory
lipo -archs "$B"
"$B" version
codesign --verify --strict "$B" && codesign --verify --deep --strict dist/ClaudeDesk.app && echo signed-ok
```

Expected: `x86_64 arm64` (in either order), `0.1.0-dev`, and `signed-ok`.

- [ ] **Step 4: Check the bundled binary really serves the vault template**

```bash
"$B" doctor --vault Resources/VaultTemplate; echo "exit=$?"
```

Expected: JSON with `"errors": []`, then `exit=0`. Warnings are fine.

- [ ] **Step 5: Commit**

```bash
git add Resources/atrium-memory.version scripts/build-app.sh
git commit -q -m "build: bundle a universal atrium-memory in the app" -m "<your harness Co-Authored-By line>"
```

---

### Task 7: Connect agents at launch, and add "Copy MCP config"

**Files:**
- Modify: `Sources/ClaudeDesk/InboxStore.swift` (`connectAgentsToInbox()` around lines 94–122), `Sources/ClaudeDesk/App.swift` (`SettingsView.general`, after the "Claude Code" texts)

**Interfaces:**
- Consumes: `MemoryTool.bundledExecutable`, `MemoryTool.connect(_:executable:vault:firstTime:) -> Change`, `MemoryTool.projectConfig(executable:vault:)` and `Workspace.vault(in:)`; the store's `agents`, `workspaceURL`, `log(_:actor:subject:details:)` and `error`.

- [ ] **Step 1: Connect every agent in `connectAgentsToInbox()`**

In `Sources/ClaudeDesk/InboxStore.swift`, insert this block after `UserDefaults.standard.set(Array(widgetConnected), forKey: widgetKey)` and before `if !problems.isEmpty`:

```swift
        // atrium-memory arrived in 3.8.0. The server entry is checked on every launch, so a moved app is repaired.
        // Settings and instructions are added once per agent, so later edits to those files are respected.
        if let executable = MemoryTool.bundledExecutable {
            let memoryKey = "workspaceConnectedAgents.memory.v1"
            var memoryConnected = Set(UserDefaults.standard.stringArray(forKey: memoryKey) ?? [])
            let vault = Workspace.vault(in: workspace)
            for agent in agents {
                do {
                    let firstTime = !memoryConnected.contains(agent.id.uuidString)
                    let change = try MemoryTool.connect(agent, executable: executable, vault: vault, firstTime: firstTime)
                    if firstTime { memoryConnected.insert(agent.id.uuidString) }
                    if firstTime || change != .unchanged {
                        log("agent.memory-connected", actor: "app", subject: agent.name,
                            details: ["agent": agent.id.uuidString, "change": "\(change)"])
                    }
                } catch { problems.append("\(agent.name): \(error.localizedDescription)") }
            }
            UserDefaults.standard.set(Array(memoryConnected), forKey: memoryKey)
        }
```

In the same function, change the error text from `"Could not connect every agent to the Inbox.\n"` to `"Could not finish connecting every agent.\n"`.

- [ ] **Step 2: Add "Copy MCP config" to Settings › General**

In `Sources/ClaudeDesk/App.swift`, inside `private var general: some View`, after the `Text("Claude runs inside the app with its normal permissions and sign-in. …")` element and its modifiers, and before `}.padding(24)`, add:

```swift
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
```

If the build reports `cannot find 'NSPasteboard' in scope`, add `import AppKit` at the top of `App.swift`.

- [ ] **Step 3: Build and run every check**

```bash
bash scripts/build-app.sh
for t in test test-agents test-routines test-cockpit test-skills test-agent-runtime test-memory-tool; do bash scripts/$t.sh || echo "FAILED: $t"; done
```

Expected: `Built …`, then no `FAILED` lines.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeDesk/InboxStore.swift Sources/ClaudeDesk/App.swift
git commit -q -m "feat: connect agents to atrium-memory at launch; Copy MCP config in Settings" -m "<your harness Co-Authored-By line>"
```

- [ ] **Step 5: Live check on the user's real agents (only with the user's go-ahead)**

This step changes the user's real agent folders, which is the point of the feature, so ask first. Then quit any running ClaudeDesk and launch the new build with a clean environment, never a bare `open`:

```bash
env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -a "$PWD/dist/ClaudeDesk.app"
```

Wait about 10 seconds, then check one agent (Atlas):

```bash
A=$(ls -d /Users/poomhirunwiwatkul/Documents/BrainHub/agent_brain/atlas-*)
cat "$A/.mcp.json"
grep -n "enabledMcpjsonServers\|mcp__atrium-memory\|Edit(//" "$A/.claude/settings.local.json"
grep -c "claudedesk:memory-tool" "$A/CLAUDE.md"
(cd "$A" && CLAUDE_CONFIG_DIR="$A/.runtime" claude mcp list)
```

Expected:
- the `atrium-memory` entry, pointing at `…/dist/ClaudeDesk.app/Contents/MacOS/atrium-memory`;
- three matching settings lines;
- `1`;
- `atrium-memory` listed as connected.

Report the output. Don't start a paid Claude run. The user tries one conversation themselves.

---

### Task 8: Template, docs and version

**Files:**
- Modify: `Resources/VaultTemplate/Notes/Second-Brain-Framework.md`, `README.md`, `docs/design/cockpit.md`, `scripts/build-app.sh` (Info.plist version)

**Interfaces:**
- Consumes: nothing new. `scripts/agent-check.swift` asserts that the framework still contains ``Vault: `<path>` ``, so keep that line.

- [ ] **Step 1: Point new vaults' framework at the tools**

In `Resources/VaultTemplate/Notes/Second-Brain-Framework.md`:
- In `## Retrieval`, replace the sentence that begins `Start from Home, which is already loaded, and follow map descriptions to the likely note before searching the whole vault.` with:
  ``Start from Home, which is already loaded, and follow map descriptions with `vault_read` (it returns each note's links) to the likely note before using `vault_search` on the whole vault.``
- In `## Capture and maintenance workflow`, replace step 1 with:
  ``1. Start from Home and follow the relevant maps with `vault_read`; then use `vault_search` for equivalent or related information.``
- Add this as the last sentence of step 6:
  ``Save through the `vault_*` tools: `vault_write` to create a note, `vault_edit` or `vault_append` to change one, always passing the `version` from your last `vault_read`.``

Then check that the template still passes the agent checks and the bundled doctor:

```bash
bash scripts/test-agents.sh && dist/ClaudeDesk.app/Contents/MacOS/atrium-memory doctor --vault Resources/VaultTemplate >/dev/null; echo "doctor exit=$?"
```

Expected: `Passed: …` and `doctor exit=0`.

- [ ] **Step 2: Bump the app version**

In `scripts/build-app.sh`'s Info.plist, change `<string>3.7.0</string>` to `<string>3.8.0</string>` and `<key>CFBundleVersion</key><string>12</string>` to `<key>CFBundleVersion</key><string>13</string>`.

- [ ] **Step 3: Document it**

In `README.md`:
- Add `bash scripts/test-memory-tool.sh` to the list under "Development and verification".
- After the "Version 3.7 · Agent widgets" section (before the next `## ` heading), add:

```markdown
## Version 3.8 · Memory Vault tools

Agents now reach the Memory Vault through **atrium-memory**, an MCP server built into ClaudeDesk (`Contents/MacOS/atrium-memory`; source: github.com/poom-h/atrium-memory). On launch, every agent gets it in its `.mcp.json`, approved in its local settings so routines and Cockpit runs can use it too, and a "Memory Vault tools" section in its CLAUDE.md. Agents search and follow maps with `vault_search` and `vault_read`, and change notes with `vault_edit`, `vault_append` and `vault_write`. Every change is checked against the version the agent last read, written all at once, and logged to `MemoryVault/.atrium-memory/audit.jsonl` without note content.

Direct file edits inside the vault are blocked for agents (an `Edit` deny rule), so the tools are the only way to change it; reading files and running the vault checker still work. Moving ClaudeDesk.app is fine: the next launch repoints every agent's entry. Your own entries and other servers are never changed. To use the same tools in your own Claude sessions, Settings › General › Copy MCP config.

The Cockpit's memory flare now follows the audit log, labelled with the agent's name, with the transcript scan kept as a fallback.

`bash scripts/test-memory-tool.sh` covers the server entry (add, keep, repair after a move, user entries, invalid files), settings and instructions, runner arguments and the audit flare.
```

In `docs/design/cockpit.md`, in the vault-flare paragraph (the one that begins `When an agent reads or searches a vault note, its star flares`), add this bullet right after the `- **Source:** …` bullet:

```markdown
- **Source (3.8):** atrium-memory's audit log, `MemoryVault/.atrium-memory/audit.jsonl`, followed the same way: a successful `vault_read` lights its note and a successful `vault_search` lights its results, labelled with the call's `actor` (the agent's name). Transcripts remain the fallback for direct reads and `@` imports.
```

- [ ] **Step 4: Final build and commit**

```bash
bash scripts/build-app.sh
for t in test test-agents test-routines test-cockpit test-skills test-agent-runtime test-memory-tool; do bash scripts/$t.sh || echo "FAILED: $t"; done
git add -A
git commit -q -m "docs: Memory Vault tools in the template, README and Cockpit design; version 3.8.0" -m "<your harness Co-Authored-By line>"
```

Expected: `Built …`, no `FAILED` lines, one commit.

---

## Spec coverage

| Spec item (ClaudeDesk integration) | Task |
|---|---|
| 1. Bundling: universal, pinned, local source or verified release, signed, always the bundled copy | 6 (and 7 via `bundledExecutable`) |
| 2. Wiring: add on every launch, keep others, report invalid files, repair a moved app's own entry | 2, 7 |
| 3. Approval: `enabledMcpjsonServers` and `permissions.allow` | 3 |
| 4. Routines and Cockpit runs get the tools | 4 |
| 5. Enforcement: deny rule, runner drops Edit on the vault and disallows it, reads and checker kept | 3, 4 |
| 6. Instructions section once; template framework updated; existing vaults untouched | 3, 8 |
| 7. Projects: Copy MCP config with actor `project` | 3, 7 |
| 8. Cockpit flare follows the audit log; transcript fallback kept; design doc note | 5, 8 |
| 9. Migration: existing agents connected on next launch | 7 |
