---
name: widget-instructions
description: Design or update your own widget on the user's ClaudeDesk Cockpit, a Markdown file with headings, images, tables, charts, stats, checklists, and buttons that start a background run of you. Use when the user asks you to show something on the Cockpit, change how your widget looks, or when your work changes what a widget shows.
---

# ClaudeDesk Cockpit widgets

The Cockpit is the user's overview screen. You can design your own widgets for it. Each widget is one Markdown file in your `widgets/` folder (its path is in the "Cockpit widgets" section of your CLAUDE.md). Save images in `widgets/assets/`.

- Create a new file for a new widget. It appears in the user's **+ WIDGET** menu, and the user places it.
- Edit the file to change the widget. The Cockpit reloads it within a few seconds.
- Edit only your own widget files. Don't touch the Cockpit layout or other agents' folders.
- Keep the card short: it sits in a small box (270 points wide by default). Put detail below the `<!-- full -->` line; that part shows only when the user opens the widget in focus mode.

## File layout

```markdown
---
title: News
icon: newspaper          # an SF Symbol name
width: medium            # small (270), medium (360), wide (460), or a number from 220 to 640
updated: 2026-10-24T08:00
---
![Top story](https://example.com/hero.jpg)

### OpenAI ships a new model
> Why it matters: one-line takeaway.

- Second story, with a [link](https://example.com)
- Third story

<!-- full -->
## Full digest
Everything else: sections, tables, more images…
```

## What you can use

Normal Markdown (GitHub style): headings, **bold**, *italic*, `code`, links, bullet and numbered lists, `> quotes`, `---` dividers, tables, and fenced code.

**Images:** `![alt text](source)` on its own line. The source is an `https://` URL or a path relative to the widget file, such as `assets/chart.png`. `http://`, `file://`, and absolute paths don't load. Images scale to the widget's width.

**Checklist:** `- [ ] item` and `- [x] item`. The user can tick items; ClaudeDesk writes the tick into your file, so read it before rewriting the list.

HTML isn't rendered. `<!-- comments -->` are hidden.

## Interactive and data blocks

Write these as fenced blocks with `key: value` lines.

**Button.** It starts a background run of you with the instruction in `run`, the same way the user's skill shortcuts do. The click is the user's approval. When the run finishes something that belongs on the widget, update the widget file.

````markdown
```button
label: More like this
run: Find three more stories like today's top story and add them under "More" in the full part of this widget.
icon: sparkles            # optional SF Symbol
skill: ai-tech-news       # optional library skill to use
web: true                 # optional: allow fetching web pages
note: takes about a minute   # optional, shown beside the button
```
````

**Input box.** Like a button, but the user's text replaces `{text}` in `run`.

````markdown
```input
placeholder: Ask about a story…
label: Ask
run: Answer this question about today's news and put the answer at the top of this widget's full part: {text}
```
````

**Stat**, a big number:

````markdown
```stat
label: Stories today
value: 12
note: 3 more than yesterday
```
````

**Gauge**, a progress bar. `max` defaults to 100.

````markdown
```gauge
label: Reading list
value: 7
max: 10
note: 7 of 10
```
````

**Chart.** Every line that isn't `title`, `type`, or `unit` is one data point, in order.

````markdown
```chart
title: Stories per day
type: bar          # bar or line
Mon: 5
Tue: 8
Wed: 6
```
````

## Rules

- A button only runs when the user clicks it. Write `run` instructions you'd be happy to carry out unattended, under the usual restricted background-run permissions.
- Don't put secrets or private credentials in a widget.
- If you need a kind of block that doesn't exist yet, send the user an Inbox `request` describing it (see the `inbox-instructions` skill).
