# ClaudeDesk

A native macOS workspace with two modes: repository development and persistent agents. Both run multiple Claude Code instances inside the app.

## Run

Requires macOS 14 or newer and Claude Code installed and signed in.

```sh
bash scripts/build-app.sh
open dist/ClaudeDesk.app
```

Drag `dist/ClaudeDesk.app` into Applications to install. The local build is ad-hoc signed; distributing to other Macs requires Developer ID signing and notarization.

## Projects mode

1. Add a project folder (⌘N).
2. Create named session shortcuts such as Frontend, Tests, and Review, with optional starting prompts.
3. Choose **Open Claude** or **Open all**. Each launch starts an independent, interactive Claude process inside the app, including repeated launches of the same shortcut.
4. In **Live workspace**, choose Grid, Columns, or Rows. Pane sizes adapt to the window; larger collections scroll so terminals remain usable.
5. Drag a pane's title onto another pane to reorder it, or use its left/right arrows. Use the expand button to focus one terminal and **Show all** to return.
6. Return to **Session library** to launch more instances. Existing processes and terminal contents stay alive while switching views and projects.
7. Close a pane to stop its process. Running instances require confirmation. Quitting the app stops running sessions without asking; conversations are saved and can be continued later. Closing the main window hides it without ending sessions; reopen it from the Window menu or Dock.

Click inside a terminal to type. Normal CLI controls, keyboard input, colors, scrolling, selection, copy/paste, and terminal resizing are handled by SwiftTerm. No Terminal.app or Automation permission is required.

The session menu lets you edit, duplicate, or remove saved shortcuts. Right-click a project to reveal its folder or remove it. Settings (⌘,) accepts a custom Claude executable path.

Each launch starts a new conversation. Use Claude's own `/resume` command to return to an earlier conversation. Live processes are not restored after quitting. Multiple instances in one project share its files; ClaudeDesk does not create separate Git worktrees. Existing Claude settings, authentication, permissions, and hooks apply normally.

Projects and shortcuts are saved locally at `~/Library/Application Support/ClaudeDesk/projects.json`. Layout choice is saved in app preferences. ClaudeDesk does not store credentials.

## Agents mode

1. Switch to **Agents** and open **Set up agent storage** (or Settings → Agent host folder).
2. Choose a host folder once. The app remembers it as the default for new agents. Changing it later does not move existing agents.
3. Choose **Create agent**, enter a name and purpose, and create the environment.
4. Choose **New conversation** to talk to the agent. The **Talk to agent** menu also offers Continue latest and a past-conversation picker.
5. Edit **Instructions**, **Memory**, **MCP servers**, **Settings**, or **Local overrides** inside the app. Save and start a new conversation to load the changes.
6. Use the plugin controls to add a marketplace, install, list, enable, or disable plugins in that agent's environment. Commands and interactive prompts appear in a terminal pane. Installation is never silently auto-approved.

Each agent gets a unique directory under the chosen host, even when names match:

```text
host/agent-name-uuid/
├── agent.json                 # Agent identity
├── CLAUDE.md                  # Role, instructions, memory import
├── memory/MEMORY.md           # Durable memory index; topic files go beside it
├── files/                    # Agent work and artifacts
├── .mcp.json                  # Agent-scoped MCP server definitions
├── .claude/settings.local.json
├── .claude/skills/
├── .claude/agents/
└── .runtime/                  # Private Claude profile, history, plugins, state
    └── settings.json          # Includes this agent's auto-memory directory
```

Agent processes receive `CLAUDE_CONFIG_DIR=<agent>/.runtime` and `CLAUDE_CODE_PROJECT_DIR_NAME=agent`. The app's Settings editor edits that private profile's settings; plugin commands use local scope and the same private profile. Claude may require a fresh sign-in or workspace trust step. Existing account credentials are not copied into an agent environment. Organization policy and inherited provider environment variables can still apply.

The environment is a dedicated working directory, **not a filesystem security sandbox**. Normal Claude permissions apply. Conversations for one agent share its files and memory, and continue running when switching modes. Separate agents have separate directories and private profiles. Projects mode continues using the normal Claude profile.

The memory editor checks the on-disk file before saving and rejects stale writes if Claude changed it. JSON editors validate object structure; Claude performs its own settings and MCP validation. A missing or unreadable file is reported rather than replaced silently. Configuration changes do not restart running sessions.

The agent registry is saved at `~/Library/Application Support/ClaudeDesk/agents.json`. The selected host path is stored in app preferences. Normal project records are preserved and old records migrate without requiring an agent identifier.

Configuration behavior follows the official [Claude settings documentation](https://code.claude.com/docs/en/settings) and [memory documentation](https://code.claude.com/docs/en/memory).

## Development and verification

Building needs the Xcode command line tools and Go. The bundled atrium-memory is built from a checkout at `../brainvault` (or `ATRIUM_MEMORY_SRC`); without one, the pinned release in `Resources/atrium-memory.version` is downloaded from GitHub and checked against its checksums.

```sh
bash scripts/build-app.sh
bash scripts/test.sh
bash scripts/test-terminals.sh
bash scripts/test-agents.sh
bash scripts/test-agent-runtime.sh
bash scripts/test-memory-tool.sh
```

The build uses `swiftc` directly and the vendored SwiftTerm v1.13.0 library, with no runtime downloads. A local compiler-only overlay handles duplicate SwiftBridging headers in some Command Line Tools installations without modifying installed tools. The standard Swift package is also provided for healthy Xcode installations.

Standalone checks cover shell argument quoting and project encoding. Integration checks exercise two concurrent real pseudo-terminals, independent input/output, terminal sizing, natural exit, sibling survival, and termination. UI checks verified two Claude instances inside the app, layout changes, and focus mode.

Agent checks cover unique environments, memory/config separation, old-project decoding, JSON validation, stale-edit protection, and symlink containment. Runtime checks use the actual embedded terminal launcher with two disposable agent environments to verify working directories, configuration routing, independent writes/input, and process cleanup without signing into Claude or installing plugins.

SwiftTerm is MIT licensed. Its license is included in the app's Resources folder and `Vendor/SwiftTerm/LICENSE`.

## Terminal workspace appearance and layouts

Choose **Theme** in the top bar for Claude Dark (warm charcoal/terracotta), Warm Light (cream/ink), or Midnight (graphite/amber). Theme and terminal font size are remembered. Claude's own explicit ANSI colors still follow its CLI theme; use its `/theme` command if those need matching.

Drag a pane header onto another pane's edge to split there, or into its center to swap positions. A tinted preview shows the destination. Drag the dividers to adjust proportions. **Snap layout** offers Balanced, Columns, Rows, and Main + stack presets. Compact workspaces scroll when panes reach their minimum readable size. Layouts stay intact while switching between the library and live workspace; running processes are retained. Layouts are in memory for the current app run.

Double-click a header to focus that pane; repeat to return. The Workspace menu also provides:

- Command–1 / Command–2: switch to the Cockpit / the Studio.
- Control–1 through Control–9: select a session.
- Command–Option–Left/Right: previous/next session.
- Command–Shift–Return: toggle focus.
- Command–Shift–0: reset to the balanced layout.

The text-size menu adjusts all terminal panes. Pane menus provide snap actions as an alternative to dragging. These are layouts inside the ClaudeDesk window.

`bash scripts/test-layout.sh` verifies geometry, docking, swaps, removal, reconciliation and resize bounds for 1–12 panes.

Version 3.1.1 fixes pane dragging by using native macOS mouse tracking on headers and divider hit areas. UI verification exercised edge docking, center swapping, and divider resizing with three live disposable terminals.

## Version 3.2

Appearance is in Settings; terminal fonts range from 6–32 pt. The sidebar stays beside the terminal workspace; use the native sidebar button to hide it when you need more room. Each live session has a colored Claude-style sunburst in its header and session tab.

The puzzle-piece button opens Plugins & MCP. Select the normal global Claude profile, a project, or an agent. Project and agent operations use local scope; agents also receive their private configuration environment. Global installations apply to normal project sessions, not isolated agents. CLI commands run visibly with ordinary confirmation prompts. MCP accepts a single server JSON object with a command or URL. Marketplace declarations use the selected scope too. Restart conversations after configuration changes.

Each terminal's paperclip opens a file picker and inserts quoted absolute paths into its draft using bracketed paste. It does not upload file bytes or send the prompt; Claude reads supported files when you submit and grant any required permissions.

Mouse wheel events are now forwarded to TUIs that enable mouse tracking. Hold Shift to scroll terminal history instead. The vendored SwiftTerm changes add wheel reporting and a clipboard-independent pasteText API.

Validation for 3.2: scoped MCP registration was exercised with the installed Claude CLI in disposable profiles (`scripts/test-integration-scopes.sh`). UI checks verified 6 pt selection, integration scope choices, native file selection, bracketed paste without Enter, and SGR wheel input reaching a foreground terminal program. No third-party plugins were installed as part of testing. Scope semantics follow [Claude MCP documentation](https://code.claude.com/docs/en/mcp).

## Version 3.3 · Persistent workspace

Projects/Agents navigation, saved session shortcuts, new/resume conversation actions, and live session selection now live in one resizable sidebar. Selecting another project or agent does not replace the terminal canvas. Each mode retains its own running terminals and layout. Memory and configuration editors open as sheets; Plugins & MCP defaults to the selected environment, with global scope still available in its picker. The old full-page agent/project dashboards are no longer part of navigation.

## Version 3.4 · Workspace, skill library, and Inbox

Settings now has a **Workspace folder**. ClaudeDesk keeps agents in `agent_brain/`, the memory vault in `MemoryVault/` (new vaults start from a bundled framework), skills in `skill_library/`, Inbox items in `inbox/`, and the activity log in `logs/`. Missing folders are created; existing ones are never changed. Older setups are asked once whether to migrate.

**Skills** is a third sidebar mode. It lists every skill in the library, edits its `SKILL.md`, and attaches it to Global (`~/.claude/skills`), agents, or projects by symlink, so one copy serves everywhere. Project links are added to the repository's `.gitignore`. Each agent's sidebar has a Skills menu for quick attach and detach.

The **Inbox** (toolbar tray, ⌘I) collects non-urgent items from agents: `request` (permission or a question, with optional choices and a typed reply), `message` (reports), and `skill` (a skill the agent wrote in its own `skills-proposed/` folder). Approving a skill moves it into the library and attaches it to that agent. Items can carry callbacks, shown before you decide and individually switchable: reopen the source conversation with a message, or start a new conversation. Resolved items move to `inbox/archive/` with the outcome recorded. Agents are connected once: the Inbox folder is added to their allowed directories, their `CLAUDE.md` gains an Inbox section, and the bundled `inbox-instructions` skill is attached.

The activity log (`logs/YYYY-MM.jsonl`) records conversations, Inbox decisions, skill changes, agent creation and edits, and workspace changes as pointers only, never message content.

`bash scripts/test-skills.sh` covers front matter parsing, library editing and attachment, conflicts, `.gitignore` entries, proposal approval with symlink containment, Inbox wiring, item parsing, stale-safe archiving, and the log. Design and the planned routines iteration: `docs/design/skills-inbox-routines.md`.

## Version 3.5 · Routines

Scheduled work for agents is defined in `<workspace>/routines/routines.md`: one `##` section per routine with `agent`, `schedule` (`daily 08:30`, `weekdays 08:30`, `mondays 09:00`, `every 6h`, `hourly`), optional `skill`, `max_turns`, `timeout`, `enabled`, `tools: web-fetch`, `output`, then the prompt. Agents can edit the file. A new routine, or one changed to a different agent, more often than hourly, above the default limits (30 turns, 15 minutes), or with extra tools, pauses and asks for approval in the Inbox. Prompt and time-of-day edits apply immediately.

**Run routines in the background** (Settings or the clock button's Routines sheet) installs a LaunchAgent that runs `claudedesk-runner` every 5 minutes while the Mac is awake; it is off by default. Missed times run once after waking. Each run is `claude -p` in the agent's folder with its private profile, in the default permission mode with prompts disabled. Only reading, searching, `WebSearch`, skills, edits inside the agent's folder and its allowed directories, and the vault checker are allowed. `WebFetch` requires `tools: web-fetch`. Runs are capped at 20 a day. For agents connected to atrium-memory, the vault folder is the exception: runs get the `mcp__atrium-memory` tools there instead of `Edit`, and `--disallowedTools` blocks direct edits. Approvals, state, the queue, run outputs, and the runner log live in `<workspace>/.claudedesk/`, outside agents' reach.

The Inbox adds `routine` (approve to switch a routine on), `memory` (append proposed text to an agent's `MEMORY.md`), and `alert` (failures, limits, invalid routines; shown first) items, plus a `run-routine` callback. Notifications appear only when a run fails, hits a limit, or files an inbox item.

`bash scripts/test-routines.sh` uses a fake `claude` to cover schedules and catch-up, parsing, approval rules, restricted arguments, queueing, timeouts, turn limits, the daily cap, and logging. The restricted profile was verified against the real CLI: `rm`, arbitrary commands, and writes outside allowed folders are denied. `acceptEdits` mode is deliberately not used because it permits `rm`.

## Version 3.6 · Cockpit

ClaudeDesk opens in the **Cockpit**, a full-window overview. Click the app title to switch between the Cockpit ("ClaudeDesk OS") and the **Studio** (Projects, Agents, Skills). The first Cockpit theme, Futuristic space, draws a slow starfield with the Memory Vault as constellations: Home, maps, and notes are stars and wikilinks are lines. A note pulses when it changes. **Explore memory** brings the constellations forward; hover a star for its title and click to open it in Obsidian. Reduce motion is in the Cockpit menu and follows the macOS setting.

Everything else is a widget on a snap grid. Add widgets from **Add widget**, drag them to reorder, and change size or settings from each widget's menu. The layout is saved in `<workspace>/.claudedesk/cockpit.json`. Widgets:
- **Activity**: what each agent is doing, its latest action, live run steps with Stop, and recent results
- **Inbox**: one-click Done and Approve
- **News**: the latest Inbox message with a given `topic`
- **Routines**: today's timeline
- **Token usage**: from every saved transcript, by source, with output tokens and an API-equivalent estimate from sessions with cost data
- **Plan limits**: 5-hour and 7-day usage with reset times
- **Skill shortcuts** and **Quick capture**: start background runs immediately, with no approval or daily cap
- **Agents**, **Vault health**, and **Today**

Background runs from the Cockpit go through `claudedesk-runner --run-request`, using the routines' restricted profile and streaming output. Plan limits are collected by a status line that ClaudeDesk adds once to your normal Claude profile and each agent's profile, never over an existing one. It records `rate_limits` and session cost in `<workspace>/.claudedesk/usage/` and shows `model · ctx · 5h · 7d` in each terminal.

`bash scripts/test-cockpit.sh` covers the layout, vault graph, usage counting, the status line, steps, a streamed manual run, the cap exemption, logging, and Stop. Design: `docs/design/cockpit.md`.

## Version 3.7 · Agent widgets

Agents now design their own Cockpit widgets. Each widget is a Markdown file in the agent's own folder, `<agent>/widgets/<name>.md`, with images in `widgets/assets/`. The card part shows on the Cockpit, and everything after `<!-- full -->` shows only in focus mode. A new widget appears in **+ WIDGET** under "From agents" (the label gets a dot) for you to place, and edits show within a few seconds.

Widgets can use full Markdown (headings, lists, quotes, tables, code, dividers, images) plus interactive and data blocks written as fenced blocks: **button** and **input** start a background run of that agent with the widget's instruction (the click is the approval; same restricted profile as shortcuts), **checklist** items can be ticked, and **stat**, **gauge** and **chart** show numbers. Hovering a button shows what it will ask the agent to do. Agents learn the format from the bundled `widget-instructions` skill and a "Cockpit widgets" section added once to each agent's CLAUDE.md.

The same renderer now shows Inbox items and focus mode. Images load from `https` or from paths inside the item's folder only; resolving an Inbox item moves its relative images into the archive with it. The built-in News widget is retired: saved News widgets become AI Scout's `news` widget in the same place.

`bash scripts/test-cockpit.sh` also covers Markdown blocks, image safety, widget files, checklist ticks, and archived images. Design: `docs/design/cockpit.md` (Revision: agent widgets).

The Routines widget now shows today's runs as they happened, including manual ones, live progress with Stop, routines that need you, and the next run; focus mode lists 7 days of runs with totals. Run now can't queue a routine twice and shows Starting…, Running… and the result. Widgets that grow into each other no longer overlap.

Widgets have one global size (75–150%, **− / +** in the strip or ⌘− / ⌘+); widgets with no room open at that size collapse to their title row, and the strip shows how many. **+ WIDGET** opens a gallery with a live preview and description of every widget.

The Cockpit keeps the memory graph alone in the middle; widgets sit in a scrolling column on each side. Drag a widget's header to reorder it or move it to the other side (or use Move up, Move down, and Move to the other side in its menu). Quick capture was removed.

When an agent reads or searches a vault note, its star in the Cockpit's memory graph lights up for a few seconds with the note's title and the agent's name.

**Quick search** (⌘F) searches the vault from the Cockpit: a sonar sweep pings every match on the graph, the rest fade, and the camera glides to the selected note with a targeting reticle. ↑ / ↓ steps through results, Return opens the note in Obsidian, Esc clears.

Clicking a star or opening a search result shows the note in the built-in viewer, with wikilinks you can follow, backlinks, and Open in Obsidian. The search box stays hidden until you press Return (or ⌘F).

The memory graph has three views, switched with **2D / 3D / ORBIT** in the strip: the flat constellation, a 3D sphere you can drag to turn, and orbits where maps circle Home and notes circle their maps. Switching morphs every star to its new place.

**Shift+Return** in the Cockpit opens an Ask bar to talk to Atlas (or another agent): it answers as a background run, with live steps and the notes it reads lighting up on the graph, and Continue in Studio reopens the session as a full conversation.

The Studio has a new **Space** look matching the Cockpit (starfield, glass sidebar, the same status strip). It's the default; the older themes stay in Settings.

**Google mail and calendar** (read-only, several accounts) connect in Settings › Integrations. **Jev** (TypeSafe) sorts each email into a category and flags urgent, needs-reply and suspicious mail; the **Mail** and **Schedule** widgets show the result, and Atlas uses it when you ask about your day. Keys and sign-ins live in the macOS Keychain. The agents' Inbox is now called the **Desk**.

By default mail and calendar come from **this Mac** (Apple Mail and macOS calendars, so your Gmail stays connected with no Google setup); the Google API remains an advanced option.

## Version 3.8 · Memory Vault tools

Agents now reach the Memory Vault through **atrium-memory**, an MCP server built into ClaudeDesk (`Contents/MacOS/atrium-memory`; source: github.com/poom-h/atrium-memory). On launch, every agent gets it in its `.mcp.json`, approved in its local settings, and granted to routines and Cockpit runs, and a "Memory Vault tools" section in its CLAUDE.md. Agents search and follow maps with `vault_search` and `vault_read`, and change notes with `vault_edit`, `vault_append` and `vault_write`. Edits and whole-note replacements are checked against the version the agent last read (creating a note or appending doesn't need one); every change is written all at once and logged to `MemoryVault/.atrium-memory/audit.jsonl` without note content.

Claude's file-editing tools are blocked inside the vault for agents (an `Edit` deny rule), so they change it through the vault tools; reading files and running the vault checker still work. Shell commands and scripts could still write files, so this is a guardrail, not a lock. Moving or reinstalling ClaudeDesk.app is fine: each launch points every agent's entry at the running app's copy, and changing the workspace moves agents to the new vault (with their edit rule and instructions). Your own entries and other servers are never changed. To use the same tools in your own Claude sessions, Settings › General › Copy MCP config.

The Cockpit's memory flare now follows the audit log, labelled with the agent's name, with the transcript scan kept as a fallback.

`bash scripts/test-memory-tool.sh` covers the server entry (add, keep, repair after a move, user entries, invalid files), settings and instructions, runner arguments and the audit flare.
