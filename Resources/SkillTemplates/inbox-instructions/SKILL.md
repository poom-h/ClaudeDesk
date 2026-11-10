---
name: inbox-instructions
description: Send the user a non-urgent item through the ClaudeDesk Inbox, such as a permission request, a question, a report, or a proposed new skill. Use when you need a decision that can wait, want to report finished work, or have written a skill you want added to your toolkit.
---

# ClaudeDesk Inbox

The user reviews these items in ClaudeDesk when convenient. Use the Inbox for things that can wait. If the user is in the conversation and the matter is quick, just ask them directly.

The Inbox folder's path is in the "Inbox" section of your CLAUDE.md. Write each item as a new Markdown file in that folder. Never edit or delete other items, and never touch `archive/` except to read it.

## Writing an item

File name: `<YYYY-MM-DD>-<your agent folder name>-<short-slug>.md`, for example `2026-10-23-atlas-dc6273fd-archive-duplicates.md`.

```markdown
---
kind: request
from: <your agent folder name, the last part of your working directory>
via: conversation
session: ${CLAUDE_SESSION_ID}
title: Archive 5 duplicate AWS notes?
created: <current local time as YYYY-MM-DDTHH:MM>
status: pending
choices: [Archive all, Keep them]
on_approve:
  - resume: "The user chose: {choice} {reply}. Continue."
on_reject:
  - resume: "The user declined: {reason}"
---

Explain what you want and why, what happens if approved, and anything the user should check.
```

Rules:
- `from` must be your agent folder name.
- `session`: keep `${CLAUDE_SESSION_ID}` exactly as shown when writing from a conversation. In a scheduled routine run, use the run ID you were given and set `via: routine:<routine name>`.
- `title` is one line the user can decide on. Put the details in the body.
- `topic` (optional) labels a recurring report, such as `topic: news` for a news digest. The ClaudeDesk Cockpit shows the latest item for each topic in its widgets.
- Quote any value that contains a colon.

## Kinds

| kind | Use for | Extra properties |
|---|---|---|
| `request` | Permission to do something, or a question. The user approves, rejects, picks one of your `choices`, or types a reply. | `choices` (optional) |
| `message` | Reports and FYIs, such as "finished X", findings, or a status report. Nothing to decide. | none |
| `skill` | A skill you wrote and want added to the library and attached to you. | `skill: <name>` |
| `memory` | Something worth adding to your `memory/MEMORY.md`. Put the exact text to append in a fenced block that starts with ```` ```memory ````. Approval appends it under a dated heading. | none |

Use `memory` only for additions. To change or remove existing memory, file a `request` describing the change. ClaudeDesk itself files `routine` and `alert` items; don't write those.

## Callbacks: what happens after the user decides

`on_approve` runs after an approval, a choice, or a reply. `on_reject` runs after a rejection. Each entry is one of:

- `resume: "<message>"`: reopens this conversation (from `session`) and sends the message, so you carry on where you left off.
- `new-conversation: "<prompt>"`: starts a fresh conversation with you, using the prompt.
- `none`: nothing.

Inside messages, `{reason}` becomes the user's rejection reason, `{reply}` their typed reply, and `{choice}` the choice they picked. The user sees every callback before deciding and can switch any of them off, so make them clear. Omit callbacks for `message` items.

## Proposing a new skill

1. Write the skill to `skills-proposed/<name>/SKILL.md` inside your own agent folder. Use a lowercase, hyphenated name. Start the file with front matter giving `name` and a `description` that says when to use the skill.
2. File a `skill` item with `skill: <name>`, explaining what the skill does and why you need it.
3. Don't use the skill until it's approved. Once approved it appears in your skills; if it doesn't show up, run `/reload-skills`.

## Scheduled routines

Routines for every agent live in the `routines.md` file named in your CLAUDE.md. Add or change a routine only when the user asks for one, or propose it through a `request` first. Each routine is a `##` section: property lines, a blank line, then the prompt.

```markdown
## heartbeat
- agent: <your agent folder name>
- schedule: daily 08:30
- skill: heartbeat

Run your heartbeat routine for today.
```

- `schedule`: `daily HH:MM`, `weekdays HH:MM`, `mondays HH:MM` (any weekday), `every 6h`, `every 30m`, or `hourly`.
- Optional: `skill`, `max_turns` (default 30), `timeout` (default 15m), `enabled: no`, `tools: web-fetch`, `output`.
- Routine names use lowercase letters, numbers, and hyphens. Edit only your own routines and keep other sections intact.

A new routine, or one changed to a different agent, more often than hourly, above the default limits, or with extra tools, waits for the user's approval in the Inbox. Changing only the prompt or the time of day applies right away.

In a routine run nobody is watching. The run's first message gives its routine name and run ID: use them as `via: routine:<name>` and `session: <run ID>` in inbox items. Answers to that routine's earlier requests are included in the same message.

## Never block on the Inbox

After filing an item, continue with whatever else you can do, or finish. Don't wait or poll for an answer. Resolved items move to `archive/`, with `status`, `decision`, and any `reason` or `reply` recorded. When a later conversation or run depends on an earlier request, read your own items in `archive/` for the answer.
