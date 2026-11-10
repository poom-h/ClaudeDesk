# ClaudeDesk

A macOS app for running and supervising Claude Code agents and project sessions, with a shared knowledge vault, a skill library, an approval inbox, and scheduled routines.

## Places

**Workspace folder**:
The folder that holds everything ClaudeDesk manages: agents, the Memory Vault, the skill library, the Inbox, routines, and logs.
_Avoid_: Agent host folder, root

**Cockpit**:
The everyday overview screen that brings together the state of the agents, Inbox, routines, news, usage, and memory.
_Avoid_: OS, OS mode, dashboard, home, Workspace

**Studio**:
The screen for working directly with projects, agents, and skills.
_Avoid_: Workspace, main view, editor mode

**Widget**:
One self-contained element of the Cockpit, such as routines or token usage, that the user can add, move, resize, and configure.
_Avoid_: Panel, card, tile

**Agent widget**:
A widget an agent designs itself as a Markdown file in its own `widgets/` folder. The app draws the frame; the agent writes the content, including buttons that start a background run of that agent.
_Avoid_: Custom widget, plugin

**Widget block**:
An interactive or data element inside an agent widget, written as a fenced block: button, input, stat, gauge, or chart.
_Avoid_: Component, control

**Cockpit theme**:
A complete look for the Cockpit (its background, how memory is drawn, and how widgets are styled), chosen independently of the app theme.
_Avoid_: Skin, wallpaper, app theme

**Activity**:
The live picture of what each agent is doing right now, across its conversations and runs.
_Avoid_: Status, monitor, feed

## Actors

**Agent**:
A persistent Claude assistant with its own folder, instructions, memory, and private Claude profile.
_Avoid_: Bot, assistant profile

**Project**:
A code folder where you run ordinary Claude sessions with your normal Claude profile.
_Avoid_: Repo, workspace

## Knowledge

**Memory Vault**:
The shared Obsidian vault of durable knowledge that agents maintain.
_Avoid_: Second brain, vault notes store

**Agent memory**:
An agent's private working notes about preferences and context, kept in its own folder rather than the Memory Vault.
_Avoid_: Vault, knowledge

## Work

**Conversation**:
An interactive Claude session with an agent or in a project, which can be resumed later.
_Avoid_: Chat, instance, session pane

**Routine**:
A scheduled, unattended task an agent performs, defined in `routines.md`.
_Avoid_: Cron job, task, automation

**Run**:
One unattended execution of a routine or skill shortcut, with its own ID and result.
_Avoid_: Job, execution

**Library skill**:
A skill stored once in the skill library and attached to agents, projects, or Global by link.
_Avoid_: Plugin skill, local skill

**Skill shortcut**:
A Cockpit button that starts an unattended run of one library skill with one agent.
_Avoid_: Quick action, macro

## Usage

**Token usage**:
The tokens Claude processed across conversations and runs, with an API-equivalent cost estimate.
_Avoid_: Spend, bill, credits

**Plan limits**:
How much of the Claude subscription's 5-hour and 7-day usage windows has been used, and when each resets.
_Avoid_: Session limit, quota, rate limit

## Inbox

**Inbox**:
The shared place where agents and the runner send items that need the user's attention.
_Avoid_: Approvals, notifications, queue

**Inbox item**:
One message, request, skill proposal, routine approval, memory proposal, or alert waiting in the Inbox.
_Avoid_: Ticket, notification

**Callback**:
A follow-up action an inbox item asks for after the user decides, such as reopening its conversation.
_Avoid_: Hook, trigger
