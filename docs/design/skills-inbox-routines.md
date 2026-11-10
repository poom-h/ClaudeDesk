# Skills library, Inbox, routines, and activity log

Status: iteration 1 shipped in 3.4.0; iteration 2 (routines) built in 3.5.0 after the spike below.

ClaudeDesk gains a library that collects every skill in one place, an Inbox where agents send you non-urgent items, scheduled routines, and one activity log. Files on disk are the only record: the app reads and acts on them, and keeps no database of its own.

## Workspace layout

The Settings "Workspace folder" (shipped in 3.3.1) holds everything:

```text
<workspace>/
├── agent_brain/              # agents (existing)
│   └── <agent>/
│       ├── .claude/skills/   # symlinks to attached library skills
│       └── skills-proposed/  # skills the agent wrote, awaiting approval
├── MemoryVault/              # knowledge vault (existing)
├── skill_library/            # the collection: one folder per skill, each with SKILL.md
├── inbox/                    # one Markdown file per item
│   └── archive/              # resolved items, with their outcome recorded
├── routines/routines.md      # iteration 2: every routine, all agents (agents may edit)
├── .claudedesk/              # runner records agents can't reach: approved.json, state.json, queue/, runs/, runner.log
└── logs/                     # activity log, one JSONL file per month
```

## Skills library

- **Storage:** `skill_library/<name>/SKILL.md`, plus any supporting files.
- **Attach = symlink** (one true copy; detaching removes the link). Targets:
  - an agent: `<agent>/.claude/skills/<name>`
  - a project: `<repo>/.claude/skills/<name>`, with the app adding the path to the repo's `.gitignore`
  - Global: `~/.claude/skills/<name>`, which applies to normal sessions only, since agents have private profiles
- **No registry.** The app scans those folders to show what's attached, so a link deleted by hand shows as detached.
- **UI: a third sidebar mode, "Skills".**
  - Sidebar: the library list.
  - Main area: the `SKILL.md` editor (with stale-write protection, like the memory editor), "Reveal in Finder" for extra files, and "Attached to" checkboxes for Global, each agent and each project.
  - A "New skill" button, which creates a skill from a template.
- **Agent sidebar section:** each agent gets a Skills row listing its attached skills, with attach and detach controls.
- **Agent-written skills:**
  1. The agent writes `<agent>/skills-proposed/<name>/` and files a `skill` inbox item.
  2. On approval, the app checks the path stays inside the agent's folder, moves the skill into the library (refusing a taken name), and links it back to the agent.
  3. Agents never write to the library directly.
- **Live pickup:** symlinked skill folders load (verified 2026-10-22). Claude Code watches skill folders, so an attached skill should appear in an open conversation; `/reload-skills` is the fallback.

## Inbox

- **Placement:** a toolbar button with an unread badge, plus ⌘I. It opens in the main area; terminals keep running.
- **Items:** `inbox/<date>-<agent>-<slug>.md`. Properties:

```yaml
kind: skill | request | message        # iteration 2 adds routine | memory | alert
from: <agent id>
via: conversation | routine:<name>
session: <conversation or run id>
title: New skill "daily-news"
created: 2026-10-22T18:40
status: pending
skill: daily-news                      # kind-specific field
choices: [Approve, Reject]             # request only, optional
on_approve:
  - resume: "Approved and attached. Continue setting up the news routine."
on_reject:
  - resume: "Rejected: {reason}. Suggest an alternative."
```

  The body explains the item in Markdown. A file that won't parse is still listed as "Can't read this item", with its path.

- **Kinds:**

| Kind | Purpose | Actions | Iteration |
|---|---|---|---|
| skill | the agent wants a skill it wrote | Approve: into the library and attach · Reject | 1 |
| request | permission or a question; optional choices; typed reply | Approve / Reject / choice / reply | 1 |
| message | report or FYI (heartbeat, vault check, "finished X") | Done | 1 |
| routine | a new or flagged routine change | Approve: switch on · Reject | 2 |
| memory | a proposed memory edit | Approve: apply with the stale check · Reject | 2 |
| alert | routine failure or cap reached (written by the runner) | Done; shown at the top | 2 |
| draft | something for you to send yourself | (later) | — |

- **Discovery:** the app watches `inbox/` with file-change notifications and re-scans when the window becomes active.
- **Resolving an item:**
  1. Re-read the file. If it changed since you opened it, refresh and stop.
  2. Run the kind's built-in handler. On failure the item stays pending, the error is shown, and no callbacks run.
  3. Write the outcome into the file (`status`, `resolved`, reason or reply).
  4. Move the file to `inbox/archive/`.
  5. Run the callbacks you left ticked, in order. A callback failure is shown and noted in the archived file.
- **Callbacks:** a fixed set the app implements, shown before you click, each of which can be unticked. Nothing an agent writes can run code outside this set.
  - `resume: <message>`: opens the source conversation in a visible pane with `claude --resume <session> -- "<message>"`, which sends the message as the next turn (documented as `claude -r "<session>" "query"`).
  - `new-conversation: {agent, prompt}`: a fresh conversation in a visible pane.
  - `run-routine: <name>` (iteration 2): writes a request into `routines/queue/` for the runner.
  - `none`.
  - `{reason}` and `{reply}` are filled in from what you typed.
- **Routine-filed requests never block.** By default the next run reads your answer from `inbox/archive/`; `run-routine` or `resume` are used when the routine asks for them. If agents prove unreliable at checking the archive, the runner pastes answered requests into the prompt.
- **Agent access:** the app adds `<workspace>/inbox` (and in iteration 2 `<workspace>/routines.md`) to every agent's `additionalDirectories`, for new agents and as a one-time update for existing ones. Agents can read each other's items, which is acceptable because they aren't secret.
- **Agent instructions:** a library skill named `inbox-instructions`, attached to every agent, covers:
  - the item format, kinds and callbacks
  - `skills-proposed/`
  - never blocking, and checking the archive for answers
  - how to edit `routines.md`

  Each agent's `CLAUDE.md` gets one line pointing to it.

## Routines (iteration 2)

- **Definition:** one central `<workspace>/routines.md`, editable by you and by agents. Each routine has:
  - name and agent
  - schedule, in plain phrases: `daily 07:00`, `weekdays 08:30`, `every 6h`, `mondays 09:00`
  - prompt or skill
  - output location
  - optional limits
- **Runner:** a launchd job fires every 5 minutes, reads the file, and runs whatever is due, so it works with the app closed while the Mac is awake and catches up after sleep.
  - Each run is `claude -p` in the agent's folder, with the agent's private profile and a restricted permission profile: it can read and write the agent's folder and the vault, search the web, and run allow-listed commands such as `vault_check.py`; it can't delete, send, or run arbitrary shell commands.
- **Limits:** defaults of 30 turns and 15 minutes per run, and at most 20 runs a day across all routines. The runner enforces the time limit by stopping the process.
- **Approval rules:** the runner compares `routines.md` with `routines/approved` (its copy of the last version you approved). These changes pause the routine and file a `routine` item:
  - a new routine
  - a different agent
  - running more often than hourly
  - limits above the defaults
  - extra tools

  Prompt-text and time-of-day edits apply freely.
- **Outputs:** knowledge goes to the vault's `Inbox/`. Operational reports (heartbeat, vault check, failures) go to the workspace inbox as `message` or `alert` items.
- **First routines, all for Atlas:**
  - **Heartbeat, daily:**
    - run the vault checker and fix problems Atlas itself caused
    - propose memory updates and new skills through the Inbox, never applying them directly
    - write a "state of Atlas" message
  - **Vault maintenance, nightly:** run the checker, fix map and link problems, and report the rest. The framework note must be updated to allow this scope.
  - **News:** the system stays generic; a dedicated news agent comes later.
- **Spike results (2026-10-22), done in Atlas's real profile:**
  1. **Sign-in:** each agent's private profile is signed in (`claude auth status`: claude.ai, team), so `claude -p` runs unattended with no setup token.
  2. **Turn limit:** `--max-turns N` works with subscription auth. Hitting it exits with code 1 and `subtype: error_max_turns`.
  3. **Restricted profile** that works: `--permission-mode default --permission-prompts none`, `--tools` limiting the built-in tools, and `--allowedTools` listing only what may run, e.g. `Edit(//<abs path>/**)` (covers Write and Edit), `Read`, and exact `Bash(<command>)` entries. In the test, `rm`, arbitrary `python3 -c`, and writes outside the allowed paths were denied and reported in `permission_denials`.
  4. **Pitfalls:**
     - **Never use `acceptEdits`**: it auto-approved `rm` inside the working folder.
     - Absolute paths in permission rules need a leading `//`.
     - Variadic flags such as `--allowedTools` swallow the prompt, so always pass `--` before it.

## Activity log

- **File:** `<workspace>/logs/YYYY-MM.jsonl`. **Written by:** the app and the runner only, never agents.
- **Fields on every line:** `time`, `type`, `actor` (user, app, agent ID, or routine), `subject`, `outcome`, `details`.
- **Events:**

| Area | Events |
|---|---|
| Conversations | started, resumed, ended (exit status), callback-launched |
| Inbox | item created, approved, rejected, done, callback succeeded or failed, unreadable item found |
| Skills | created, edited, proposed, approved, attached, detached |
| Agents | created, settings or memory edited in the app |
| Workspace | set, migrated |
| Routines (iteration 2) | run started, finished, failed, timed out, cap reached, paused for approval |

- **What it records:** pointers (session IDs, paths, item IDs), never message contents, prompts, or note text.
- **Retention:** kept indefinitely; the future dashboard reads it ("show, don't store").

## Iteration 1 scope

1. Skills mode: library list, editor, "Attached to" (Global, agents, projects), New skill
2. Skills row in each agent's sidebar section
3. Skill proposals from `<agent>/skills-proposed/`
4. Inbox: toolbar button, badge and ⌘I; `skill`, `request` and `message` kinds; archive; `resume`, `new-conversation` and `none` callbacks
5. `inbox-instructions` library skill, plus the one-time update for existing agents (`additionalDirectories` and the `CLAUDE.md` line)
6. Activity log for conversations, inbox, skills, agents and workspace
7. `Workspace.prepare` creates `inbox/`, `inbox/archive/` and `logs/`

Iteration 2: the spike, routines, the runner, the restricted profile, heartbeat, `run-routine`, the `routine`, `memory` and `alert` kinds, and routine log events.

Out of scope: the dashboard / agentic OS, a phone channel, an always-on server, `draft` items.

## Decision record

Q1 the workspace folder holds agent_brain, MemoryVault and skill_library (built) · Q2 symlinks · Q3 projects too, with .gitignore · Q4 agent skills need approval · Q5 launchd · Q6 one central routines.md · Q7 heartbeat proposes, never applies · Q8 restricted profile · Q9 results in the vault Inbox; dashboard later · Q10 library first · Q11 proposals in the agent's own folder · Q12 symlinks are the record · Q13 Skills mode plus per-agent assignment · Q14 built-in editor · Q15 Global attach · Q16 agents edit routines, with important changes flagged · Q17 plain schedule phrases · Q18 limits · Q19 nightly checker plus map and link fixes · Q20 news agent later · Q21 Skills mode layout · Q22 Inbox in the toolbar with ⌘I · Q23 one shared workspace inbox with an archive · Q24 callbacks · Q25 approval rules for routine changes · Q26/Q33 one monthly activity log · Q27 iteration 1 scope · Q28 agent access to inbox and routines.md · Q29 inbox-instructions skill · Q30 knowledge to the vault, operations to the inbox · Q31 kinds · Q32 routine requests never block · Q34 only the app and runner write the log; pointers only · Q35 keep logs; start in iteration 1
