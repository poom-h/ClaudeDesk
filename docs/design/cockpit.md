# Cockpit

Status: first version built in 3.6.0 (2026-10-24). Terms follow [GLOSSARY.md](../../GLOSSARY.md).

The Cockpit is the everyday overview screen: what every agent is doing, what's waiting, today's news, usage and plan limits, routines, and the Memory Vault drawn as constellations behind it all. The **Studio** (Projects, Agents, Skills) stays the place for hands-on work.

## Navigation

- **Two modes:** the Cockpit and the Studio. Click the app title to switch; it reads **ClaudeDesk OS** in the Cockpit and **ClaudeDesk** in the Studio.
- **The Cockpit fills the window.** The sidebar is hidden; the title switch stays at the top left.
- **Launch:** the app opens in the Cockpit by default, remembering the last mode used.
- **Rule:** the Cockpit only reads what already exists ("show, don't store"). It writes nothing of its own except its layout and shortcuts.

## Cockpit theme

- The Cockpit has its **own theme**, independent of the app theme, which still applies to the Studio.
- **First version: one code theme, "Futuristic space":**
  - a deep-space background with a slow starfield
  - the Memory Vault drawn as **constellations**
  - widgets as translucent glass
- **Built behind a theme interface** from day one. A theme provides the background renderer, the memory renderer, widget styling, and a set of adjustable settings (colours, glass strength, star density, motion).
- **Later:** theme variations as folders, `<workspace>/cockpit-themes/<name>/theme.json`, overriding a code theme's settings without a rebuild.
- **Motion:** a "reduce motion" switch stops all drifting and pulsing; the macOS Reduce Motion setting does the same.
- **Built with** native SwiftUI, drawing the graph in a Canvas with a small force layout. A web view (d3 or three.js) is worth revisiting only if the vault reaches thousands of notes or a 3D view is wanted.

## Memory constellations

- **Source:** the Memory Vault. Home is the central star, maps are bright stars, notes are small stars, and wikilinks are the constellation lines. Agent memory is not shown.
- **Live feedback:**
  - when a vault note changes, its star pulses
  - new notes fade in as new stars
  - the vault is watched like the Inbox
- **Explore memory** brings the constellations to the front: hover a star for its title, click it to open the note in Obsidian.

## Widgets

Every element is a **widget** on a snap grid:
- **Add:** the **Add widget** picker.
- **Move:** drag it.
- **Resize:** step through small, medium, wide and large.
- **Remove:** from its menu.
- **Configure:** each widget has its own settings popover, and some widgets can be added more than once.
- **Saved:** the layout is stored in `<workspace>/.claudedesk/cockpit.json`.

| Widget | Shows | Settings |
|---|---|---|
| **Activity** | One row per agent: in a conversation (duration plus its latest action from the transcript), running a routine or shortcut (live steps, elapsed time, **Stop**), waiting (has Inbox items), or idle (last active). Finished runs stay for a few minutes with their result. Project panes are grouped below. Clicking a row jumps to that pane or run. | – |
| **Inbox** | Top waiting items. One-click **Done** for messages and alerts, and **Approve** for routine items. Anything else opens the full Inbox. | how many items |
| ~~News~~ | Retired in 3.7: replaced by AI Scout's own agent widget (see Revision: agent widgets) | – |
| **Routines** | Today's runs as they happened, scheduled and manual (from the activity log), what's running or queued, what's still due, routines that need you, and the next run; focus mode shows today or 7 days of runs with totals | – |
| **Token usage** | Totals for today, 7 days and 30 days, broken down by source (each agent, ClaudeDesk projects, other Claude Code), with an API-equivalent cost estimate | range |
| **Plan limits** | 5-hour and 7-day usage as gauges with reset times, the snapshot's age, and a warning colour above 80% | – |
| **Skill shortcut** | One button (or a bar of several) that starts a background run | skill, agent, instruction, web-fetch |
| **Quick capture** | A text bar that sends a request to an agent as a background run | default agent (Atlas) |
| **Agents** | Each agent's state, attached skills, and last heartbeat, with **Talk** to open a conversation | – |
| **Vault health** | Note and map counts, what's new today, and the vault checker's status | – |
| **Today** | Date, Inbox count, and the next routine | – |

## Background runs from the Cockpit

- **Skill shortcuts and quick capture** both start **runs** through the existing runner. The app writes a queue request and wakes the runner (`launchctl kickstart`), so a run starts within seconds and keeps going if the window closes.
- **Same safeguards as routines:** restricted profile, turn and time limits, logging, and alerts on failure.
- **Differences from routines:**
  - no Inbox approval, because clicking *is* the approval
  - no daily cap, because the 20-a-day cap is for routines only
- **Live steps:** runs use streaming JSON output, so Activity can show each step as it happens.
- **Stop** ends the run.
- **Shortcuts** are defined in the Cockpit (**Add shortcut**: library skill, agent, optional instruction, optional web-fetch). They're stored in `cockpit.json`, where agents can't change them.

## News

- News is any Inbox `message` item with a `topic` property; the News widget shows the latest item for its topic.
- AI Scout's routine prompt adds `topic: news`, and the `inbox-instructions` skill documents the property.

## Token usage and plan limits

- **Token usage:** read from every saved transcript on the Mac (your normal Claude profile and each agent profile) plus run outputs. Each message records input, output and cache tokens, and each run records an API-equivalent cost. Sources are matched by profile, and by the session IDs the activity log records.
- **Plan limits:** these only reach Claude Code through the status line (`rate_limits.five_hour` and `seven_day`, verified on this account 2026-10-24: 24% and 33%).
  - **Collection:** ClaudeDesk installs a small status line in each managed profile (normal plus each agent's). It saves the latest snapshot to `<workspace>/.claudedesk/usage/latest.json` and prints a compact line in the terminal, for example `Opus 5.5 · ctx 12% · 5h 24% · 7d 33%`.
  - **Existing status lines:** a status line the user configured is never replaced. If one is added later, ClaudeDesk only saves the snapshot.
  - **Freshness:** the snapshot updates only while a session or run is active, so the widget shows its age and the reset times.

## First version scope

1. The mode switch (title toggle, full-window Cockpit, launch default)
2. The theme interface and the Futuristic space theme, with reduce motion
3. Memory constellations with pulses, fade-ins, and Explore memory
4. The widget grid: add, move, resize, remove, settings, saved layout
5. All eleven widgets in the table
6. Background runs from shortcuts and quick capture: queue and kickstart, streaming steps, Stop, no approval and no cap
7. `topic` on news items, and the AI Scout prompt update
8. Token usage aggregation and the plan-limits status line

Later: theme variations as folders, more themes, free-form widget placement, a 3D memory view.

## Decision record

Q1 called the Cockpit · Q2 toggle by clicking the title · Q3 full window · Q4 all ten panels, plus Activity from Q13b · Q5 vault constellations · Q6 tokens plus an API-equivalent estimate · Q7 shortcuts run in the background, shown live · Q8 native SwiftUI · Q9 show, don't store · Q10 the other mode is the Studio · Q11 opens in the Cockpit · Q12 runs go through the runner · Q13/Q13b the Activity widget replaces popups · Q14 shortcuts in cockpit.json · Q15 no approval and no cap for manual runs · Q16 `topic: news` · Q17/Q28 all token usage plus plan limits, by source · Q18 quick capture as a background run · Q20 one-click Inbox actions · Q21/Q25 themeable, code themes with settings, Futuristic space first · Q22 snap-grid widgets · Q23 per-widget settings and repeats · Q24 responsive constellations · Q26 status line snapshot for plan limits · Q27 freshness shown

## Revision 2026-10-24: free canvas

After living with the snap grid, the layout moved to the reference style: compact widgets placed freely around the memory graph, with open space between them.
- **Q44 placement:** drag a widget by its header to anywhere. It snaps to the canvas edges and to other widgets' edges, and its position is saved (`x`, `y` in `cockpit.json`). Widgets with no saved position, and everything after **Tidy up**, stack in a left column (Today, Inbox, Routines, Plan limits, Token usage) and a right column (Activity, Agents, News, Shortcuts, Vault health), with Quick capture centred at the bottom.
- **Q45 graph:** the memory graph is the interactive centre stage. Hover a star for its details and click to open it in Obsidian. Drag empty space to pan, pinch or use the zoom buttons, and use FIT to recentre. Stars are coloured by the map that links them. The separate Explore memory mode is gone.
- **Q46 size:** widgets are compact (270 px; Activity 320, Quick capture 460) and only as tall as their content. Each can collapse to its title row.
- **Q47 status strip:** a thin top strip shows the Cockpit | Studio switch, runner state, live runs, Inbox count, plan limits, brain size and the time, plus zoom, **+ WIDGET** and **TIDY UP**.
- **Focus mode:** the ⤢ button in a widget's header, or double-clicking anywhere on the widget (Quick capture: its header only), opens that widget large in the centre over the dimmed Cockpit. Esc, ✕ or a click outside closes it.
  - Inbox opens the full Inbox with approvals.
  - News lists every digest for its topic, with the full text beside the list.
  - Token usage shows today, 7 days and 30 days side by side, with every source.
  - Routines opens the routines editor.
  - Other widgets show their content at full size.
- **Header buttons** (focus, collapse, menu) have 28-point click areas with a hover highlight.

## Revision 2026-10-24: agent widgets

The built-in News widget guessed at AI Scout's digest format, so every format change by the agent broke it. Widgets are now split: the app draws the frame, and the agent writes what goes inside.
- **Q48 format:** one Markdown file per widget in `<agent>/widgets/<name>.md`, images in `widgets/assets/`. Front matter sets `title`, `icon` (an SF Symbol) and `width` (small 270, medium 360, wide 460, or 220–640). The card is everything before `<!-- full -->`; focus mode shows the card plus the full part. The folder sits inside the agent's own folder, so each agent can already edit its own widgets (in conversations and in routine runs) and no one else's.
- **Q49 new widgets:** they appear in **+ WIDGET** under "From agents" for the user to place, and the label shows a dot while any are unplaced. Files are checked every 2 seconds by modification time and reparsed only when one changes.
- **Q50 flexible widgets:** layout is free Markdown. Interactive and data blocks are fenced blocks:
  - **button** (`label`, `run`, optional `skill`, `web`, `icon`, `note`) and **input** (`placeholder`, `label`, `run` with `{text}`) start a background run of the agent through the runner with the instruction, the widget's path and a reminder to update the file. The click is the approval, like shortcuts; hovering shows the instruction. Runs are labelled "Widget button" in Activity.
  - **checklist** (`- [ ]`) ticks are written into the file, only if the line still reads as a checklist item.
  - **stat**, **gauge** and **chart** (bar or line, one `label: value` per point) are display only.
  - Agents can't run code in the app. A missing block type is requested through the Inbox.
- **Q51 News:** retired. Saved News widgets become AI Scout's `news` agent widget in the same position; AI Scout's daily routine also redesigns that widget.
- **Q52 images:** `https` URLs, or relative paths that stay inside the item's own folder (the agent's `widgets/` folder, or the Inbox). `http`, `file://`, absolute paths, and paths climbing out are refused; images over 15 MB don't load. Resolving an Inbox item moves its relative images to `archive/` (copied when another waiting item uses them).
- **Shared renderer:** Inbox items, focus mode and agent widgets use one native renderer (`Markdown.swift` parses blocks; `MarkdownView.swift` draws them), with no new dependency. Plain-text items keep their line breaks. Raw HTML isn't rendered; comments are hidden. Interactive blocks are inactive outside agent widgets.

## Revision 2026-10-24: routines that show what happened

Running a routine by hand used to leave no trace in the widget, because it only showed each routine's scheduled time.
- **Runs, not slots:** each run today gets a row (time, outcome, how long ago), tagged **manual** when started by Run now or an Inbox follow-up. History comes from the activity log's `routine.*` events (`RoutineHistory.swift`), reloaded only when the log changes. Scheduled times not yet covered show as *next* or *due*, and queued runs as *starting…*. Rows sort by time (the old list sorted the time text, putting 10:00 AM before 2:00 AM).
- **Live:** a running row shows a spinner, elapsed time, the latest step and Stop.
- **Attention:** routines that need fixing, wait for approval, or whose latest earlier run failed show at the top with **Review**.
- **Next:** once today is done, "Next: <routine> · tomorrow 2:00 AM".
- **Hover:** Run now (never twice: an already queued or running routine isn't queued again) and the run's steps and result.
- **Compact:** a row stays on one line when it fits (duration moves to the tooltip, steps and focus mode), and the card shows the latest five entries.
- **Focus mode:** today or 7 days, filterable by routine, with runs, success count, total time and cost, and each run's steps.
- **Routines screen:** Run now shows Starting… and Running…, and a status line shows queued, running (elapsed, latest step, Stop) and the finished result. Run now wakes the runner at once.
- **Layout:** when a widget grows into the one below it, the lower one moves down, or to the nearest free spot if there's no room. Saved positions don't change.

## Revision 2026-10-24: widget size and gallery

- **Widget size:** one global size for every widget, 75–150% (`widgetScale` in `cockpit.json`, optional so older layouts load at 100%). Change it with **− / +** in the status strip, ⌘− / ⌘+, or the settings menu. Widgets are drawn scaled from their top-left corner and placed by their scaled size, so snapping, overlap avoidance and Tidy up keep working.
- **Collapse to fit:** when a widget has no room open anywhere at the current size, it's drawn collapsed to its title row with a compress icon that opens focus mode. The strip shows how many, with a tooltip on what to do. Placement uses each widget's open height (measured while open), so it doesn't flip between open and collapsed. Nothing is saved: your own collapse settings stay as they are.
- **Gallery:** **+ WIDGET** opens a gallery instead of a menu. Agent widgets come first, then built-in ones, each as a live preview (not clickable) with a one-line description, whether it's already on the Cockpit, and **Add** or **Add another**.

## Revision 2026-10-24: side columns

The middle of the Cockpit is now only the memory graph. Widgets live in two side columns.
- **Columns:** a left and a right column, each a vertical scroll with widgets stacked at one width (330 points × the widget size). Each widget has a `side` in `cockpit.json` (0 left, 1 right; nil uses its kind's default side), and the order within a side is the order in the file.
- **Rearranging:** drag a widget by its header onto another widget to put it there (an accent line shows where), or onto the end of either column. Each widget's menu also has Move up, Move down, and Move to the other side. New widgets go to the end of the column with fewer widgets.
- **Graph:** sized to fit the clear middle (`GraphViewport.fitWidth`), centred in the window.
- **Removed:** Quick capture (from the layout and the gallery; the kind stays decodable), free placement, snapping, overlap avoidance, collapse to fit, and Tidy up. The settings menu has "Reset to default widgets and sides".
- **Migration:** once, on opening the Cockpit, a free-placement layout converts: Quick capture is dropped, a hand-placed widget joins the side its saved position was on, each side keeps top-to-bottom order, and saved positions are cleared.

## Revision 2026-10-24: reads light up the graph

When an agent reads or searches a vault note, its star flares with a warm light for 4 seconds, labelled with the note and the agent ("Tech · Atlas"). This is separate from the ring that marks a changed note.
- **Source:** agents' transcripts (`<agent>/.runtime/projects/*/*.jsonl`), followed every 2 seconds while the Cockpit is open (`VaultActivity.swift`). Only lines added since the last check are read, older conversations aren't replayed, and nothing is written.
- **What counts:** any new transcript line that names a vault note by its full path: reads, search results (`Grep`, `Glob`), shell commands, edits and writes. Conversations and background runs both count. Folders and hidden tool files aren't notes.
- **Motion:** the graph animates at 20 fps only while a flare or pulse is showing; Reduce motion turns the flare off.

## Revision 2026-10-24: quick search on the graph

A search field sits at the top of the clear middle (⌘F). Typing searches every vault note (`VaultSearch.swift`): every word must match the title, path or text; titles rank above paths above text. Up to six results show with a plain-text snippet around the match; the rest stay lit on the graph.
- **Keys:** ↑ / ↓ step through results (the camera follows), Return or a double-click opens the note in Obsidian, Esc clears and glides back to the full view. Clicking a result flies to it.
- **On the graph:** each query change sends a cyan sonar ring out from the centre, and matching stars ping as it passes. Non-matches fade almost away; matches get a pulsing cyan halo and their name, and links between matches light up. The selected result gets a rotating four-bracket reticle with crosshair ticks.
- **Camera:** glides (eased, about 0.85 s) to put the selected star in the open space below the results, zoomed to at least 1.8×. Zoom buttons and FIT glide too; dragging or pinching mid-glide takes over where the camera is.
- **Graph edges:** the graph fades out where the side columns begin, so it never draws behind widgets.
- **Reduce motion:** the camera jumps instead of gliding, with no sweep, pings or pulsing.
- **Checking:** `open --args -debugSearch <text>` fills in a query on launch, for screenshots; it's never saved.

## Revision 2026-10-24: note viewer, search on Return

- **Search pops up:** the search box is hidden so the middle stays clear. Return (when not typing in a text field) or ⌘F pops it up; Esc, the × or a click on empty graph hides and clears it. Results still update as you type.
- **Note viewer:** clicking a star, or opening a search result (Return or double-click), shows the note inside ClaudeDesk. It shows the title, path and last edit, the note's properties as tags, and the note rendered by the shared Markdown renderer. `[[wikilinks]]` follow inside the viewer, with Back (⌘[); links to missing notes show as plain text. "Links to" and "Linked from" list the connected notes. Open in Obsidian and Show in Finder are in the header; Esc or a click outside closes it. Images resolve inside the vault only.
- **Checking:** `open --args -debugOpenNote <vault path>` opens a note on launch, for screenshots; it's never saved.
- **Frame rate:** the graph draws at the display's full rate (up to 60 fps, `GraphFrames`) while anything moves: a camera glide, the search sweep and pings, a read flare, or a change pulse. When the motion ends, halos stop pulsing and the reticle comes to rest, and the graph goes back to one frame a second (or none, with Reduce motion). Measured: about 15% CPU during a sweep and glide, under 1% with a search open and settled, under 1% idle.

## Revision 2026-10-25: graph views

A **2D / 3D / ORBIT** switcher in the status strip picks how the memory graph is laid out (saved as `cockpitGraphMode`). All three are drawn in the same Canvas, with no 3D library.
- **2D (Constellation):** the force layout as before.
- **3D (Sphere):** a 3D force layout inside a sphere (`ConstellationLayout.positions3D`), seen with perspective. Nearer stars are larger and brighter, farther ones fade into fog, and stars are drawn far to near. A faint wireframe globe (equator, two latitudes, four meridians) shows the shape. Drag turns it: sideways spins it, up and down tilts it; it also drifts very slowly.
- **ORBIT:** Home at the centre; maps circle it on one ring; each note circles the first map (by name) that links to it, with neighbouring systems turning in opposite directions; notes no map links to circle on an outer ring. Dashed guide rings show the orbits.
- **Switching** morphs every star from its place in the old view to the new one (eased, about 1.1 s); guides fade in as it lands. Search, read flares, hover, and opening notes work in every view, and a search flies to its result in the current view. With Reduce motion the switch is instant.
- **Cost:** about 1–2% CPU once settled in either new view; motion runs at full frame rate only while something moves.
- **Checking:** `open --args -debugGraphMode sphere|orbit|flat` switches view on launch (this one is saved, like a normal switch).

## Revision 2026-10-25: Ask panel

**Shift+Return** in the Cockpit (when not typing in a text field) opens an Ask bar at the bottom of the clear middle, addressed to Atlas by default; the agent menu picks another agent.
- **Sending** (Return) starts a background run of kind `ask` (`DeskStore.ask`), under the same restricted profile as shortcuts. Its prompt says the final message is the answer the user reads, rendered as Markdown, so it should be the answer itself.
- **While it works**, the panel shows the run's latest step and elapsed time, with Stop. Notes it reads light up on the graph (the read flare).
- **Answers** render as Markdown under each question. Follow-ups carry the last four questions and answers as context.
- **Continue in Studio** reopens the same session (`--resume <run ID>`) as a conversation pane. **Copy answer** and **New chat** are in the panel's footer. Esc hides the panel; the chat stays until New chat or the app quits.
- **Checking:** `open --args -debugAsk "<text>"` opens the panel with the text filled in, without sending it.
- **Explaining it:** hovering the Ask bar says what it does; its ⓘ button opens a short explainer (headless `claude -p` as the agent, restricted tools, live steps, follow-ups, Continue in Studio, plan usage). When neither bar is open, a faint hint at the bottom of the Cockpit shows "↵ search memory · ⇧↵ ask Atlas".

## Revision 2026-10-26: Studio in the Space look

The Studio now matches the Cockpit. A new Studio theme, **Space** (`DeskTheme.space`), is the default, and existing setups switch to it once (`studioSpaceTheme.v1`); the older themes stay in Settings.
- **Frame:** the Cockpit's starfield behind everything, the same thin status strip (Cockpit | Studio switch, CLAUDEDESK OS · STUDIO, runner, Inbox, agents, live sessions, sidebar toggle ⌘0, time), a floating glass sidebar, and a rounded glass panel for the main area, instead of the system split view.
- **Controls:** Projects / Agents / Skills is a pill switch; section labels are monospaced capitals; the sidebar's main buttons use the accent glass style.
- **Colours:** every Studio screen (terminals, agents, skills, Inbox) reads the theme, so they take the Space palette: navy backgrounds, the Cockpit's blue accent, and light text. Empty screens let the stars show through.
- The other themes keep the system split-view layout.

## Revision 2026-10-26: the Desk, Google mail and calendar, Jev triage

- **The Desk:** the agents' Inbox is called the **Desk** wherever you see it (sidebar, strip, widget, menu ⌘I). The folder stays `inbox/` and agents' instructions are unchanged, so nothing they rely on breaks.
- **Secrets in the Keychain** (`Secrets.swift`): the Jev API key, the Google OAuth client ID and secret, and each Google account's refresh token are generic-password items (service `ClaudeDesk`) on this Mac only, not synced. Settings › **Integrations** saves, replaces and removes them and never shows a saved value. Access tokens live only in memory. After an update, macOS may ask once to let ClaudeDesk use its saved keys.
- **Google** (`GoogleService.swift`): **Add Google account** opens Google's sign-in in your browser (OAuth for installed apps with PKCE and a one-shot 127.0.0.1 redirect). Scopes are read-only: `gmail.readonly` and `calendar.readonly`, plus `openid email`. Several accounts are supported. Recent inbox mail (last 4 days, up to 30 per account) and the next two days of events refresh every 5 minutes while the Cockpit is open. The cache (`~/Library/Application Support/ClaudeDesk/mail-cache.json`, owner-only) is outside the workspace.
- **Jev triage** (`MailModel.swift`): one call per new email to `api.typesafe.ai/v1/systemone` (model `jev-latest` by default, settable): a **category** (work, personal, meetings, finance, updates, newsletters, other), three **signals** (urgent, needs reply, suspicious) and an **importance** score, all guarded so email text is evidence, never instructions. Judgments are cached by message, so mail is never re-triaged. Code decides: urgent and needs-reply need 60%, suspicious needs 50% and is flagged but never pushed to the top; ordering uses importance, urgency, reply and unread.
- **Widgets:** **Mail** (counts for urgent, reply and suspicious; top messages with account colour, category and flags; focus mode adds category and account filters and snippets; click opens the thread in Gmail) and **Schedule** (next event, today's events across accounts with Join for video calls; focus adds tomorrow). Both are added to the Cockpit once.
- **Atlas:** questions in the Ask bar about mail, messages, the calendar, meetings or the day get the triaged mail and upcoming events as context, labelled as untrusted email text.
- **Not yet:** agents reading mail directly (MCP tools) — planned as a second step.
- **This Mac (default source)** (`MacAccounts.swift`): instead of the Google API, mail and calendar can come from the accounts already on the Mac. Calendars are read through EventKit (every calendar, including Google once it's in Internet Accounts), and mail from Apple Mail through AppleScript: the last 3 days of the unified inbox, up to 80 messages, each opening in Mail with a `message://` link. ClaudeDesk opens Mail hidden in the background if it isn't running. There are no keys and no 7-day sign-outs; macOS asks once for calendar access and once to control Mail (Info.plist explains both). Settings › Integrations picks the source: **This Mac** or **Google API (advanced)**.

