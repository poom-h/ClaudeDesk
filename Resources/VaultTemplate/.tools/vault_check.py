#!/usr/bin/env python3
"""Check the Memory Vault's maps, links, and note properties.

Usage: python3 .tools/vault_check.py [--vault PATH] [--strict]

Reads the vault and never changes it. Exits 1 when there are errors
(or warnings with --strict), otherwise 0. Rules come from
Notes/Second-Brain-Framework.md.
"""
import argparse
import re
import sys
import time
from collections import deque
from pathlib import Path

# Tuning lives here.
NOTE_TYPES = {"guide", "concept", "tool", "troubleshooting", "reference", "idea"}
MAP_SECTIONS = ["Start here", "Maps", "Notes", "In progress", "Open questions", "Not here"]
STANDARD_DIRS = {"Inbox", "Notes", "Maps", "Assets", "Archive"}
INBOX_STALE_DAYS = 14
MAX_DEPTH = 5  # map hops from Home before a note counts as buried
HOME_MAX_LINES = 60

DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LINK = re.compile(r"\[\[([^\]]+)\]\]")
FENCE = re.compile(r"^(```|~~~).*?^\1[^\n]*$", re.MULTILINE | re.DOTALL)
INLINE_CODE = re.compile(r"`[^`\n]*`")
HEADING = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)
ENTRY = re.compile(r"^\s*[-*]\s+\[\[[^\]]+\]\](.*)$")


class Doc:
    def __init__(self, vault, path):
        self.path = path
        self.rel = path.relative_to(vault).as_posix()
        self.top = self.rel.split("/")[0] if "/" in self.rel else ""
        text = path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
        self.lines = text.count("\n") + 1
        self.props, self.body = split_frontmatter(text)
        self.code_free = INLINE_CODE.sub("", FENCE.sub("", self.body))
        self.links = [t for t in (link_target(m) for m in LINK.findall(self.code_free)) if t]
        self.is_map = self.rel == "Home.md" or self.top == "Maps"


def split_frontmatter(text):
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    close = text.find("\n", end + 4)
    body = "" if close == -1 else text[close + 1:]
    props, key = {}, None
    for line in text[4:end].split("\n"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if match:
            key, value = match.group(1), match.group(2).strip()
            props[key] = value.strip("'\"") if value else []
        elif key and line.lstrip().startswith("- ") and isinstance(props.get(key), list):
            props[key].append(line.lstrip()[2:].strip().strip("'\""))
    return props, body


def link_target(raw):
    # [[target#heading|alias]] -> target; [[#heading]] links within the same note.
    return re.split(r"[|#^]", raw, maxsplit=1)[0].strip()


class Vault:
    def __init__(self, root):
        self.root = root
        self.docs, self.files = [], []
        for path in sorted(root.rglob("*")):
            parts = path.relative_to(root).parts
            if any(part.startswith(".") for part in parts) or not path.is_file():
                continue
            self.files.append(path)
            if path.suffix.lower() == ".md":
                self.docs.append(Doc(root, path))
        self.by_rel = {d.rel.lower()[:-3]: d for d in self.docs}
        self.by_stem = {}
        for doc in self.docs:
            self.by_stem.setdefault(doc.path.stem.lower(), []).append(doc)
        # When titles collide, resolve to the organized copy rather than a capture or archive.
        preference = {"Notes": 0, "Maps": 0, "": 1, "Inbox": 2, "Archive": 3}
        for docs in self.by_stem.values():
            docs.sort(key=lambda d: preference.get(d.top, 1))
        self.by_name = {}
        for path in self.files:
            self.by_name.setdefault(path.name.lower(), []).append(path)

    def resolve(self, target):
        """Return the Doc or attachment Path a wikilink points to, as Obsidian would."""
        key = target.lower()
        if key.endswith(".md"):
            key = key[:-3]
        if key in self.by_rel:
            return self.by_rel[key]
        name = key.rsplit("/", 1)[-1]
        if name in self.by_stem:
            return self.by_stem[name][0]
        found = self.by_name.get(name)
        return found[0] if found else None


def check(root, strict):
    vault = Vault(root)
    errors, warnings = [], []

    def error(where, message):
        errors.append(f"{getattr(where, 'rel', where)}: {message}")

    def warn(where, message):
        warnings.append(f"{getattr(where, 'rel', where)}: {message}")

    # Titles must be unique, because links resolve by title.
    for docs in vault.by_stem.values():
        live = [d for d in docs if d.top != "Archive"]
        if len(live) > 1:
            error(live[0], "title also used by " + ", ".join(d.rel for d in live[1:]) + " (links become ambiguous)")
        elif live and len(docs) > 1:
            warn(live[0], "title also used by archived " + ", ".join(d.rel for d in docs if d.top == "Archive"))

    for doc in vault.docs:
        for target in doc.links:
            found = vault.resolve(target)
            if found is None:
                (warn if doc.top in ("Inbox", "Archive") else error)(doc, f"links to missing [[{target}]]")
            elif doc.is_map and isinstance(found, Doc) and found.top == "Archive":
                warn(doc, f"map still lists archived note [[{target}]]")

        if doc.top == "" and doc.rel != "Home.md":
            warn(doc, "file sits outside the standard folders")
        if "status" in doc.props:
            warn(doc, "`status` is retired; use `verified: <date>` or `outdated: <date>`")
        for key in ("verified", "outdated", "archived"):
            value = doc.props.get(key)
            if value is not None and not (isinstance(value, str) and DATE.match(value)):
                error(doc, f"`{key}` must be a date like 2026-10-22")

        if doc.top == "Notes":
            note_type = doc.props.get("type")
            if not note_type:
                error(doc, "missing `type` property")
            elif note_type == "map":
                warn(doc, "maps belong in Maps/")
            elif note_type not in NOTE_TYPES:
                warn(doc, f"unusual type `{note_type}` (known: {', '.join(sorted(NOTE_TYPES))})")
        if doc.top == "Archive" and not doc.props.get("archived"):
            warn(doc, "archived note has no `archived: <date>` property")
        if doc.top == "Inbox" and time.time() - doc.path.stat().st_mtime > INBOX_STALE_DAYS * 86400:
            warn(doc, f"Inbox capture untouched for over {INBOX_STALE_DAYS} days")
        if doc.is_map:
            check_map(doc, error, warn)

    for top in sorted({p.relative_to(root).parts[0] for p in vault.files if len(p.relative_to(root).parts) > 1}):
        if top not in STANDARD_DIRS:
            warn(top + "/", "folder is not part of the framework")

    home = vault.by_rel.get("home")
    if home is None:
        error("Home.md", "missing, so reachability cannot be checked")
    else:
        if home.lines > HOME_MAX_LINES:
            warn(home, f"longer than {HOME_MAX_LINES} lines; move detail into maps")
        depth = reach(vault, home)
        for doc in vault.docs:
            if doc.top not in ("Notes", "Maps"):
                continue
            if doc not in depth:
                error(doc, "not reachable from Home through maps")
            elif doc.top == "Notes" and depth[doc] > MAX_DEPTH:
                warn(doc, f"{depth[doc]} map hops from Home (over {MAX_DEPTH}); consider a flatter route")

    counts = [(top, sum(1 for d in vault.docs if d.top == top)) for top in ("Notes", "Maps", "Inbox", "Archive")]
    print(f"Memory Vault check: {root}")
    print("  ".join(f"{n} {top.lower()}" for top, n in counts))
    for title, items in (("ERRORS", errors), ("WARNINGS", warnings)):
        if items:
            print(f"\n{title} ({len(items)})")
            for item in items:
                print(f"  {item}")
    failed = bool(errors) or (strict and bool(warnings))
    print(f"\nResult: {'FAIL' if failed else 'OK'} ({len(errors)} errors, {len(warnings)} warnings)")
    return 1 if failed else 0


def check_map(doc, error, warn):
    if doc.props.get("type") != "map":
        warn(doc, "map without `type: map`")
    headings = HEADING.findall(doc.code_free)
    unknown = [h for h in headings if h not in MAP_SECTIONS]
    if unknown:
        error(doc, "unknown map sections: " + ", ".join(unknown) + f" (allowed: {', '.join(MAP_SECTIONS)})")
    known = [MAP_SECTIONS.index(h) for h in headings if h in MAP_SECTIONS]
    if known != sorted(set(known)):
        error(doc, "map sections out of order or repeated (order: " + ", ".join(MAP_SECTIONS) + ")")
    for line in doc.code_free.split("\n"):
        match = ENTRY.match(line)
        if match and not re.match(r"^\s*[—–:-]+\s*\S", match.group(1)):
            warn(doc, "entry without a one-line description: " + line.strip())


def reach(vault, home):
    """Breadth-first walk from Home through maps; returns {doc: hops from Home}."""
    depth = {home: 0}
    queue = deque([home])
    while queue:
        current = queue.popleft()
        for target in current.links:
            found = vault.resolve(target)
            if isinstance(found, Doc) and found not in depth:
                depth[found] = depth[current] + 1
                if found.is_map:
                    queue.append(found)
    return depth


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--vault", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--strict", action="store_true", help="fail on warnings too")
    args = parser.parse_args()
    if not args.vault.is_dir():
        sys.exit(f"Vault not found: {args.vault}")
    sys.exit(check(args.vault.resolve(), args.strict))


if __name__ == "__main__":
    main()
