---
type: reference
topics:
  - knowledge-management
  - second-brain
---

# Second Brain Framework

ClaudeDesk sets up this framework as the default for a new Memory Vault. It is the operating framework for the agent that maintains the vault and for the Obsidian vault itself, adapted from the references below. It is a practical convention, not a claim that one universal method is best.

## Purpose

Maintain a flexible personal knowledge library for anything useful: practical guides, concepts, technologies, troubleshooting fixes, references, ideas, and learning notes. Do not require a course, project, or predefined subject category before saving something. The user should be able to say “Save this guide for running EC2” without choosing folders, metadata, or templates.

Vault: `{{VAULT_PATH}}`

Keep durable knowledge in this vault. The agent's private working memory, Claude history, credentials, and runtime belong in its separate agent environment. Do not put credentials or secrets in ordinary notes.

## Folder conventions

```text
MemoryVault/
├── Home.md      # Root map: only where things live, no facts
├── Inbox/       # Raw or unprocessed captures; interviews in Inbox/interviews/
├── Notes/       # Organized guides, concepts, tools, references, and ideas
├── Maps/        # Maps that group notes and other maps
├── Assets/      # Images, PDFs, and other attachments
├── Archive/     # Retired notes and processed captures; nothing is deleted
└── .tools/      # vault_check.py (hidden in Obsidian)
```

Keep the folders flat; do not create a folder for every subject. Grouping and hierarchy live in maps, not folders, so a note can belong to several groups without being copied or moved.

## Ground rules

- **Every fact has one home.** Write it once, in the most fitting note, and link to it from everywhere else. Do not copy explanations between notes.
- **Maps change with the notes.** When a note is created, renamed, moved, or archived, update every map that lists it in the same turn.
- **Nothing is deleted.** Move retired notes to `Archive/` with an `archived: <date>` property and a one-line reason at the top. Remove them from maps.
- **Append to running notes.** Journals, logs, and decision records grow by adding entries; do not rewrite them whole.
- **Only the user's confirmation verifies a note.** See [[#Properties]].
- **Check before judging.** Run the vault checker before any review and after changing the vault, so deterministic problems are found by the script rather than by guessing.

Re-read a file before updating it so changes from the user or other sessions are preserved. Discuss substantial reorganizations, merges with information loss, and archiving notes the user did not ask to retire before doing them. Do not change `.obsidian` settings unless asked.

## Home and maps

`Home.md` is the root map. It holds no facts, only links to the top-level maps (one per broad area of life or work) and a “Not here” list. The agent loads it at the start of every conversation, so it stays short: about 60 lines at most.

Every note in `Notes/` must be reachable from Home by following maps. Maps can contain other maps, so groups can nest as deep as the subject needs, for example:

```text
Home → Tech → AWS → EC2 → [[Launch an EC2 instance]]
                  → Lambda → [[Deploy a Lambda function]]
```

- Start broad. Create a sub-map when a map grows past about 25 entries or a cluster is clearly its own subject. Do not create maps with one entry.
- A note or map can be listed in more than one map when it genuinely belongs in both.
- Each extra level costs the agent one more file to read. Prefer a wide map with clear descriptions over a deep chain of thin maps.

### Map format

Maps live in `Maps/` (Home is the only map outside it) and carry `type: map`. They use only these sections, in this order, and leave out sections they do not need:

1. `## Start here` — the one to three entries a newcomer should open first
2. `## Maps` — sub-maps
3. `## Notes` — the notes in this group
4. `## In progress` — what the user is currently learning or doing in this area
5. `## Open questions` — known gaps worth filling
6. `## Not here` — related things that live elsewhere, so the agent stops searching

Every link entry is one line with a description that lets the agent choose without opening the file:

```markdown
- [[Launch an EC2 instance]] — create a server and connect through SSH.
- [[Diagnose an EC2 SSH timeout]] — investigate connection failures.
```

Maps contain no facts. Explanations belong in notes.

## Capture and maintenance workflow

For a request to save knowledge:

1. Start from Home and follow the relevant maps; then search titles and contents for equivalent or related information.
2. Reuse an equivalent note. Propose or make a scoped update when the request clearly authorizes it; create a separate note when it serves a different purpose. Do not silently replace conflicting claims.
3. Preserve the source URL, author, date, or supplied provenance when available. Distinguish direct quotations, source summaries, the user's experience, and the agent's inference. Never invent citations or missing facts.
4. Choose a suitable note format. Use existing type and topic names before creating synonyms. Do not force an uncertain capture into a category; Inbox is a valid destination.
5. Write a clear title and useful content. Preserve code, commands, prerequisites, and limitations accurately. Mark unknown or unverified details explicitly.
6. Add the note to the right map, creating a sub-map only when the rules above call for one. Link relevant existing notes when the relationship is meaningful, and explain the relationship.
7. Run the vault checker and fix any problem the change caused.
8. Report briefly what was saved or updated and link to the note. Mention unresolved gaps or conflicts.

When an Inbox capture has been turned into notes, move it to `Archive/` with the reason `Processed into [[Note title]]`.

## Note scope

Keep each note focused on a clear question or purpose, but complete enough to use. A guide such as “Launch an EC2 instance and connect through SSH” can remain a single note. Do not turn every command into a separate note. Extract a concept when it becomes independently reusable, and link back instead of duplicating explanations.

Prefer specific, readable titles. Example: “Diagnose an EC2 SSH timeout” rather than “AWS notes 2”. Titles must be unique across the vault, because links resolve by title.

## Flexible note types

These are starting conventions, not a closed schema:

| Type | Useful content |
| --- | --- |
| guide | Goal, prerequisites, steps, verification, troubleshooting, sources |
| concept | Explanation, examples, when it matters, connections, sources |
| tool | What it does, trade-offs, potential uses, actual experience, sources |
| troubleshooting | Symptoms, environment, cause or hypotheses, fix, verification |
| reference | Commands, configuration, facts, assumptions, sources |
| idea | Idea, motivation, open questions, possible next step |

Choose only the sections that help. Do not fill empty sections with invented material. Prefer `guide` over introducing synonymous types such as `how-to` and `tutorial` without a reason.

## Properties

Notes in `Notes/` carry `type` and, when useful, `topics`. Raw Inbox captures need none.

```yaml
---
type: guide
topics:
  - aws
  - deployment
verified: 2026-10-22
---
```

There is no draft/ready status. The user talks to the agent rather than editing properties, so trust is recorded only when it carries information:

- **No `verified` property** means the agent wrote or updated the note and the user has not confirmed it. This is the normal state; it needs no review chores.
- **`verified: <date>`**: The agent adds it only when the user confirms in conversation that the note worked or is right (“that worked”, “looks right”). The user's confirmation is the approval. Record what was confirmed in the body when it is narrower than the whole note.
- **`outdated: <date>`**: The agent sets it when the user says something changed or broke, and adds a short line at the top of the body explaining what is wrong. Remove `outdated` and refresh `verified` once the note is fixed and confirmed again.

When answering from a note without `verified`, mention that it has not been confirmed. Record sources, relevant OS/tool versions, and assumptions in the body when needed. Never use the date of saving a note as evidence that it was tested.

Properties may support optional Obsidian Bases views such as “AWS guides” or “outdated notes”. Do not install plugins or build dashboards merely to satisfy this framework.

## Retrieval

Start from Home, which is already loaded, and follow map descriptions to the likely note before searching the whole vault. Return the relevant notes with a concise answer and clear links; do not create another saved note unless asked or already authorized. If the answer was missing or hard to find, suggest a map entry or note that would have made it easy.

## Starting interview

When the user asks to be interviewed, or when an area of the vault is empty and the user agrees, interview them before writing maps. Ask one question at a time and wait for the answer. Cover, in this order:

1. What they are learning or working on now
2. What they keep looking up or re-solving
3. Recurring problems they want written down
4. Interests and areas of life they want to keep knowledge about
5. Where their notes and bookmarks live today (Apple Notes, bookmarks, chats, documents)
6. What they keep forgetting

Push back gently when an answer is vague. Save every question and answer as you go to `Inbox/interviews/<date>-<topic>.md`. When the user says “stop”, draft or extend Home and the maps from the answers, list what is still unknown, and move the interview to `Archive/` once it has been processed. Each run can cover a different topic.

## Vault checker

`.tools/vault_check.py` reads the vault and never changes it:

```sh
python3 {{VAULT_PATH}}/.tools/vault_check.py
```

It reports errors (broken links, notes not reachable from Home, duplicate titles, map sections out of order, missing or malformed properties) and warnings (map entries without descriptions, deeply buried notes, old Inbox captures, maps linking to archived notes, retired `status` properties). It exits with code 1 when there are errors; `--strict` also fails on warnings.

## Gradual review

When the user requests a review, run the checker first, then identify useful Inbox captures, outdated notes, duplicates, and maps that have grown too long or too thin. Suggest manageable improvements. Do not ask the user to review unverified notes unless they want to. Scheduled runs are limited to the maintenance below; nothing here authorizes automatic large reorganizations. Easy capture and useful retrieval matter more than perfect taxonomy.

## Scheduled maintenance

Approved by the user on 2026-10-22. A nightly routine may run the vault checker and fix only:
- notes not reachable from Home, by adding them to the best-fitting existing map
- broken links left by a rename, when exactly one note matches
- map entries without a description
- map entries for archived notes

It must not move, rename, archive, merge, or delete notes, change note content beyond fixing a link, or process Inbox captures. It reports fixes and remaining problems as one ClaudeDesk Inbox message, and stays silent when the vault is clean.

## References and provenance

The folder structure, metadata conventions, and agent workflow above are ClaudeDesk's defaults; adapt them to how you work. They are an adaptation, not a verbatim implementation of PARA, Zettelkasten, or MAPS.

- [Zettelkasten introduction](https://zettelkasten.de/introduction/) — focused notes and meaningful connections.
- [Atomic note-taking guide](https://zettelkasten.de/atomicity/guide/) — treating note scope as a useful principle rather than an inflexible rule.
- [Obsidian internal links](https://help.obsidian.md/links) — connecting notes without duplicating them.
- [Obsidian properties](https://obsidian.md/help/properties) — structured metadata.
- [Obsidian Bases](https://help.obsidian.md/bases) — optional views over notes and properties.
- [Building a Second Brain](https://fortelabs.com/blog/basboverview/) — capture, organize, distill, and use information.
- [MAPS framework guide](https://github.com/pavrus117/ai-os-maps-guide) by Pav (Automation Orbit) — the source of the root map that holds no facts, one home per fact, the fixed map sections with a “Not here” list, the nightly link checker, the starting interview, and archiving instead of deleting. Its strict two-hop limit was relaxed here to allow nested maps.
