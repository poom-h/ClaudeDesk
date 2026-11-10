# atrium-memory: the Memory Vault as a tool

Date: 2026-11-07 (integration section revised 2026-11-10)
Status: Design approved. The tool is built (repo `poom-h/atrium-memory`); the ClaudeDesk integration is planned in Plan 2.
Name: `atrium-memory`, renamed from the working name `brainvault` on 2026-11-10. Below, read `brainvault` as `atrium-memory`, `BRAINVAULT_*` as `ATRIUM_MEMORY_*` and `.brainvault/` as `.atrium-memory/`.
Related: `docs/design/cockpit.md` (vault activity flare, quick search)

## Problem

The Memory Vault is a plain folder (`<workspace>/MemoryVault`). Agents reach it by file path, injected into their `CLAUDE.md` through `{{VAULT_PATH}}`. The Cockpit learns which notes agents touched by scanning transcripts for those paths (`VaultActivity.swift`).

This has three weaknesses:

1. Only processes that know the path and have filesystem access can use the vault. Other agents and services have no defined interface.
2. Nothing enforces safe writes: there is no confinement, no stale-write check, and no record of who changed what.
3. Activity tracking is inferred from transcript text, so it is fragile.

ClaudeDesk is also expected to be published for anyone to download, and eventually to run on Windows as well as macOS. The vault interface must not be tied to the Mac-only Swift app.

## Goals

- Agents use the vault through tools (MCP), not raw file paths.
- Any local MCP client can use the same tool: ClaudeDesk agents, plain Claude Code, or other MCP clients.
- Agents can read and write directly. Writes are confined to the vault, checked for staleness, atomic, and logged.
- The tool is a standalone, cross-platform program (macOS, Windows, Linux) with no dependency on ClaudeDesk.
- Existing vaults keep working unchanged.

## Non-goals (first version)

- Network access: no HTTP transport and no remote or cloud callers. The transport is local stdio only.
- Semantic or embedding search.
- Sync between machines.
- Porting the ClaudeDesk app itself to Windows. That is a separate project; this design only keeps the vault from blocking it.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Who can call it | Local only | No auth, TLS or hosting needed; covers agents and local tools |
| Write policy | Read and write directly | Matches how agents maintain the vault today; safety enforced in the tool |
| Shape | Standalone tool, the app is one client | Publishable, reusable, and cross-platform independent of the app |
| Language | Go, with the official `modelcontextprotocol/go-sdk` (v1.x) | Single static binary per OS, easy cross-compilation, small codebase |
| Transport | MCP over stdio | Supported by every MCP client; no ports or long-running service |

Alternatives considered and rejected:

- MCP mode in the Swift `claudedesk-runner`: reuses existing code, but ties the tool to a Mac-only binary.
- TypeScript server: mature SDK, but users need Node or a bundled runtime.
- Rust server: good fit technically, but a steeper curve for contributors on a small tool.
- Relying on the Obsidian MCP: needs Obsidian running, and gives no control over write safety or logging.

## Architecture

```
Vault format spec   SPEC.md: the contract any implementation follows
       │
Core library        internal/vault: index, search, backlinks, link resolution, safe read/write
       │
Adapters            cmd/brainvault: `mcp` (stdio), CLI subcommands, `doctor`
       │
Clients             ClaudeDesk agents, Claude Code, other MCP clients, scripts
```

Boundary rule: adapters only translate input and output. All behaviour and every safety rule live in `internal/vault` and are tested there.

### Repository layout

```
brainvault/
├── SPEC.md
├── internal/vault/      open vault, path resolution, index, search, backlinks, read/write
├── internal/lock/       per-OS file locking behind one interface
├── internal/audit/      append-only JSONL call log
├── cmd/brainvault/      one binary: mcp | search | read | list | backlinks | write | doctor
├── testdata/vaults/     sample vaults, including the ClaudeDesk VaultTemplate
└── .goreleaser.yml
```

The tool lives in its own repository. ClaudeDesk consumes released binaries.

### Vault format (SPEC.md)

SPEC.md writes down the current format so other tools can implement it:

- A vault is a folder of Markdown notes. ClaudeDesk creates `Inbox/`, `Notes/`, `Maps/`, `Assets/`, `Archive/` and `Home.md`, but the tool accepts any folder layout.
- Optional YAML frontmatter at the top of a note.
- Links use Obsidian syntax: `[[Note]]`, `[[Note|alias]]` and `[[Note#heading]]`. A link resolves to a note by file name (case-insensitive, without `.md`). If several notes share that name, the shortest path wins, which is Obsidian's rule.
- Note ID is the vault-relative path with forward slashes on every OS, for example `Notes/LangGraph basics.md`. This matches the Cockpit graph's node IDs.
- Folders whose names start with `.` (such as `.obsidian/` and `.tools/`) are not notes and are never listed or written.

### Configuration

The tool has exactly two inputs, both generic. Nothing in the tool knows about ClaudeDesk.

| Variable | Required | Meaning |
|---|---|---|
| `BRAINVAULT_PATH` | yes | Absolute path to the vault folder |
| `BRAINVAULT_ACTOR` | no (default `unknown`) | Caller name recorded in the log, for example an agent name |

CLI flags `--vault` and `--actor` override the variables.

The log is written to `<vault>/.brainvault/audit.jsonl`. Keeping it inside the vault means any client watching that vault, including the Cockpit, finds it without per-OS config paths. The `.` prefix keeps it out of notes and out of Obsidian's file list.

## MCP tools

All paths are note IDs. Every result that returns note content also returns `version`, a SHA-256 hash of the file bytes.

| Tool | Input | Output |
|---|---|---|
| `vault_search` | `query`, optional `folder`, `limit` (default 20, max 100) | Matching notes, each with `id`, `title` and a short snippet |
| `vault_read` | `id` | `content`, `frontmatter` (parsed), `links` (outgoing IDs), `version` |
| `vault_list` | optional `folder`, `recursive` (default true) | Note IDs with `title` and modified time |
| `vault_backlinks` | `id` | IDs of notes that link to it |
| `vault_write` | `id`, `content`, `version` (required to replace an existing note; omit to create) | New `version`. Creating fails if the note exists |
| `vault_append` | `id`, `text`, optional `version` | New `version`. Appends with a separating newline; creates the note if missing |
| `vault_edit` | `id`, `old_text`, `new_text`, `version` | New `version`. `old_text` must appear exactly once |

Search follows the Cockpit's `VaultSearch` rule so agents and the Cockpit agree: every word of the query must match the title, path or text (case-insensitive), and matches rank titles above paths above text. The index is built from disk on each call, which is fast enough for vaults of a few thousand notes. A cached index is a later optimisation if measurements call for it.

`vault_append` takes an optional version because appends from several agents do not conflict with each other; the lock is enough. `vault_write` (replace) and `vault_edit` require a version because they replace content.

## Safety rules (enforced in the core)

1. **Confinement.** An ID is cleaned and resolved against the vault root. It is rejected if it is absolute, contains `..` after cleaning, resolves through a symlink to a path outside the vault, or targets a dot-folder. Writes are only allowed to `.md` files.
2. **Stale writes.** `vault_write` (replace), `vault_edit`, and `vault_append` with a version, compare the supplied version to the current file hash and fail with `stale_version` if they differ.
3. **Atomic writes.** Write to a temp file in the same folder, then rename over the target. Missing parent folders are created.
4. **Locking.** One lock file per vault (`<vault>/.brainvault/write.lock`), held for the read-compare-write sequence. The lock wait is limited to 5 seconds, then the call fails with `locked`. `internal/lock` uses `flock` on Unix and `LockFileEx` on Windows.
5. **Line endings and encoding.** Notes are UTF-8. Existing files keep their line-ending style; new files use LF. Unicode file names are normalised to NFC when comparing IDs, so macOS (NFD on disk) and other systems agree.
6. **Case.** IDs are matched case-insensitively when resolving existing notes, since macOS and Windows file systems usually are. A create whose ID differs only in case from an existing note fails with `exists`.
7. **Logging.** Every call, including failures, appends one JSON line: `time`, `actor`, `tool`, `id` (or `query` and the returned IDs for search), `outcome`. Note content is never logged.

## Errors

Tool failures return an MCP tool error with a typed code and a sentence an agent can act on. The server never exits on a bad call.

| Code | When | Agent's next step |
|---|---|---|
| `not_found` | Note does not exist | Search or create |
| `exists` | Create target already exists | Read, then write with its version |
| `outside_vault` | Confinement rule failed | Use a vault-relative note ID |
| `stale_version` | Note changed since it was read; includes `current_version` | Re-read, merge, retry |
| `no_match` / `ambiguous_match` | `vault_edit` text found 0 or more than 1 times | Re-read and use a longer `old_text` |
| `invalid_note` | Not `.md`, or not valid UTF-8 | Fix the ID or content |
| `locked` | Lock not acquired within 5 seconds | Retry shortly |

Startup errors (missing or unreadable `BRAINVAULT_PATH`) are written to stderr and the process exits non-zero, so the MCP client reports the server as failed.

## ClaudeDesk integration

Users install one app. The tool ships inside it; nothing is installed separately.

1. **Bundling.** `Contents/MacOS/atrium-memory`, next to `claudedesk-runner`. `build-app.sh` builds it as a universal (arm64 + x86_64) binary from a pinned version (`Resources/atrium-memory.version`): from the local source checkout `../brainvault` when it exists (development), otherwise from that version's GitHub release, verified against its `checksums.txt`. It is signed with the same identity as the app. ClaudeDesk always uses its bundled copy, never one on the user's PATH, so the tool names and audit-log format always match the app.
2. **Wiring.** On every launch, for every agent, the app makes sure the agent's `.mcp.json` has this entry. It adds it if missing, never overwrites another server or an entry the user changed, and skips a file it can't parse, reporting the problem instead of rewriting it:

   ```json
   "atrium-memory": {
     "command": "<app>/Contents/MacOS/atrium-memory",
     "args": ["mcp"],
     "env": {
       "ATRIUM_MEMORY_PATH": "<workspace>/MemoryVault",
       "ATRIUM_MEMORY_ACTOR": "<agent name>"
     }
   }
   ```

   Because the command points into the app bundle, moving the app would break it. An entry the app wrote (`args == ["mcp"]` and a command ending in `/atrium-memory`) whose command no longer exists gets the current bundled path. Any other entry is left alone.
3. **Approval.** Claude Code asks before using a server from a project `.mcp.json`, and background runs have no prompts. Once per agent, the app adds to `.claude/settings.local.json`:
   - `"atrium-memory"` to `enabledMcpjsonServers`;
   - `"mcp__atrium-memory"` to `permissions.allow`.
4. **Routines and Cockpit runs.** `RoutineRunner.arguments` adds `mcp__atrium-memory` to `--allowedTools` for connected agents, so scheduled and manual background runs can use the vault tools.
5. **Enforcement (tools are the only way to change the vault).** Once per agent, the app adds `Edit(/<vault>/**)` to `permissions.deny`. In Claude Code, Edit rules cover every built-in file-editing tool. For connected agents, the runner stops granting `Edit` on the vault folder and passes the same rule with `--disallowedTools`. Reading files and running the vault checker stay allowed, because `@` imports of Home and the framework load at conversation start. Shell commands could still write files; this rule stops accidental direct edits, not a determined agent.
6. **Instructions.** Once per agent, the app appends a `## Memory Vault tools` section (marker `<!-- claudedesk:memory-tool -->`) to `CLAUDE.md`. It says to use the `vault_*` tools, follow maps from Home with `vault_read`, pass back the `version`, and handle `stale_version`. The bundled vault template's framework note (used for new vaults) gets the same guidance. An existing vault's notes are never changed by the app.
7. **Projects.** Project sessions use the user's normal Claude profile, which the app does not edit. Settings › General offers "Copy MCP config": the same entry with actor `project`, for users to add themselves.
8. **Cockpit activity.** The flare also follows `<vault>/.atrium-memory/audit.jsonl`: `vault_read` lights the read note, and `vault_search` lights the returned IDs, labelled with the actor (the agent's name). The transcript scan stays as a fallback, so direct file reads and the `@` imports still show up. `docs/design/cockpit.md` gets a note about the new source.
9. **Migration.** The vault format does not change, so no data migration is needed. Existing agents are connected on the next launch.

## Testing

- **Core unit tests** (table-driven) in `internal/vault`: every confinement case (absolute path, `..`, symlink escape, dot-folder, non-`.md`), stale version on write, edit and append, create-exists, case-only collisions, NFC/NFD names, CRLF preservation, edit match counts, and search matching and ranking.
- **Concurrency test:** several goroutines and a second process append and edit the same note; no update is lost and no file is torn.
- **End-to-end test:** start `brainvault mcp` as a subprocess, connect with the Go SDK client over stdio, and exercise every tool, including error codes.
- **Conformance vaults:** `testdata/vaults/` holds sample vaults, including a copy of ClaudeDesk's `VaultTemplate`. `brainvault doctor` must pass on each.
- **CI** runs all tests on macOS, Windows and Linux.
- **ClaudeDesk side:** a check script, in the style of the existing `scripts/*-check.swift`, verifies `.mcp.json` wiring (adds the entry, leaves other servers alone, repairs a moved path, skips invalid JSON) and that the Cockpit reads the audit log.

## Distribution

- GoReleaser builds `darwin/arm64`, `darwin/amd64`, `windows/amd64`, `windows/arm64`, `linux/amd64` and `linux/arm64`, and publishes them on GitHub Releases with checksums.
- macOS binaries are signed and notarised in the release pipeline. Inside ClaudeDesk the binary is signed with the app.
- Homebrew and Scoop packages are optional later.

## Build order

1. `SPEC.md` and the core with its unit tests.
2. Locking and audit log.
3. The `mcp` adapter and end-to-end test.
4. CLI subcommands and `doctor`.
5. Release pipeline.
6. ClaudeDesk: bundle the binary, wire `.mcp.json`, update instructions, read the audit log in the Cockpit.
