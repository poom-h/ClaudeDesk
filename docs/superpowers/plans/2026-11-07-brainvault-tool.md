# brainvault Tool Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `brainvault`, a standalone, cross-platform Go program that serves a Markdown Memory Vault to agents as seven MCP tools over stdio, with confined, stale-checked, atomic, locked and logged writes.

**Architecture:** A core library (`internal/vault`) holds every behaviour and safety rule. `internal/lock` gives per-OS file locking, and `internal/audit` writes a JSONL call log. Thin adapters translate input and output: `internal/mcpserver` (MCP tools) and `cmd/brainvault` (the `mcp` subcommand, CLI subcommands and `doctor`). Nothing in the tool knows about ClaudeDesk.

**Tech Stack:** Go (current stable from Homebrew), `github.com/modelcontextprotocol/go-sdk` (v1.x), `gopkg.in/yaml.v3`, `golang.org/x/text/unicode/norm`, `golang.org/x/sys/windows`, GoReleaser v2, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-07-brainvault-design.md` (in the ManageMyClaude folder).
**Plan 2 (later):** the ClaudeDesk integration (bundle the binary, wire `.mcp.json`, update agent instructions, read the audit log in the Cockpit). Write it after this plan ships a working binary.

## Global Constraints

- Repository: a new git repo at `/Users/poomhirunwiwatkul/Documents/Code/BrainHub/brainvault`. Go module path: `github.com/poom-h/brainvault`.
- Dependencies are limited to: `github.com/modelcontextprotocol/go-sdk`, `gopkg.in/yaml.v3`, `golang.org/x/text`, `golang.org/x/sys`. Ask before adding any other.
- Builds use `CGO_ENABLED=0`. Release targets: `darwin/arm64`, `darwin/amd64`, `windows/amd64`, `windows/arm64`, `linux/amd64`, `linux/arm64`.
- Configuration inputs: `BRAINVAULT_PATH` (required) and `BRAINVAULT_ACTOR` (optional, default `unknown`). The CLI flags `--vault` and `--actor` override them.
- Audit log: `<vault>/.brainvault/audit.jsonl`. Lock file: `<vault>/.brainvault/write.lock`. Lock wait: 5 seconds.
- Tool names: `vault_search`, `vault_read`, `vault_list`, `vault_backlinks`, `vault_write`, `vault_append`, `vault_edit`.
- Error codes: `not_found`, `exists`, `outside_vault`, `stale_version`, `no_match`, `ambiguous_match`, `invalid_note`, `locked` (and `internal` for unexpected failures).
- A note ID is the vault-relative path with forward slashes on every OS, NFC-normalised, and must end in `.md`.
- `version` is the lowercase hex SHA-256 of the note's file bytes.
- The search default limit is 20 and the maximum is 100.
- Note content is never written to the audit log.
- Every commit message ends with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File Structure

```
brainvault/
├── go.mod, go.sum
├── .gitignore, .gitattributes
├── SPEC.md                          vault format contract
├── README.md                        install and client configuration
├── internal/vault/
│   ├── errors.go                    Code, Error, CodeOf, OutcomeOf
│   ├── path.go                      Vault, Open, resolve (confinement, case, Unicode)
│   ├── note.go                      Note, Read, version, frontmatter, readNote
│   ├── index.go                     Entry, notes walk, List
│   ├── links.go                     wikilink resolution, outgoing links, Backlinks
│   ├── search.go                    Search, ranking, snippets (port of ClaudeDesk VaultSearch)
│   ├── write.go                     Saved, Write, Append, Edit, atomic write, line endings
│   ├── doctor.go                    Report, Check
│   └── *_test.go                    unit, concurrency and conformance tests
├── internal/lock/
│   ├── lock.go                      Acquire, Release, ErrTimeout
│   ├── lock_unix.go                 flock (darwin, linux)
│   ├── lock_windows.go              LockFileEx
│   └── lock_test.go
├── internal/audit/
│   ├── audit.go                     Entry, Log, New, Record
│   └── audit_test.go
├── internal/mcpserver/
│   └── server.go                    tool definitions and handlers
├── cmd/brainvault/
│   ├── main.go                      subcommand dispatch
│   ├── cli.go                       CLI subcommands
│   ├── e2e_test.go                  MCP over stdio against the built binary
│   └── cli_test.go
├── testdata/vaults/                 conformance vaults
├── .github/workflows/ci.yml, release.yml
└── .goreleaser.yaml
```

---

### Task 1: Toolchain, repository and error types

**Files:**
- Create: `brainvault/go.mod`, `brainvault/.gitignore`, `brainvault/.gitattributes`, `brainvault/SPEC.md`
- Create: `brainvault/internal/vault/errors.go`
- Test: `brainvault/internal/vault/errors_test.go`

**Interfaces:**
- Produces: `type Code string` and its constants (`NotFound`, `Exists`, `OutsideVault`, `StaleVersion`, `NoMatch`, `AmbiguousMatch`, `InvalidNote`, `Locked`, `Internal`). `type Error struct { Code Code; Message string; CurrentVersion string }`. `func errorf(code Code, format string, args ...any) *Error`. `func CodeOf(err error) Code`. `func OutcomeOf(err error) string` (returns `"ok"` for nil).

- [ ] **Step 1: Install Go and create the repository**

```bash
brew install go
go version
mkdir -p /Users/poomhirunwiwatkul/Documents/Code/BrainHub/brainvault
cd /Users/poomhirunwiwatkul/Documents/Code/BrainHub/brainvault
git init
go mod init github.com/poom-h/brainvault
```

Expected: `go version` prints `go1.2x …`, and `go.mod` exists.

- [ ] **Step 2: Add repository files**

`.gitignore`:

```
/dist/
/brainvault
/brainvault.exe
```

`.gitattributes` (keeps test fixtures byte-exact on Windows checkouts):

```
testdata/** -text
```

`SPEC.md`:

````markdown
# brainvault vault format

A vault is a folder of Markdown notes. Any program that follows these rules can read and write a vault safely alongside brainvault and Obsidian.

## Notes

- A note is a UTF-8 file ending in `.md`, anywhere under the vault folder.
- Files and folders whose names start with `.` are not notes. They are never listed, searched or written. (`.obsidian/`, `.brainvault/` and `.tools/` are examples.)
- A note's **ID** is its path relative to the vault folder, with `/` between parts on every OS and Unicode NFC normalisation, for example `Notes/LangGraph basics.md`.
- IDs match existing files ignoring case and Unicode normalisation. Two notes whose IDs differ only in case are not allowed.
- A note's **title** is its file name without `.md`.
- A note's **version** is the lowercase hex SHA-256 of its file bytes.

## Properties

A note may start with a YAML properties block between two lines containing only `---`:

```
---
tags: [ai, agents]
created: 2026-11-07
---
```

## Links

- Links use Obsidian syntax: `[[Target]]`, `[[Target|label]]`, `[[Target#Heading]]`.
- `Target` may end in `.md`, and may contain a folder path (`[[Notes/Alpha]]`).
- A target with a folder path first matches the note with that exact ID (ignoring case). Otherwise, and as a fallback, it matches notes whose title equals the target's last part (ignoring case).
- If several notes share that title, the one with the shortest ID wins (then the alphabetically first).

## Line endings

Existing notes keep their line-ending style (CRLF or LF) when changed. New notes use LF.

## Tool files

brainvault keeps its own files in `<vault>/.brainvault/`: `audit.jsonl` (one JSON object per tool call, never including note content) and `write.lock`.

## Suggested layout

ClaudeDesk creates `Inbox/`, `Notes/`, `Maps/`, `Assets/`, `Archive/` and `Home.md`. brainvault accepts any layout.
````

- [ ] **Step 3: Write the failing test**

`internal/vault/errors_test.go`:

```go
package vault

import (
	"errors"
	"fmt"
	"testing"
)

func TestErrorText(t *testing.T) {
	err := &Error{Code: StaleVersion, Message: "note changed", CurrentVersion: "abc"}
	if got := err.Error(); got != "stale_version: note changed (current_version: abc)" {
		t.Fatalf("got %q", got)
	}
	if got := errorf(NotFound, "no note %q", "A.md").Error(); got != `not_found: no note "A.md"` {
		t.Fatalf("got %q", got)
	}
}

func TestCodeOf(t *testing.T) {
	wrapped := fmt.Errorf("context: %w", errorf(Locked, "busy"))
	if got := CodeOf(wrapped); got != Locked {
		t.Fatalf("CodeOf(wrapped) = %s, want locked", got)
	}
	if got := CodeOf(errors.New("disk on fire")); got != Internal {
		t.Fatalf("CodeOf(plain) = %s, want internal", got)
	}
	if OutcomeOf(nil) != "ok" || OutcomeOf(wrapped) != "locked" {
		t.Fatalf("OutcomeOf: got %q and %q", OutcomeOf(nil), OutcomeOf(wrapped))
	}
}
```

- [ ] **Step 4: Run the test to see it fail**

Run: `go test ./internal/vault/`
Expected: FAIL to compile, with `undefined: Error` and `undefined: errorf`.

- [ ] **Step 5: Write the implementation**

`internal/vault/errors.go`:

```go
// Package vault reads, searches and safely changes a Markdown vault. Every rule in SPEC.md lives here.
package vault

import (
	"errors"
	"fmt"
)

// Code is a machine-readable failure reason that tools return to agents.
type Code string

const (
	NotFound       Code = "not_found"
	Exists         Code = "exists"
	OutsideVault   Code = "outside_vault"
	StaleVersion   Code = "stale_version"
	NoMatch        Code = "no_match"
	AmbiguousMatch Code = "ambiguous_match"
	InvalidNote    Code = "invalid_note"
	Locked         Code = "locked"
	Internal       Code = "internal"
)

// Error is a vault failure an agent can act on.
type Error struct {
	Code           Code
	Message        string
	CurrentVersion string // set for stale_version and exists, so the agent can re-read and retry
}

func (e *Error) Error() string {
	s := fmt.Sprintf("%s: %s", e.Code, e.Message)
	if e.CurrentVersion != "" {
		s += fmt.Sprintf(" (current_version: %s)", e.CurrentVersion)
	}
	return s
}

func errorf(code Code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// CodeOf returns the Code of a vault error, or Internal for any other error.
func CodeOf(err error) Code {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return Internal
}

// OutcomeOf is the audit-log outcome for a call: "ok", or the error's code.
func OutcomeOf(err error) string {
	if err == nil {
		return "ok"
	}
	return string(CodeOf(err))
}
```

- [ ] **Step 6: Run the test to see it pass**

Run: `go test ./internal/vault/`
Expected: `ok  github.com/poom-h/brainvault/internal/vault`

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "feat: repository, vault format spec and error codes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Opening a vault and resolving note IDs safely

**Files:**
- Create: `internal/vault/path.go`
- Test: `internal/vault/helpers_test.go`, `internal/vault/path_test.go`

**Interfaces:**
- Consumes: `errorf`, `CodeOf`, `OutsideVault`, `InvalidNote` from Task 1.
- Produces: `type Vault struct { Root string }`, `func Open(dir string) (*Vault, error)`, `type target struct { ID, Abs string; Exists bool }`, `func (v *Vault) resolve(id string) (target, error)`. Test helpers `newVault(t, files map[string]string) *Vault` and `wantCode(t, err, code)`.

- [ ] **Step 1: Add the go dependency**

```bash
go get golang.org/x/text@latest
```

- [ ] **Step 2: Write test helpers and the failing tests**

`internal/vault/helpers_test.go`:

```go
package vault

import (
	"os"
	"path/filepath"
	"testing"
)

// newVault makes a vault in a temp folder with the given files (vault-relative path -> content).
func newVault(t *testing.T, files map[string]string) *Vault {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	v, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func wantCode(t *testing.T, err error, code Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("got no error, want %s", code)
	}
	if got := CodeOf(err); got != code {
		t.Fatalf("got error %v (code %s), want code %s", err, got, code)
	}
}
```

`internal/vault/path_test.go`:

```go
package vault

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpenRejectsMissingFolder(t *testing.T) {
	if _, err := Open(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("Open of a missing folder succeeded")
	}
}

func TestResolve(t *testing.T) {
	v := newVault(t, map[string]string{"Notes/Alpha.md": "a", "Home.md": "h"})
	tests := []struct {
		name, id, wantID string
		wantExists       bool
		wantCode         Code
	}{
		{"exact", "Notes/Alpha.md", "Notes/Alpha.md", true, ""},
		{"case-insensitive", "notes/ALPHA.md", "Notes/Alpha.md", true, ""},
		{"backslashes", `Notes\Alpha.md`, "Notes/Alpha.md", true, ""},
		{"dot segment", "Notes/./Alpha.md", "Notes/Alpha.md", true, ""},
		{"new note", "Notes/New idea.md", "Notes/New idea.md", false, ""},
		{"new folder", "Projects/Plan.md", "Projects/Plan.md", false, ""},
		{"empty", "", "", false, OutsideVault},
		{"absolute", "/etc/passwd.md", "", false, OutsideVault},
		{"windows drive", `C:\x.md`, "", false, OutsideVault},
		{"parent", "../x.md", "", false, OutsideVault},
		{"parent inside", "Notes/../../x.md", "", false, OutsideVault},
		{"hidden folder", ".obsidian/app.md", "", false, OutsideVault},
		{"hidden file", "Notes/.secret.md", "", false, OutsideVault},
		{"not markdown", "Notes/Alpha.txt", "", false, InvalidNote},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := v.resolve(tc.id)
			if tc.wantCode != "" {
				wantCode(t, err, tc.wantCode)
				return
			}
			if err != nil {
				t.Fatalf("resolve(%q): %v", tc.id, err)
			}
			if got.ID != tc.wantID || got.Exists != tc.wantExists {
				t.Fatalf("resolve(%q) = %q exists=%v, want %q exists=%v", tc.id, got.ID, got.Exists, tc.wantID, tc.wantExists)
			}
		})
	}
}

func TestResolveRejectsFolder(t *testing.T) {
	v := newVault(t, map[string]string{"Odd.md/inner.md": "x"})
	_, err := v.resolve("Odd.md")
	wantCode(t, err, InvalidNote)
}

func TestResolveRejectsSymlinkEscape(t *testing.T) {
	v := newVault(t, nil)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret.md"), []byte("s"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(v.Root, "Escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	_, err := v.resolve("Escape/secret.md")
	wantCode(t, err, OutsideVault)
	_, err = v.resolve("Escape/new.md")
	wantCode(t, err, OutsideVault)
}

func TestResolveMatchesUnicodeNormalisation(t *testing.T) {
	v := newVault(t, map[string]string{"Notes/Cafe\u0301.md": "c"}) // decomposed é on disk
	got, err := v.resolve("Notes/Caf\u00e9.md")                       // composed é from the caller
	if err != nil {
		t.Fatal(err)
	}
	if !got.Exists || got.ID != "Notes/Caf\u00e9.md" {
		t.Fatalf("got %+v, want existing note with NFC ID", got)
	}
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `go test ./internal/vault/ -run 'TestOpen|TestResolve' -v`
Expected: FAIL to compile, with `undefined: Open` and `v.resolve undefined`.

- [ ] **Step 4: Write the implementation**

`internal/vault/path.go`:

```go
package vault

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/text/unicode/norm"
)

// Vault is an open Memory Vault folder.
type Vault struct {
	Root string // absolute path with symlinks resolved
}

// Open checks that dir is a folder and returns the vault rooted there.
func Open(dir string) (*Vault, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return nil, fmt.Errorf("vault folder %s: %w", dir, err)
	}
	info, err := os.Stat(real)
	if err != nil {
		return nil, fmt.Errorf("vault folder %s: %w", dir, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("vault folder %s is not a folder", dir)
	}
	return &Vault{Root: real}, nil
}

// target is a note ID checked against the vault.
type target struct {
	ID     string // vault-relative, forward slashes, NFC, spelled as on disk where it exists
	Abs    string // absolute path on disk
	Exists bool
}

// resolve checks a note ID and finds its file. Existing files and folders match ignoring case and
// Unicode normalisation. The file does not need to exist.
func (v *Vault) resolve(id string) (target, error) {
	raw := strings.TrimSpace(strings.ReplaceAll(id, "\\", "/"))
	if raw == "" {
		return target{}, errorf(OutsideVault, "note ID is empty; use a vault-relative path such as Notes/Example.md")
	}
	if strings.HasPrefix(raw, "/") || strings.Contains(raw, ":") {
		return target{}, errorf(OutsideVault, "%q is an absolute path; use a vault-relative note ID such as Notes/Example.md", id)
	}
	clean := path.Clean(norm.NFC.String(raw))
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return target{}, errorf(OutsideVault, "%q points outside the vault", id)
	}
	parts := strings.Split(clean, "/")
	for _, p := range parts {
		if strings.HasPrefix(p, ".") {
			return target{}, errorf(OutsideVault, "%q is hidden; folders and files starting with . are not notes", id)
		}
	}
	if strings.ToLower(path.Ext(clean)) != ".md" {
		return target{}, errorf(InvalidNote, "%q is not a Markdown note; note IDs end in .md", id)
	}

	abs, exists := v.Root, true
	idParts := make([]string, len(parts))
	for i, p := range parts {
		name := p
		if exists {
			if found, ok := lookup(abs, p); ok {
				name = found
			} else {
				exists = false
			}
		}
		abs = filepath.Join(abs, name)
		idParts[i] = norm.NFC.String(name)
	}
	if err := v.checkInside(abs); err != nil {
		return target{}, err
	}
	if exists {
		if info, err := os.Stat(abs); err == nil && info.IsDir() {
			return target{}, errorf(InvalidNote, "%q is a folder, not a note", id)
		}
	}
	return target{ID: strings.Join(idParts, "/"), Abs: abs, Exists: exists}, nil
}

// lookup finds the entry of dir called name: exactly after NFC normalisation, or else ignoring case.
func lookup(dir, name string) (string, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	for _, e := range entries {
		if norm.NFC.String(e.Name()) == name {
			return e.Name(), true
		}
	}
	for _, e := range entries {
		if strings.EqualFold(norm.NFC.String(e.Name()), name) {
			return e.Name(), true
		}
	}
	return "", false
}

// checkInside rejects a path whose deepest existing part resolves, through symlinks, outside the vault.
func (v *Vault) checkInside(abs string) error {
	p := abs
	for {
		if _, err := os.Lstat(p); err == nil {
			break
		}
		parent := filepath.Dir(p)
		if parent == p {
			break
		}
		p = parent
	}
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		return errorf(OutsideVault, "cannot resolve the note's location")
	}
	rel, err := filepath.Rel(v.Root, real)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return errorf(OutsideVault, "the note's location leads outside the vault through a link")
	}
	return nil
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `go test ./internal/vault/ -v`
Expected: every test passes. On a machine without symlink permission, `TestResolveRejectsSymlinkEscape` reports SKIP.

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "feat: open vaults and resolve note IDs with confinement" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Reading notes and listing the vault

**Files:**
- Create: `internal/vault/note.go`, `internal/vault/index.go`
- Test: `internal/vault/note_test.go`

**Interfaces:**
- Consumes: `Vault`, `resolve`, `target`, `errorf`, `newVault`, `wantCode`.
- Produces:
  - `type Note struct { ID, Title, Content string; Frontmatter map[string]any; Links []string; Version string }` with JSON tags `id`, `title`, `content`, `frontmatter,omitempty`, `links`, `version`.
  - `func (v *Vault) Read(id string) (Note, error)`.
  - `func versionOf(b []byte) string`, `func titleOf(id string) string`, `func readNote(t target) ([]byte, error)`.
  - `func splitFrontmatter(text string) (yamlText, body string, ok bool)`, `func parseFrontmatter(text string) map[string]any`.
  - `type Entry struct { ID, Title, Modified string; abs string }` with JSON tags `id`, `title`, `modified`.
  - `func (v *Vault) notes() ([]Entry, error)` and `func (v *Vault) List(folder string, recursive bool) ([]Entry, error)`.

- [ ] **Step 1: Add the YAML dependency**

```bash
go get gopkg.in/yaml.v3@latest
```

- [ ] **Step 2: Write the failing tests**

`internal/vault/note_test.go`:

```go
package vault

import (
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestRead(t *testing.T) {
	body := "---\ntags: [ai, notes]\ncreated: 2026-01-02\n---\n# Alpha\nText.\n"
	v := newVault(t, map[string]string{"Notes/Alpha.md": body})
	n, err := v.Read("notes/alpha.md")
	if err != nil {
		t.Fatal(err)
	}
	if n.ID != "Notes/Alpha.md" || n.Title != "Alpha" || n.Content != body {
		t.Fatalf("got %+v", n)
	}
	sum := sha256.Sum256([]byte(body))
	if n.Version != hex.EncodeToString(sum[:]) {
		t.Fatalf("version = %s", n.Version)
	}
	if tags, _ := n.Frontmatter["tags"].([]any); len(tags) != 2 || tags[0] != "ai" {
		t.Fatalf("tags = %#v", n.Frontmatter["tags"])
	}
	if created, _ := n.Frontmatter["created"].(string); !strings.HasPrefix(created, "2026-01-02") {
		t.Fatalf("created = %#v, want a string starting 2026-01-02", n.Frontmatter["created"])
	}
	if n.Links == nil {
		t.Fatal("links must be an empty list, not nil")
	}
}

func TestReadErrors(t *testing.T) {
	v := newVault(t, map[string]string{"Bad.md": "\xff\xfe"})
	_, err := v.Read("Missing.md")
	wantCode(t, err, NotFound)
	_, err = v.Read("Bad.md")
	wantCode(t, err, InvalidNote)
}

func TestFrontmatter(t *testing.T) {
	cases := map[string]bool{
		"no properties\n":                 false,
		"---\n---\nempty block\n":         false,
		"---\nkey: [unclosed\n---\nbody\n": false,
		"---\r\nkey: value\r\n---\r\nbody": true,
	}
	for text, want := range cases {
		if got := parseFrontmatter(text) != nil; got != want {
			t.Errorf("parseFrontmatter(%q) present = %v, want %v", text, got, want)
		}
	}
	_, body, ok := splitFrontmatter("---\na: 1\n---\nHello\n")
	if !ok || body != "Hello\n" {
		t.Fatalf("body = %q ok = %v", body, ok)
	}
}

func TestList(t *testing.T) {
	v := newVault(t, map[string]string{
		"Home.md": "", "Notes/A.md": "", "Notes/Deep/B.md": "",
		".obsidian/x.md": "", "Notes/.hidden.md": "", "Notes/readme.txt": "",
	})
	ids := func(es []Entry) []string {
		out := []string{}
		for _, e := range es {
			out = append(out, e.ID)
		}
		return out
	}
	all, err := v.List("", true)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(all); !slices.Equal(got, []string{"Home.md", "Notes/A.md", "Notes/Deep/B.md"}) {
		t.Fatalf("all = %v", got)
	}
	if _, err := time.Parse(time.RFC3339, all[0].Modified); err != nil {
		t.Fatalf("modified %q is not RFC 3339", all[0].Modified)
	}
	notes, _ := v.List("notes/", true)
	if got := ids(notes); !slices.Equal(got, []string{"Notes/A.md", "Notes/Deep/B.md"}) {
		t.Fatalf("notes = %v", got)
	}
	flat, _ := v.List("Notes", false)
	if got := ids(flat); !slices.Equal(got, []string{"Notes/A.md"}) {
		t.Fatalf("flat = %v", got)
	}
	_, err = v.List("../x", true)
	wantCode(t, err, OutsideVault)
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `go test ./internal/vault/ -run 'TestRead|TestFrontmatter|TestList' -v`
Expected: FAIL to compile, with `v.Read undefined` and `undefined: parseFrontmatter`.

- [ ] **Step 4: Write `note.go`**

```go
package vault

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path"
	"strings"
	"unicode/utf8"

	"gopkg.in/yaml.v3"
)

// Note is one note as tools return it.
type Note struct {
	ID          string         `json:"id"`
	Title       string         `json:"title"`
	Content     string         `json:"content"`
	Frontmatter map[string]any `json:"frontmatter,omitempty"`
	Links       []string       `json:"links"`
	Version     string         `json:"version"`
}

// Read returns a note with its parsed properties, outgoing links and version.
func (v *Vault) Read(id string) (Note, error) {
	t, err := v.resolve(id)
	if err != nil {
		return Note{}, err
	}
	if !t.Exists {
		return Note{}, errorf(NotFound, "no note %q; use vault_search or vault_list to find notes", id)
	}
	data, err := readNote(t)
	if err != nil {
		return Note{}, err
	}
	text := string(data)
	return Note{
		ID:          t.ID,
		Title:       titleOf(t.ID),
		Content:     text,
		Frontmatter: parseFrontmatter(text),
		Links:       []string{},
		Version:     versionOf(data),
	}, nil
}

// readNote reads an existing note's bytes and checks they are UTF-8.
func readNote(t target) ([]byte, error) {
	data, err := os.ReadFile(t.Abs)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(data) {
		return nil, errorf(InvalidNote, "%q is not valid UTF-8 text", t.ID)
	}
	return data, nil
}

func versionOf(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func titleOf(id string) string {
	return strings.TrimSuffix(path.Base(id), path.Ext(id))
}

// splitFrontmatter returns the YAML properties block (without its fences) and the body after it,
// with line endings converted to LF. ok is false when the note has no properties block.
func splitFrontmatter(text string) (yamlText, body string, ok bool) {
	lf := strings.ReplaceAll(text, "\r\n", "\n")
	if !strings.HasPrefix(lf, "---\n") {
		return "", lf, false
	}
	rest := lf[len("---\n"):]
	if rest == "---" || strings.HasPrefix(rest, "---\n") {
		return "", strings.TrimPrefix(strings.TrimPrefix(rest, "---"), "\n"), true
	}
	search := 0
	for {
		i := strings.Index(rest[search:], "\n---")
		if i < 0 {
			return "", lf, false
		}
		end := search + i
		after := rest[end+len("\n---"):]
		if after == "" || strings.HasPrefix(after, "\n") {
			return rest[:end], strings.TrimPrefix(after, "\n"), true
		}
		search = end + 1
	}
}

// parseFrontmatter returns a note's properties as plain JSON values, or nil if it has none or they don't parse.
func parseFrontmatter(text string) map[string]any {
	y, _, ok := splitFrontmatter(text)
	if !ok || strings.TrimSpace(y) == "" {
		return nil
	}
	var raw map[string]any
	if err := yaml.Unmarshal([]byte(y), &raw); err != nil || len(raw) == 0 {
		return nil
	}
	// Round-trip through JSON so every value is a plain JSON type (dates become strings).
	b, err := json.Marshal(raw)
	if err != nil {
		return nil
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		return nil
	}
	return out
}
```

- [ ] **Step 5: Write `index.go`**

```go
package vault

import (
	"io/fs"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"
)

// Entry is one note in a listing.
type Entry struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Modified string `json:"modified"` // RFC 3339, UTC
	abs      string
}

// notes walks the vault and returns every note, sorted by ID. Hidden entries and symlinks are skipped.
func (v *Vault) notes() ([]Entry, error) {
	out := []Entry{}
	err := filepath.WalkDir(v.Root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip parts we can't read
		}
		if p == v.Root {
			return nil
		}
		if strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() || d.Type()&fs.ModeSymlink != 0 || strings.ToLower(filepath.Ext(d.Name())) != ".md" {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		rel, err := filepath.Rel(v.Root, p)
		if err != nil {
			return nil
		}
		id := norm.NFC.String(filepath.ToSlash(rel))
		out = append(out, Entry{ID: id, Title: titleOf(id), Modified: info.ModTime().UTC().Format(time.RFC3339), abs: p})
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, err
}

// List returns the notes under folder ("" for the whole vault). With recursive false, only notes directly in it.
func (v *Vault) List(folder string, recursive bool) ([]Entry, error) {
	prefix, err := cleanFolder(folder)
	if err != nil {
		return nil, err
	}
	all, err := v.notes()
	if err != nil {
		return nil, err
	}
	out := []Entry{}
	for _, e := range all {
		rest := e.ID
		if prefix != "" {
			if len(e.ID) <= len(prefix) || e.ID[len(prefix)] != '/' || !strings.EqualFold(e.ID[:len(prefix)], prefix) {
				continue
			}
			rest = e.ID[len(prefix)+1:]
		}
		if !recursive && strings.Contains(rest, "/") {
			continue
		}
		out = append(out, e)
	}
	return out, nil
}

// cleanFolder turns a folder argument into a vault-relative prefix without slashes at either end.
func cleanFolder(folder string) (string, error) {
	f := strings.Trim(strings.ReplaceAll(strings.TrimSpace(folder), "\\", "/"), "/")
	if f == "" || f == "." {
		return "", nil
	}
	c := path.Clean(norm.NFC.String(f))
	if c == ".." || strings.HasPrefix(c, "../") || strings.Contains(c, ":") {
		return "", errorf(OutsideVault, "folder %q is outside the vault", folder)
	}
	return c, nil
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `go test ./internal/vault/ -v`
Expected: every test passes.

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "feat: read notes with properties and versions, list the vault" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Wikilinks and backlinks

**Files:**
- Create: `internal/vault/links.go`
- Modify: `internal/vault/note.go` (`Read` fills `Links`)
- Test: `internal/vault/links_test.go`

**Interfaces:**
- Consumes: `Entry`, `notes()`, `resolve`, `readNote`, `target`.
- Produces: `var wikilink *regexp.Regexp`. `type linkIndex struct { byStem map[string][]string; byPath map[string]string }`. `func newLinkIndex(entries []Entry) linkIndex`. `func (li linkIndex) resolve(target string) string`. `func (li linkIndex) outgoing(text string) []string`. `func (v *Vault) Backlinks(id string) ([]string, error)`.

- [ ] **Step 1: Write the failing tests**

`internal/vault/links_test.go`:

```go
package vault

import (
	"slices"
	"testing"
)

func TestReadLinks(t *testing.T) {
	v := newVault(t, map[string]string{
		"Home.md":        "[[Alpha]] [[alpha|label]] [[Alpha#Part]] [[Notes/Beta]] [[Beta.md]] [[Other/Alpha]] [[Missing]]",
		"Alpha.md":       "",
		"Notes/Alpha.md": "",
		"Notes/Beta.md":  "",
	})
	n, err := v.Read("Home.md")
	if err != nil {
		t.Fatal(err)
	}
	// Shortest ID wins for [[Alpha]]; [[Other/Alpha]] falls back to the name; duplicates appear once.
	if want := []string{"Alpha.md", "Notes/Beta.md"}; !slices.Equal(n.Links, want) {
		t.Fatalf("links = %v, want %v", n.Links, want)
	}
}

func TestLinkWithExactPath(t *testing.T) {
	v := newVault(t, map[string]string{"Home.md": "[[Notes/Alpha]]", "Alpha.md": "", "Notes/Alpha.md": ""})
	n, err := v.Read("Home.md")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"Notes/Alpha.md"}; !slices.Equal(n.Links, want) {
		t.Fatalf("links = %v, want %v", n.Links, want)
	}
}

func TestBacklinks(t *testing.T) {
	v := newVault(t, map[string]string{
		"Home.md":      "[[Alpha]]",
		"Notes/Map.md": "see [[Alpha|it]] and [[Alpha]]",
		"Alpha.md":     "[[Alpha]] links to itself",
		"Other.md":     "no links",
	})
	got, err := v.Backlinks("alpha.md")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"Home.md", "Notes/Map.md"}; !slices.Equal(got, want) {
		t.Fatalf("backlinks = %v, want %v", got, want)
	}
	_, err = v.Backlinks("Nope.md")
	wantCode(t, err, NotFound)
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/vault/ -run 'Link' -v`
Expected: FAIL. `TestReadLinks` reports `links = []`, and `Backlinks` is undefined.

- [ ] **Step 3: Write `links.go`**

```go
package vault

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

var wikilink = regexp.MustCompile(`\[\[([^\]]+)\]\]`)

// linkIndex finds the note a wikilink names, following the rules in SPEC.md.
type linkIndex struct {
	byStem map[string][]string // lowercased title -> IDs, shortest first
	byPath map[string]string   // lowercased ID without .md -> ID
}

func newLinkIndex(entries []Entry) linkIndex {
	li := linkIndex{byStem: map[string][]string{}, byPath: map[string]string{}}
	for _, e := range entries {
		li.byStem[strings.ToLower(e.Title)] = append(li.byStem[strings.ToLower(e.Title)], e.ID)
		li.byPath[strings.ToLower(strings.TrimSuffix(e.ID, ".md"))] = e.ID
	}
	for _, ids := range li.byStem {
		sort.Slice(ids, func(i, j int) bool {
			if len(ids[i]) != len(ids[j]) {
				return len(ids[i]) < len(ids[j])
			}
			return ids[i] < ids[j]
		})
	}
	return li
}

// resolve returns the ID a wikilink target means, or "" when no note matches.
func (li linkIndex) resolve(target string) string {
	name := target
	if i := strings.Index(name, "|"); i >= 0 {
		name = name[:i]
	}
	if i := strings.Index(name, "#"); i >= 0 {
		name = name[:i]
	}
	key := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(norm.NFC.String(name))), ".md")
	if strings.Contains(key, "/") {
		if id, ok := li.byPath[key]; ok {
			return id
		}
		key = key[strings.LastIndex(key, "/")+1:]
	}
	if ids := li.byStem[key]; len(ids) > 0 {
		return ids[0]
	}
	return ""
}

// outgoing returns the notes a text links to, in order, each once.
func (li linkIndex) outgoing(text string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, m := range wikilink.FindAllStringSubmatch(text, -1) {
		if id := li.resolve(m[1]); id != "" && !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// Backlinks returns the notes, other than the note itself, that link to it.
func (v *Vault) Backlinks(id string) ([]string, error) {
	t, err := v.resolve(id)
	if err != nil {
		return nil, err
	}
	if !t.Exists {
		return nil, errorf(NotFound, "no note %q", id)
	}
	entries, err := v.notes()
	if err != nil {
		return nil, err
	}
	li := newLinkIndex(entries)
	out := []string{}
	for _, e := range entries {
		if e.ID == t.ID {
			continue
		}
		data, err := os.ReadFile(e.abs)
		if err != nil || !utf8.Valid(data) {
			continue
		}
		for _, linked := range li.outgoing(string(data)) {
			if linked == t.ID {
				out = append(out, e.ID)
				break
			}
		}
	}
	return out, nil
}
```

- [ ] **Step 4: Make `Read` fill in links**

In `internal/vault/note.go`, replace the body of `Read` from `text := string(data)` to the end of the function with:

```go
	text := string(data)
	entries, err := v.notes()
	if err != nil {
		return Note{}, err
	}
	return Note{
		ID:          t.ID,
		Title:       titleOf(t.ID),
		Content:     text,
		Frontmatter: parseFrontmatter(text),
		Links:       newLinkIndex(entries).outgoing(text),
		Version:     versionOf(data),
	}, nil
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `go test ./internal/vault/ -v`
Expected: every test passes, including `TestRead` (`Links` is still a non-nil empty list there).

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "feat: resolve wikilinks and find backlinks" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Search

This is a direct port of ClaudeDesk's `Sources/ClaudeDesk/VaultSearch.swift`, so agents and the Cockpit rank results the same way.

**Files:**
- Create: `internal/vault/search.go`
- Test: `internal/vault/search_test.go`

**Interfaces:**
- Consumes: `List`, `Entry` (including unexported `abs`), `splitFrontmatter`.
- Produces: `type Match struct { ID, Title, Snippet string; score int }` with JSON tags `id`, `title`, `snippet`. `func (v *Vault) Search(query, folder string, limit int) ([]Match, error)`. `func readable(markdown, title string) string`. `func snippet(terms []string, body string, width int) string`.

- [ ] **Step 1: Write the failing tests**

`internal/vault/search_test.go`:

```go
package vault

import (
	"slices"
	"strings"
	"testing"
)

func searchVault(t *testing.T) *Vault {
	return newVault(t, map[string]string{
		"Notes/LangGraph basics.md": "# LangGraph basics\nGraphs of agents.",
		"Notes/Agents.md":           "Notes about langgraph and other tools.",
		"Maps/Tools.md":             "---\ntags: [langgraph]\n---\nNothing here.",
		"Archive/Old langgraph.md":  "old",
	})
}

func matchIDs(ms []Match) []string {
	out := []string{}
	for _, m := range ms {
		out = append(out, m.ID)
	}
	return out
}

func TestSearchRanking(t *testing.T) {
	v := searchVault(t)
	got, err := v.Search("LangGraph", "", 20)
	if err != nil {
		t.Fatal(err)
	}
	// Title prefix (720) > title contains (520) > body only (4). Properties are not searched.
	want := []string{"Notes/LangGraph basics.md", "Archive/Old langgraph.md", "Notes/Agents.md"}
	if ids := matchIDs(got); !slices.Equal(ids, want) {
		t.Fatalf("got %v, want %v", ids, want)
	}
}

func TestSearchNeedsEveryWord(t *testing.T) {
	v := searchVault(t)
	got, _ := v.Search("langgraph tools", "", 20)
	if ids := matchIDs(got); !slices.Equal(ids, []string{"Notes/Agents.md"}) {
		t.Fatalf("got %v", ids)
	}
}

func TestSearchFolderLimitAndEmpty(t *testing.T) {
	v := searchVault(t)
	got, _ := v.Search("langgraph", "Notes", 20)
	if ids := matchIDs(got); !slices.Equal(ids, []string{"Notes/LangGraph basics.md", "Notes/Agents.md"}) {
		t.Fatalf("folder: got %v", ids)
	}
	if got, _ := v.Search("langgraph", "", 1); len(got) != 1 {
		t.Fatalf("limit: got %d results", len(got))
	}
	got, err := v.Search("   ", "", 20)
	if err != nil || got == nil || len(got) != 0 {
		t.Fatalf("empty query: got %v, %v; want an empty non-nil list", got, err)
	}
}

func TestSnippet(t *testing.T) {
	body := strings.Repeat("a ", 60) + "needle" + strings.Repeat(" b", 60)
	s := snippet([]string{"needle"}, body, 90)
	if !strings.HasPrefix(s, "…") || !strings.HasSuffix(s, "…") || !strings.Contains(s, "needle") {
		t.Fatalf("snippet = %q", s)
	}
	if s := snippet([]string{"zzz"}, "short   text", 90); s != "short text" {
		t.Fatalf("no-hit snippet = %q", s)
	}
}

func TestReadable(t *testing.T) {
	got := readable("# Title\n- see [[Other|the other note]] and [docs](https://x.y)\n**bold** `code`", "Title")
	if got != "see the other note and docs\nbold code" {
		t.Fatalf("readable = %q", got)
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/vault/ -run 'TestSearch|TestSnippet|TestReadable' -v`
Expected: FAIL to compile, with `v.Search undefined`.

- [ ] **Step 3: Write `search.go`**

```go
package vault

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

// Match is one search result.
type Match struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Snippet string `json:"snippet"`
	score   int
}

const (
	defaultLimit = 20
	maxLimit     = 100
	snippetWidth = 90
)

// Search finds notes where every word of query appears in the title, path or text (properties excluded).
// Results are ranked like ClaudeDesk's Cockpit search: title matches first, then path, then text.
func (v *Vault) Search(query, folder string, limit int) ([]Match, error) {
	if limit <= 0 {
		limit = defaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	out := []Match{}
	phrase := strings.ToLower(strings.TrimSpace(query))
	terms := strings.Fields(phrase)
	if len(terms) == 0 {
		return out, nil
	}
	entries, err := v.List(folder, true)
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		data, err := os.ReadFile(e.abs)
		if err != nil || !utf8.Valid(data) {
			continue
		}
		_, body, _ := splitFrontmatter(string(data))
		if m, ok := score(e, readable(body, e.Title), phrase, terms); ok {
			out = append(out, m)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].score != out[j].score {
			return out[i].score > out[j].score
		}
		return strings.ToLower(out[i].Title) < strings.ToLower(out[j].Title)
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func score(e Entry, body, phrase string, terms []string) (Match, bool) {
	title, p, text := strings.ToLower(e.Title), strings.ToLower(e.ID), strings.ToLower(body)
	for _, t := range terms {
		if !strings.Contains(title, t) && !strings.Contains(p, t) && !strings.Contains(text, t) {
			return Match{}, false
		}
	}
	s := 0
	switch {
	case title == phrase:
		s += 1000
	case strings.HasPrefix(title, phrase):
		s += 600
	case strings.Contains(title, phrase):
		s += 400
	}
	for _, t := range terms {
		if strings.Contains(title, t) {
			if strings.HasPrefix(title, t) || strings.Contains(title, " "+t) {
				s += 120
			} else {
				s += 80
			}
		} else if strings.Contains(p, t) {
			s += 40
		}
		s += min(20, strings.Count(text, t)*4)
	}
	return Match{ID: e.ID, Title: e.Title, Snippet: snippet(terms, body, snippetWidth), score: s}, true
}

var (
	reWikilinkLabel = regexp.MustCompile(`\[\[([^\]|]*\|)?([^\]]*)\]\]`)
	reMarkdownLink  = regexp.MustCompile(`\[([^\]]*)\]\([^)]*\)`)
	reLineMarker    = regexp.MustCompile(`(?m)^\s*(#{1,6}|>|[-*+]|\d+\.)\s+`)
	reEmphasis      = regexp.MustCompile("[*`~]")
	reSpace         = regexp.MustCompile(`\s+`)
)

// readable is a note's text as it reads: no Markdown marks, wikilinks as their label, and no opening
// heading that only repeats the title. Underscores stay, since they are usually part of names.
func readable(markdown, title string) string {
	lines := strings.Split(markdown, "\n")
	for i, l := range lines {
		tl := strings.TrimSpace(l)
		if tl == "" {
			continue
		}
		if strings.HasPrefix(tl, "#") && strings.EqualFold(strings.Trim(tl, "# "), title) {
			lines = append(lines[:i], lines[i+1:]...)
		}
		break
	}
	text := strings.Join(lines, "\n")
	text = reWikilinkLabel.ReplaceAllString(text, "$2")
	text = reMarkdownLink.ReplaceAllString(text, "$1")
	text = reLineMarker.ReplaceAllString(text, "")
	return reEmphasis.ReplaceAllString(text, "")
}

// snippet is about width characters around the first matching word, on one line, with ellipses where cut.
func snippet(terms []string, body string, width int) string {
	flat := []rune(strings.TrimSpace(reSpace.ReplaceAllString(body, " ")))
	lower := strings.ToLower(string(flat))
	hit := -1
	if utf8.RuneCountInString(lower) == len(flat) { // offsets only map back when lowercasing kept the length
		for _, t := range terms {
			if i := strings.Index(lower, t); i >= 0 {
				if r := utf8.RuneCountInString(lower[:i]); hit < 0 || r < hit {
					hit = r
				}
			}
		}
	}
	if hit < 0 {
		return string(flat[:min(width, len(flat))])
	}
	start := max(0, hit-width/3)
	end := min(len(flat), start+width)
	s := string(flat[start:end])
	if start > 0 {
		s = "…" + s
	}
	if end < len(flat) {
		s += "…"
	}
	return s
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `go test ./internal/vault/ -v`
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add .
git commit -m "feat: search ranked like the ClaudeDesk Cockpit" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Cross-platform file lock

**Files:**
- Create: `internal/lock/lock.go`, `internal/lock/lock_unix.go`, `internal/lock/lock_windows.go`
- Test: `internal/lock/lock_test.go`

**Interfaces:**
- Produces: `var ErrTimeout error`. `type Lock struct`. `func Acquire(path string, wait time.Duration) (*Lock, error)`. `func (l *Lock) Release() error`.

- [ ] **Step 1: Add the go dependency**

```bash
go get golang.org/x/sys@latest
```

- [ ] **Step 2: Write the failing test**

`internal/lock/lock_test.go`:

```go
package lock

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestAcquireExcludesSecondHolder(t *testing.T) {
	p := filepath.Join(t.TempDir(), "write.lock")
	first, err := Acquire(p, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if _, err := Acquire(p, 100*time.Millisecond); !errors.Is(err, ErrTimeout) {
		t.Fatalf("second Acquire = %v, want ErrTimeout", err)
	}
	if time.Since(start) < 100*time.Millisecond {
		t.Fatal("gave up before the wait elapsed")
	}
	if err := first.Release(); err != nil {
		t.Fatal(err)
	}
	second, err := Acquire(p, time.Second)
	if err != nil {
		t.Fatalf("Acquire after Release: %v", err)
	}
	if err := second.Release(); err != nil {
		t.Fatal(err)
	}
}
```

- [ ] **Step 3: Run the test to see it fail**

Run: `go test ./internal/lock/ -v`
Expected: FAIL to compile, with `undefined: Acquire`.

- [ ] **Step 4: Write the implementation**

`internal/lock/lock.go`:

```go
// Package lock provides an exclusive, cross-process file lock with a bounded wait.
package lock

import (
	"errors"
	"os"
	"time"
)

// ErrTimeout means another holder kept the lock for the whole wait.
var ErrTimeout = errors.New("lock: timed out waiting for the lock")

// Lock is a held lock. Release it when done.
type Lock struct{ f *os.File }

// Acquire takes an exclusive lock on the file at path, creating the file if needed. It retries until wait elapses.
func Acquire(path string, wait time.Duration) (*Lock, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(wait)
	for {
		ok, err := tryLock(f)
		if err != nil {
			f.Close()
			return nil, err
		}
		if ok {
			return &Lock{f: f}, nil
		}
		if time.Now().After(deadline) {
			f.Close()
			return nil, ErrTimeout
		}
		time.Sleep(25 * time.Millisecond)
	}
}

// Release unlocks and closes the lock file.
func (l *Lock) Release() error {
	err := unlock(l.f)
	if cerr := l.f.Close(); err == nil {
		err = cerr
	}
	return err
}
```

`internal/lock/lock_unix.go`:

```go
//go:build darwin || linux

package lock

import (
	"errors"
	"os"
	"syscall"
)

func tryLock(f *os.File) (bool, error) {
	err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return false, nil
	}
	return false, err
}

func unlock(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}
```

`internal/lock/lock_windows.go`:

```go
//go:build windows

package lock

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

func tryLock(f *os.File) (bool, error) {
	ol := new(windows.Overlapped)
	err := windows.LockFileEx(windows.Handle(f.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, ol)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
		return false, nil
	}
	return false, err
}

func unlock(f *os.File) error {
	ol := new(windows.Overlapped)
	return windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, ol)
}
```

- [ ] **Step 5: Run the test to see it pass, and cross-compile for Windows**

Run: `go test ./internal/lock/ -v && GOOS=windows GOARCH=amd64 go vet ./internal/lock/`
Expected: `TestAcquireExcludesSecondHolder` PASS, and `go vet` prints nothing. The vet run proves the Windows file compiles; CI runs the test on Windows in Task 11.

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "feat: cross-platform write lock with bounded wait" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Safe writes: write, append, edit

**Files:**
- Create: `internal/vault/write.go`
- Test: `internal/vault/write_test.go`, `internal/vault/concurrency_test.go`

**Interfaces:**
- Consumes: `resolve`, `target`, `readNote`, `versionOf`, `errorf`, `Error`, `lock.Acquire`, `lock.ErrTimeout`.
- Produces: `type Saved struct { ID, Version string }` with JSON tags `id`, `version`. `func (v *Vault) Write(id, content, version string) (Saved, error)`. `func (v *Vault) Append(id, text, version string) (Saved, error)`. `func (v *Vault) Edit(id, oldText, newText, version string) (Saved, error)`.

- [ ] **Step 1: Write the failing tests**

`internal/vault/write_test.go`:

```go
package vault

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readFile(t *testing.T, v *Vault, id string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(v.Root, filepath.FromSlash(id)))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestWrite(t *testing.T) {
	v := newVault(t, map[string]string{"Notes/Alpha.md": "old\n"})

	saved, err := v.Write("Projects/New.md", "line1\r\nline2\r\n", "")
	if err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, v, "Projects/New.md"); got != "line1\nline2\n" {
		t.Fatalf("new note = %q, want LF line endings", got)
	}
	if saved.ID != "Projects/New.md" || saved.Version != versionOf([]byte("line1\nline2\n")) {
		t.Fatalf("saved = %+v", saved)
	}

	_, err = v.Write("Notes/Alpha.md", "x", "")
	wantCode(t, err, Exists)
	_, err = v.Write("notes/ALPHA.md", "x", "") // differs only in case
	wantCode(t, err, Exists)

	_, err = v.Write("Notes/Alpha.md", "x", "wrong")
	wantCode(t, err, StaleVersion)
	var e *Error
	if !errors.As(err, &e) || e.CurrentVersion != versionOf([]byte("old\n")) {
		t.Fatalf("stale error should carry the current version, got %v", err)
	}

	saved, err = v.Write("notes/alpha.md", "new\n", versionOf([]byte("old\n")))
	if err != nil {
		t.Fatal(err)
	}
	if saved.ID != "Notes/Alpha.md" || readFile(t, v, "Notes/Alpha.md") != "new\n" {
		t.Fatalf("replace failed: %+v %q", saved, readFile(t, v, "Notes/Alpha.md"))
	}

	_, err = v.Write("Notes/Ghost.md", "x", "abc")
	wantCode(t, err, NotFound)
	_, err = v.Write("../escape.md", "x", "")
	wantCode(t, err, OutsideVault)
	_, err = v.Write("Notes/Bad.md", "\xff", "")
	wantCode(t, err, InvalidNote)
}

func TestWriteKeepsCRLF(t *testing.T) {
	start := "a\r\nb\r\n"
	v := newVault(t, map[string]string{"Win.md": start})
	if _, err := v.Write("Win.md", "c\nd\n", versionOf([]byte(start))); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, v, "Win.md"); got != "c\r\nd\r\n" {
		t.Fatalf("got %q, want CRLF kept", got)
	}
}

func TestAppend(t *testing.T) {
	v := newVault(t, map[string]string{"Log.md": "first"})
	if _, err := v.Append("Log.md", "second", ""); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, v, "Log.md"); got != "first\nsecond\n" {
		t.Fatalf("got %q", got)
	}
	_, err := v.Append("Log.md", "third", "stale")
	wantCode(t, err, StaleVersion)
	if _, err := v.Append("Inbox/New.md", "hello", ""); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, v, "Inbox/New.md"); got != "hello\n" {
		t.Fatalf("got %q", got)
	}
}

func TestEdit(t *testing.T) {
	start := "# Plan\r\nstep one\r\nstep two\r\n"
	v := newVault(t, map[string]string{"Plan.md": start})
	ver := versionOf([]byte(start))

	_, err := v.Edit("Plan.md", "step one", "step 1", "")
	wantCode(t, err, StaleVersion)
	_, err = v.Edit("Plan.md", "missing", "x", ver)
	wantCode(t, err, NoMatch)
	_, err = v.Edit("Plan.md", "step", "x", ver)
	wantCode(t, err, AmbiguousMatch)
	_, err = v.Edit("Plan.md", "", "x", ver)
	wantCode(t, err, NoMatch)
	_, err = v.Edit("Ghost.md", "a", "b", ver)
	wantCode(t, err, NotFound)

	if _, err := v.Edit("Plan.md", "step one\nstep two", "step 1\nstep 2", ver); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, v, "Plan.md"); got != "# Plan\r\nstep 1\r\nstep 2\r\n" {
		t.Fatalf("got %q", got)
	}
}

func TestWriteLeavesNoTempFiles(t *testing.T) {
	v := newVault(t, nil)
	if _, err := v.Write("Notes/A.md", "a", ""); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(v.Root, "Notes"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("temp file left behind: %s", e.Name())
		}
	}
}
```

`internal/vault/concurrency_test.go`:

```go
package vault

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
)

// TestHelperAppend is the second process in TestConcurrentAppendsLoseNothing. It does nothing on its own.
func TestHelperAppend(t *testing.T) {
	dir := os.Getenv("BRAINVAULT_HELPER_VAULT")
	if dir == "" {
		t.Skip("helper process only")
	}
	v, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 50; i++ {
		if _, err := v.Append("Log.md", fmt.Sprintf("proc-%d", i), ""); err != nil {
			t.Fatal(err)
		}
	}
}

func TestConcurrentAppendsLoseNothing(t *testing.T) {
	v := newVault(t, map[string]string{"Log.md": ""})
	helper := exec.Command(os.Args[0], "-test.run=^TestHelperAppend$")
	helper.Env = append(os.Environ(), "BRAINVAULT_HELPER_VAULT="+v.Root)
	if err := helper.Start(); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 25; i++ {
				if _, err := v.Append("Log.md", fmt.Sprintf("g%d-%d", g, i), ""); err != nil {
					t.Error(err)
				}
			}
		}(g)
	}
	wg.Wait()
	if err := helper.Wait(); err != nil {
		t.Fatalf("helper process: %v", err)
	}
	if lines := strings.Fields(readFile(t, v, "Log.md")); len(lines) != 150 {
		t.Fatalf("got %d lines, want 150 (4×25 from goroutines + 50 from the second process)", len(lines))
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/vault/ -run 'TestWrite|TestAppend|TestEdit|TestConcurrent' -v`
Expected: FAIL to compile, with `v.Write undefined`.

- [ ] **Step 3: Write `write.go`**

```go
package vault

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/poom-h/brainvault/internal/lock"
)

const lockWait = 5 * time.Second

// Saved is the result of a change: the note's ID as stored and its new version.
type Saved struct {
	ID      string `json:"id"`
	Version string `json:"version"`
}

// Write creates a note (version "") or replaces a whole note (version from the last read).
func (v *Vault) Write(id, content, version string) (Saved, error) {
	var saved Saved
	err := v.withLock(func() error {
		t, err := v.resolve(id)
		if err != nil {
			return err
		}
		if !utf8.ValidString(content) {
			return errorf(InvalidNote, "content is not valid UTF-8 text")
		}
		if !t.Exists {
			if version != "" {
				return errorf(NotFound, "no note %q to replace; omit version to create it", id)
			}
			saved, err = writeAtomic(t, []byte(toLF(content)), 0o644)
			return err
		}
		old, err := readNote(t)
		if err != nil {
			return err
		}
		current := versionOf(old)
		if version == "" {
			return &Error{Code: Exists, Message: fmt.Sprintf("%q already exists; read it and pass its version to replace it", t.ID), CurrentVersion: current}
		}
		if version != current {
			return stale(t.ID, current)
		}
		saved, err = writeAtomic(t, []byte(restoreEOL(toLF(content), old)), modeOf(t.Abs))
		return err
	})
	return saved, err
}

// Append adds text on a new line at the end of a note, creating it if missing. version is optional.
func (v *Vault) Append(id, text, version string) (Saved, error) {
	var saved Saved
	err := v.withLock(func() error {
		t, err := v.resolve(id)
		if err != nil {
			return err
		}
		if !utf8.ValidString(text) {
			return errorf(InvalidNote, "text is not valid UTF-8")
		}
		if !t.Exists {
			if version != "" {
				return errorf(NotFound, "no note %q; omit version to create it", id)
			}
			saved, err = writeAtomic(t, []byte(ensureNewline(toLF(text))), 0o644)
			return err
		}
		old, err := readNote(t)
		if err != nil {
			return err
		}
		if current := versionOf(old); version != "" && version != current {
			return stale(t.ID, current)
		}
		s := toLF(string(old))
		if s != "" && !strings.HasSuffix(s, "\n") {
			s += "\n"
		}
		s += ensureNewline(toLF(text))
		saved, err = writeAtomic(t, []byte(restoreEOL(s, old)), modeOf(t.Abs))
		return err
	})
	return saved, err
}

// Edit replaces the one place oldText appears in a note with newText. version is required.
func (v *Vault) Edit(id, oldText, newText, version string) (Saved, error) {
	var saved Saved
	err := v.withLock(func() error {
		t, err := v.resolve(id)
		if err != nil {
			return err
		}
		if !t.Exists {
			return errorf(NotFound, "no note %q", id)
		}
		if !utf8.ValidString(newText) {
			return errorf(InvalidNote, "new_text is not valid UTF-8")
		}
		old, err := readNote(t)
		if err != nil {
			return err
		}
		current := versionOf(old)
		if version == "" {
			return &Error{Code: StaleVersion, Message: "pass the version from your last vault_read of this note", CurrentVersion: current}
		}
		if version != current {
			return stale(t.ID, current)
		}
		s, find := toLF(string(old)), toLF(oldText)
		if find == "" {
			return errorf(NoMatch, "old_text is empty")
		}
		switch n := strings.Count(s, find); {
		case n == 0:
			return errorf(NoMatch, "old_text does not appear in %q; read the note again and copy the passage exactly", t.ID)
		case n > 1:
			return errorf(AmbiguousMatch, "old_text appears %d times in %q; include more surrounding text so it appears once", n, t.ID)
		}
		s = strings.Replace(s, find, toLF(newText), 1)
		saved, err = writeAtomic(t, []byte(restoreEOL(s, old)), modeOf(t.Abs))
		return err
	})
	return saved, err
}

func stale(id, current string) *Error {
	return &Error{Code: StaleVersion, Message: fmt.Sprintf("%q changed since you read it; read it again, merge your change, and retry", id), CurrentVersion: current}
}

// withLock runs fn while holding the vault's write lock.
func (v *Vault) withLock(fn func() error) error {
	dir := filepath.Join(v.Root, ".brainvault")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	l, err := lock.Acquire(filepath.Join(dir, "write.lock"), lockWait)
	if errors.Is(err, lock.ErrTimeout) {
		return errorf(Locked, "another writer is holding the vault; retry shortly")
	}
	if err != nil {
		return err
	}
	defer l.Release()
	return fn()
}

// writeAtomic writes data to a temp file beside the note, then renames it over the note.
func writeAtomic(t target, data []byte, mode fs.FileMode) (Saved, error) {
	dir := filepath.Dir(t.Abs)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Saved{}, err
	}
	tmp, err := os.CreateTemp(dir, ".brainvault-*.tmp")
	if err != nil {
		return Saved{}, err
	}
	name := tmp.Name()
	defer os.Remove(name) // does nothing after a successful rename
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return Saved{}, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return Saved{}, err
	}
	if err := tmp.Close(); err != nil {
		return Saved{}, err
	}
	if err := os.Chmod(name, mode); err != nil {
		return Saved{}, err
	}
	if err := os.Rename(name, t.Abs); err != nil {
		return Saved{}, err
	}
	return Saved{ID: t.ID, Version: versionOf(data)}, nil
}

func modeOf(abs string) fs.FileMode {
	if info, err := os.Stat(abs); err == nil {
		return info.Mode().Perm()
	}
	return 0o644
}

func toLF(s string) string { return strings.ReplaceAll(s, "\r\n", "\n") }

// restoreEOL gives LF text the line endings of the original file.
func restoreEOL(lf string, original []byte) string {
	if bytes.Contains(original, []byte("\r\n")) {
		return strings.ReplaceAll(lf, "\n", "\r\n")
	}
	return lf
}

func ensureNewline(s string) string {
	if strings.HasSuffix(s, "\n") {
		return s
	}
	return s + "\n"
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `go test ./internal/vault/ -v -race`
Expected: every test passes with no race reports. `TestHelperAppend` shows SKIP when run directly.

- [ ] **Step 5: Commit**

```bash
git add .
git commit -m "feat: confined, stale-checked, atomic, locked writes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Audit log

**Files:**
- Create: `internal/audit/audit.go`
- Test: `internal/audit/audit_test.go`

**Interfaces:**
- Produces: `type Entry struct { Time, Actor, Tool, ID, Folder, Query string; Results []string; Outcome string }` with JSON tags `time`, `actor`, `tool`, `id,omitempty`, `folder,omitempty`, `query,omitempty`, `results,omitempty`, `outcome`. `type Log struct`. `func New(vaultRoot string) *Log`. `func (l *Log) Path() string`. `func (l *Log) Record(e Entry) error`.

- [ ] **Step 1: Write the failing test**

`internal/audit/audit_test.go`:

```go
package audit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRecordAppendsJSONLines(t *testing.T) {
	root := t.TempDir()
	l := New(root)
	l.now = func() time.Time { return time.Date(2026, 11, 7, 9, 0, 0, 0, time.UTC) }

	if err := l.Record(Entry{Actor: "atlas", Tool: "vault_read", ID: "Home.md", Outcome: "ok"}); err != nil {
		t.Fatal(err)
	}
	if err := l.Record(Entry{Actor: "atlas", Tool: "vault_search", Query: "graph", Results: []string{"A.md"}, Outcome: "ok"}); err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, ".brainvault", "audit.jsonl"); l.Path() != want {
		t.Fatalf("Path() = %s, want %s", l.Path(), want)
	}
	data, err := os.ReadFile(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2:\n%s", len(lines), data)
	}
	var first Entry
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatal(err)
	}
	if first.Time != "2026-11-07T09:00:00Z" || first.ID != "Home.md" || first.Actor != "atlas" {
		t.Fatalf("first = %+v", first)
	}
	if strings.Contains(lines[0], "query") {
		t.Fatalf("empty fields should be omitted: %s", lines[0])
	}
}
```

- [ ] **Step 2: Run the test to see it fail**

Run: `go test ./internal/audit/ -v`
Expected: FAIL to compile, with `undefined: New`.

- [ ] **Step 3: Write `audit.go`**

```go
// Package audit appends one JSON line per tool call to <vault>/.brainvault/audit.jsonl.
// Entries never contain note content.
package audit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Entry is one logged call.
type Entry struct {
	Time    string   `json:"time"`
	Actor   string   `json:"actor"`
	Tool    string   `json:"tool"`
	ID      string   `json:"id,omitempty"`
	Folder  string   `json:"folder,omitempty"`
	Query   string   `json:"query,omitempty"`
	Results []string `json:"results,omitempty"`
	Outcome string   `json:"outcome"`
}

// Log appends entries to a vault's audit file.
type Log struct {
	path string
	mu   sync.Mutex
	now  func() time.Time
}

// New returns the log for the vault rooted at vaultRoot.
func New(vaultRoot string) *Log {
	return &Log{path: filepath.Join(vaultRoot, ".brainvault", "audit.jsonl"), now: time.Now}
}

// Path is the audit file's location.
func (l *Log) Path() string { return l.path }

// Record appends one entry, filling in Time when it is empty.
func (l *Log) Record(e Entry) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if e.Time == "" {
		e.Time = l.now().UTC().Format(time.RFC3339Nano)
	}
	line, err := json.Marshal(e)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(l.path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(line, '\n'))
	return err
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `go test ./internal/audit/ -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add .
git commit -m "feat: JSONL audit log of tool calls" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: MCP server over stdio

**Files:**
- Create: `internal/mcpserver/server.go`, `cmd/brainvault/main.go`
- Test: `cmd/brainvault/e2e_test.go`

**Interfaces:**
- Consumes: `vault.Open`, `Read`, `List`, `Backlinks`, `Search`, `Write`, `Append`, `Edit`, `Note`, `Entry`, `Match`, `Saved`, `OutcomeOf`; `audit.New`, `audit.Entry`, `(*audit.Log).Record`.
- Produces: `func mcpserver.New(v *vault.Vault, log *audit.Log, actor, version string) *mcp.Server`. In `cmd/brainvault`: `func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int`, `func envOr(key, fallback string) string`, `var version string`. Test helpers `makeVault(t, files) string` and `cleanEnv(extra ...string) []string`.

- [ ] **Step 1: Add the MCP SDK**

```bash
go get github.com/modelcontextprotocol/go-sdk@latest
```

Expected: `go.mod` lists `github.com/modelcontextprotocol/go-sdk v1.x.y`.

- [ ] **Step 2: Write the failing end-to-end test**

`cmd/brainvault/e2e_test.go`:

```go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var binary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "brainvault-e2e-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary = filepath.Join(dir, "brainvault")
	if runtime.GOOS == "windows" {
		binary += ".exe"
	}
	if out, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "go build: %v\n%s", err, out)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// cleanEnv is this process's environment without BRAINVAULT_ settings, plus extra.
func cleanEnv(extra ...string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "BRAINVAULT_") {
			env = append(env, kv)
		}
	}
	return append(env, extra...)
}

func makeVault(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func connect(t *testing.T, dir string) *mcp.ClientSession {
	t.Helper()
	cmd := exec.Command(binary, "mcp")
	cmd.Env = cleanEnv("BRAINVAULT_PATH="+dir, "BRAINVAULT_ACTOR=e2e")
	client := mcp.NewClient(&mcp.Implementation{Name: "e2e", Version: "test"}, nil)
	session, err := client.Connect(context.Background(), &mcp.CommandTransport{Command: cmd}, nil)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(func() { session.Close() })
	return session
}

// call runs a tool and returns its structured result, or the error text when the tool failed.
func call(t *testing.T, s *mcp.ClientSession, tool string, args map[string]any) (map[string]any, string) {
	t.Helper()
	res, err := s.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", tool, err)
	}
	if res.IsError {
		for _, c := range res.Content {
			if tc, ok := c.(*mcp.TextContent); ok {
				return nil, tc.Text
			}
		}
		return nil, "(no error text)"
	}
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%s: structured result %s: %v", tool, raw, err)
	}
	return out, ""
}

func mustCall(t *testing.T, s *mcp.ClientSession, tool string, args map[string]any) map[string]any {
	t.Helper()
	out, errText := call(t, s, tool, args)
	if errText != "" {
		t.Fatalf("%s failed: %s", tool, errText)
	}
	return out
}

func TestToolsOverStdio(t *testing.T) {
	dir := makeVault(t, map[string]string{
		"Home.md":        "# Home\nStart at [[Alpha]].\n",
		"Notes/Alpha.md": "# Alpha\nAbout graphs.\n",
	})
	s := connect(t, dir)
	ctx := context.Background()

	tools, err := s.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, tool := range tools.Tools {
		names[tool.Name] = true
	}
	for _, want := range []string{"vault_search", "vault_read", "vault_list", "vault_backlinks", "vault_write", "vault_append", "vault_edit"} {
		if !names[want] {
			t.Errorf("tool %s is missing", want)
		}
	}

	read := mustCall(t, s, "vault_read", map[string]any{"id": "Notes/Alpha.md"})
	version, _ := read["version"].(string)
	if read["title"] != "Alpha" || version == "" {
		t.Fatalf("vault_read = %v", read)
	}

	edited := mustCall(t, s, "vault_edit", map[string]any{
		"id": "Notes/Alpha.md", "old_text": "About graphs.", "new_text": "About graphs and agents.", "version": version,
	})
	if edited["version"] == version {
		t.Fatal("vault_edit did not change the version")
	}
	if _, errText := call(t, s, "vault_edit", map[string]any{
		"id": "Notes/Alpha.md", "old_text": "agents", "new_text": "x", "version": version,
	}); !strings.HasPrefix(errText, "stale_version") {
		t.Fatalf("edit with an old version: got %q, want stale_version", errText)
	}

	mustCall(t, s, "vault_write", map[string]any{"id": "Notes/Beta.md", "content": "# Beta\nLinks to [[Alpha]].\n"})
	mustCall(t, s, "vault_append", map[string]any{"id": "Notes/Beta.md", "text": "More."})

	found := mustCall(t, s, "vault_search", map[string]any{"query": "agents"})
	results, _ := found["results"].([]any)
	if len(results) != 1 || results[0].(map[string]any)["id"] != "Notes/Alpha.md" {
		t.Fatalf("vault_search = %v", found)
	}

	back := mustCall(t, s, "vault_backlinks", map[string]any{"id": "Notes/Alpha.md"})
	if ids, _ := back["ids"].([]any); len(ids) != 2 {
		t.Fatalf("vault_backlinks = %v, want Home.md and Notes/Beta.md", back)
	}

	list := mustCall(t, s, "vault_list", map[string]any{"folder": "Notes"})
	if notes, _ := list["notes"].([]any); len(notes) != 2 {
		t.Fatalf("vault_list = %v", list)
	}

	if _, errText := call(t, s, "vault_read", map[string]any{"id": "../outside.md"}); !strings.HasPrefix(errText, "outside_vault") {
		t.Fatalf("read outside the vault: got %q", errText)
	}

	data, err := os.ReadFile(filepath.Join(dir, ".brainvault", "audit.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	log := string(data)
	for _, want := range []string{`"actor":"e2e"`, `"tool":"vault_edit"`, `"outcome":"stale_version"`, `"tool":"vault_search"`, `"results":["Notes/Alpha.md"]`} {
		if !strings.Contains(log, want) {
			t.Errorf("audit log is missing %s", want)
		}
	}
	if strings.Contains(log, "About graphs") {
		t.Error("audit log must not contain note content")
	}
}

func TestStartupFailsWithoutVault(t *testing.T) {
	cmd := exec.Command(binary, "mcp")
	cmd.Env = cleanEnv()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		t.Fatalf("want a non-zero exit, got %v", err)
	}
	if !strings.Contains(stderr.String(), "BRAINVAULT_PATH") {
		t.Fatalf("stderr = %q, want it to mention BRAINVAULT_PATH", stderr.String())
	}
}
```

- [ ] **Step 3: Run the test to see it fail**

Run: `go test ./cmd/brainvault/ -v`
Expected: FAIL. `TestMain` reports `go build: … no Go files` (or `no non-test Go files`).

- [ ] **Step 4: Write `internal/mcpserver/server.go`**

```go
// Package mcpserver exposes a vault as MCP tools. It only translates between MCP and the vault package.
package mcpserver

import (
	"context"
	"fmt"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/poom-h/brainvault/internal/audit"
	"github.com/poom-h/brainvault/internal/vault"
)

type SearchIn struct {
	Query  string `json:"query" jsonschema:"words to find; every word must appear in the note's title, path or text"`
	Folder string `json:"folder,omitempty" jsonschema:"only search notes under this vault folder, such as Notes"`
	Limit  int    `json:"limit,omitempty" jsonschema:"maximum results, default 20, at most 100"`
}

type SearchOut struct {
	Results []vault.Match `json:"results"`
}

type IDIn struct {
	ID string `json:"id" jsonschema:"note ID: the vault-relative path with forward slashes, such as Notes/Example.md"`
}

type ListIn struct {
	Folder    string `json:"folder,omitempty" jsonschema:"vault folder to list, such as Notes; omit for the whole vault"`
	Recursive *bool  `json:"recursive,omitempty" jsonschema:"include notes in subfolders; default true"`
}

type ListOut struct {
	Notes []vault.Entry `json:"notes"`
}

type BacklinksOut struct {
	IDs []string `json:"ids"`
}

type WriteIn struct {
	ID      string `json:"id" jsonschema:"note ID: the vault-relative path with forward slashes, such as Notes/Example.md"`
	Content string `json:"content" jsonschema:"the note's full Markdown"`
	Version string `json:"version,omitempty" jsonschema:"to replace an existing note, the version from your last vault_read; omit to create a new note"`
}

type AppendIn struct {
	ID      string `json:"id" jsonschema:"note ID: the vault-relative path with forward slashes, such as Notes/Example.md"`
	Text    string `json:"text" jsonschema:"Markdown to add at the end, on a new line"`
	Version string `json:"version,omitempty" jsonschema:"optional: the version from your last vault_read, to fail if the note changed"`
}

type EditIn struct {
	ID      string `json:"id" jsonschema:"note ID: the vault-relative path with forward slashes, such as Notes/Example.md"`
	OldText string `json:"old_text" jsonschema:"the exact passage to replace; it must appear exactly once"`
	NewText string `json:"new_text" jsonschema:"the replacement text"`
	Version string `json:"version" jsonschema:"the version from your last vault_read of this note"`
}

type server struct {
	vault *vault.Vault
	log   *audit.Log
	actor string
}

// New returns an MCP server with the seven vault tools.
func New(v *vault.Vault, log *audit.Log, actor, version string) *mcp.Server {
	s := &server{vault: v, log: log, actor: actor}
	srv := mcp.NewServer(&mcp.Implementation{Name: "brainvault", Version: version}, nil)
	mcp.AddTool(srv, &mcp.Tool{Name: "vault_search", Description: "Search the Memory Vault. Every word must appear in a note's title, path or text; title matches rank first. Returns note IDs, titles and snippets."}, s.search)
	mcp.AddTool(srv, &mcp.Tool{Name: "vault_read", Description: "Read one note: its Markdown, parsed properties, the notes it links to, and its version. Pass the version back when you change the note."}, s.read)
	mcp.AddTool(srv, &mcp.Tool{Name: "vault_list", Description: "List notes, optionally under one folder, with titles and last-modified times."}, s.list)
	mcp.AddTool(srv, &mcp.Tool{Name: "vault_backlinks", Description: "List the notes that link to a note with [[wikilinks]]."}, s.backlinks)
	mcp.AddTool(srv, &mcp.Tool{Name: "vault_write", Description: "Create a note, or replace a whole note. To replace, pass the version from vault_read; omit version to create. Prefer vault_edit or vault_append for small changes."}, s.write)
	mcp.AddTool(srv, &mcp.Tool{Name: "vault_append", Description: "Add text to the end of a note on a new line, creating the note if it doesn't exist."}, s.append)
	mcp.AddTool(srv, &mcp.Tool{Name: "vault_edit", Description: "Replace one exact passage of a note. old_text must appear exactly once. Pass the version from vault_read; if the note changed since, read it again and retry."}, s.edit)
	return srv
}

func (s *server) record(tool string, e audit.Entry, err error) {
	e.Actor, e.Tool, e.Outcome = s.actor, tool, vault.OutcomeOf(err)
	if lerr := s.log.Record(e); lerr != nil {
		fmt.Fprintln(os.Stderr, "brainvault: cannot write the audit log:", lerr)
	}
}

// savedID is the stored ID after a successful change, or the ID the caller asked for.
func savedID(saved vault.Saved, asked string) string {
	if saved.ID != "" {
		return saved.ID
	}
	return asked
}

func (s *server) search(_ context.Context, _ *mcp.CallToolRequest, in SearchIn) (*mcp.CallToolResult, SearchOut, error) {
	matches, err := s.vault.Search(in.Query, in.Folder, in.Limit)
	ids := make([]string, 0, len(matches))
	for _, m := range matches {
		ids = append(ids, m.ID)
	}
	s.record("vault_search", audit.Entry{Query: in.Query, Folder: in.Folder, Results: ids}, err)
	if err != nil {
		return nil, SearchOut{}, err
	}
	return nil, SearchOut{Results: matches}, nil
}

func (s *server) read(_ context.Context, _ *mcp.CallToolRequest, in IDIn) (*mcp.CallToolResult, vault.Note, error) {
	note, err := s.vault.Read(in.ID)
	id := note.ID
	if id == "" {
		id = in.ID
	}
	s.record("vault_read", audit.Entry{ID: id}, err)
	if err != nil {
		return nil, vault.Note{}, err
	}
	return nil, note, nil
}

func (s *server) list(_ context.Context, _ *mcp.CallToolRequest, in ListIn) (*mcp.CallToolResult, ListOut, error) {
	recursive := in.Recursive == nil || *in.Recursive
	notes, err := s.vault.List(in.Folder, recursive)
	s.record("vault_list", audit.Entry{Folder: in.Folder}, err)
	if err != nil {
		return nil, ListOut{}, err
	}
	return nil, ListOut{Notes: notes}, nil
}

func (s *server) backlinks(_ context.Context, _ *mcp.CallToolRequest, in IDIn) (*mcp.CallToolResult, BacklinksOut, error) {
	ids, err := s.vault.Backlinks(in.ID)
	s.record("vault_backlinks", audit.Entry{ID: in.ID}, err)
	if err != nil {
		return nil, BacklinksOut{}, err
	}
	return nil, BacklinksOut{IDs: ids}, nil
}

func (s *server) write(_ context.Context, _ *mcp.CallToolRequest, in WriteIn) (*mcp.CallToolResult, vault.Saved, error) {
	saved, err := s.vault.Write(in.ID, in.Content, in.Version)
	s.record("vault_write", audit.Entry{ID: savedID(saved, in.ID)}, err)
	if err != nil {
		return nil, vault.Saved{}, err
	}
	return nil, saved, nil
}

func (s *server) append(_ context.Context, _ *mcp.CallToolRequest, in AppendIn) (*mcp.CallToolResult, vault.Saved, error) {
	saved, err := s.vault.Append(in.ID, in.Text, in.Version)
	s.record("vault_append", audit.Entry{ID: savedID(saved, in.ID)}, err)
	if err != nil {
		return nil, vault.Saved{}, err
	}
	return nil, saved, nil
}

func (s *server) edit(_ context.Context, _ *mcp.CallToolRequest, in EditIn) (*mcp.CallToolResult, vault.Saved, error) {
	saved, err := s.vault.Edit(in.ID, in.OldText, in.NewText, in.Version)
	s.record("vault_edit", audit.Entry{ID: savedID(saved, in.ID)}, err)
	if err != nil {
		return nil, vault.Saved{}, err
	}
	return nil, saved, nil
}
```

- [ ] **Step 5: Write `cmd/brainvault/main.go` (the `mcp` and `version` commands only; Task 10 adds the rest)**

```go
// Command brainvault serves a Markdown vault to agents as MCP tools.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/poom-h/brainvault/internal/audit"
	"github.com/poom-h/brainvault/internal/mcpserver"
	"github.com/poom-h/brainvault/internal/vault"
)

// version is set at release time with -ldflags "-X main.version=…".
var version = "dev"

func main() { os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: brainvault mcp | version")
		return 2
	}
	cmd, rest := args[0], args[1:]
	if cmd == "version" {
		fmt.Fprintln(stdout, version)
		return 0
	}
	if cmd != "mcp" {
		fmt.Fprintf(stderr, "brainvault: unknown command %q\n", cmd)
		return 2
	}
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	vaultPath := fs.String("vault", os.Getenv("BRAINVAULT_PATH"), "vault folder (default $BRAINVAULT_PATH)")
	actor := fs.String("actor", envOr("BRAINVAULT_ACTOR", "unknown"), "caller name recorded in the log (default $BRAINVAULT_ACTOR)")
	if err := fs.Parse(rest); err != nil {
		return 2
	}
	if *vaultPath == "" {
		fmt.Fprintln(stderr, "brainvault: no vault folder; set BRAINVAULT_PATH or pass --vault")
		return 1
	}
	v, err := vault.Open(*vaultPath)
	if err != nil {
		fmt.Fprintln(stderr, "brainvault:", err)
		return 1
	}
	srv := mcpserver.New(v, audit.New(v.Root), *actor, version)
	if err := srv.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		fmt.Fprintln(stderr, "brainvault:", err)
		return 1
	}
	return 0
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `go mod tidy && go test ./... -v`
Expected: every test passes, including `TestToolsOverStdio` and `TestStartupFailsWithoutVault`.
If `TestToolsOverStdio` fails with an output-schema validation error, the message names the field. Fix the Go type so that field always has a JSON value of its schema type: lists must never be `nil`, and optional fields need `omitempty`. Do not turn validation off.

- [ ] **Step 7: Try it with the MCP Inspector (manual check)**

```bash
go build -o brainvault ./cmd/brainvault
npx @modelcontextprotocol/inspector ./brainvault mcp --vault /Users/poomhirunwiwatkul/Documents/Code/BrainHub/ManageMyClaude/Resources/VaultTemplate
```

Expected: the Inspector lists seven tools, and `vault_list` returns the template's notes. Use only read tools here, so the template is not changed.

- [ ] **Step 8: Commit**

```bash
git add .
git commit -m "feat: MCP server with seven vault tools over stdio" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: CLI subcommands and `doctor`

**Files:**
- Create: `internal/vault/doctor.go`, `cmd/brainvault/cli.go`
- Modify: `cmd/brainvault/main.go` (full replacement below)
- Test: `internal/vault/doctor_test.go`, `cmd/brainvault/cli_test.go`

**Interfaces:**
- Consumes: everything in `internal/vault` and `internal/audit`, and `makeVault` from `e2e_test.go`.
- Produces: `type Report struct { Notes int; Errors, Warnings []string }` with JSON tags `notes`, `errors`, `warnings`. `func (v *Vault) Check() (Report, error)`. `func frontmatterProblem(text string) error`. In `cmd/brainvault`: `type cli struct` with the methods `search`, `read`, `list`, `backlinks`, `write` and `doctor`.

- [ ] **Step 1: Write the failing tests**

`internal/vault/doctor_test.go`:

```go
package vault

import (
	"strings"
	"testing"
)

func TestCheck(t *testing.T) {
	v := newVault(t, map[string]string{
		"Bad.md":         "---\nkey: [unclosed\n---\nbody\n",
		"Ok.md":          "[[Nowhere]] [[Alpha]]\n",
		"Alpha.md":       "",
		"Notes/Alpha.md": "",
		"Binary.md":      "\xff",
	})
	r, err := v.Check()
	if err != nil {
		t.Fatal(err)
	}
	if r.Notes != 5 {
		t.Fatalf("notes = %d, want 5", r.Notes)
	}
	joinedErrors := strings.Join(r.Errors, "\n")
	for _, want := range []string{"Bad.md: properties block", "Binary.md: not valid UTF-8"} {
		if !strings.Contains(joinedErrors, want) {
			t.Errorf("errors missing %q:\n%s", want, joinedErrors)
		}
	}
	joinedWarnings := strings.Join(r.Warnings, "\n")
	for _, want := range []string{"Ok.md: link [[Nowhere]] has no matching note", `notes share the name "alpha"`} {
		if !strings.Contains(joinedWarnings, want) {
			t.Errorf("warnings missing %q:\n%s", want, joinedWarnings)
		}
	}
}
```

`cmd/brainvault/cli_test.go`:

```go
package main

import (
	"bytes"
	"strings"
	"testing"
)

func runCLI(t *testing.T, stdin string, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := run(args, strings.NewReader(stdin), &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestCLI(t *testing.T) {
	dir := makeVault(t, map[string]string{"Home.md": "# Home\n[[Alpha]]\n", "Alpha.md": "about graphs\n"})

	code, out, errOut := runCLI(t, "# Gamma\nnew note\n", "write", "--vault", dir, "--actor", "cli-test", "Notes/Gamma.md")
	if code != 0 || !strings.Contains(out, `"version"`) {
		t.Fatalf("write: code %d out %q err %q", code, out, errOut)
	}
	if code, out, _ = runCLI(t, "", "read", "--vault", dir, "Notes/Gamma.md"); code != 0 || !strings.Contains(out, "new note") {
		t.Fatalf("read: code %d out %q", code, out)
	}
	if code, out, _ = runCLI(t, "", "search", "--vault", dir, "graphs"); code != 0 || !strings.Contains(out, `"Alpha.md"`) {
		t.Fatalf("search: code %d out %q", code, out)
	}
	if code, out, _ = runCLI(t, "", "backlinks", "--vault", dir, "Alpha.md"); code != 0 || !strings.Contains(out, "Home.md") {
		t.Fatalf("backlinks: code %d out %q", code, out)
	}
	if code, out, _ = runCLI(t, "", "list", "--vault", dir, "--folder", "Notes"); code != 0 || !strings.Contains(out, "Gamma") || strings.Contains(out, "Home.md") {
		t.Fatalf("list: code %d out %q", code, out)
	}
	if code, _, errOut = runCLI(t, "", "read", "--vault", dir, "../x.md"); code != 1 || !strings.Contains(errOut, "outside_vault") {
		t.Fatalf("read outside: code %d err %q", code, errOut)
	}
	if code, out, _ = runCLI(t, "", "doctor", "--vault", dir); code != 0 {
		t.Fatalf("doctor on a clean vault: code %d out %q", code, out)
	}
}

func TestDoctorExitsNonZeroOnErrors(t *testing.T) {
	dir := makeVault(t, map[string]string{"Bad.md": "---\nkey: [unclosed\n---\nbody\n"})
	code, out, _ := runCLI(t, "", "doctor", "--vault", dir)
	if code != 1 || !strings.Contains(out, "Bad.md: properties block") {
		t.Fatalf("doctor: code %d out %q", code, out)
	}
}

func TestCLIUsageErrors(t *testing.T) {
	if code, _, _ := runCLI(t, ""); code != 2 {
		t.Fatalf("no command: code %d, want 2", code)
	}
	if code, _, errOut := runCLI(t, "", "frobnicate", "--vault", t.TempDir()); code != 2 || !strings.Contains(errOut, "unknown command") {
		t.Fatalf("unknown command: code %d err %q", code, errOut)
	}
	t.Setenv("BRAINVAULT_PATH", "")
	if code, _, errOut := runCLI(t, "", "read", "Home.md"); code != 1 || !strings.Contains(errOut, "BRAINVAULT_PATH") {
		t.Fatalf("missing vault: code %d err %q", code, errOut)
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./... -run 'TestCheck|TestCLI|TestDoctor' -v`
Expected: FAIL to compile, with `v.Check undefined`. `TestCLI` reports the unknown command `write` once that compiles.

- [ ] **Step 3: Write `internal/vault/doctor.go`**

```go
package vault

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"unicode/utf8"

	"gopkg.in/yaml.v3"
)

// Report is the result of checking a vault against SPEC.md.
type Report struct {
	Notes    int      `json:"notes"`
	Errors   []string `json:"errors"`   // notes tools can't use correctly
	Warnings []string `json:"warnings"` // allowed, but probably not intended
}

// Check validates every note: readable, UTF-8, a properties block that parses, links that resolve, unique names.
func (v *Vault) Check() (Report, error) {
	entries, err := v.notes()
	if err != nil {
		return Report{}, err
	}
	li := newLinkIndex(entries)
	r := Report{Notes: len(entries), Errors: []string{}, Warnings: []string{}}
	for _, e := range entries {
		data, err := os.ReadFile(e.abs)
		if err != nil {
			r.Errors = append(r.Errors, fmt.Sprintf("%s: cannot read: %v", e.ID, err))
			continue
		}
		if !utf8.Valid(data) {
			r.Errors = append(r.Errors, fmt.Sprintf("%s: not valid UTF-8", e.ID))
			continue
		}
		text := string(data)
		if err := frontmatterProblem(text); err != nil {
			r.Errors = append(r.Errors, fmt.Sprintf("%s: properties block: %v", e.ID, err))
		}
		for _, m := range wikilink.FindAllStringSubmatch(text, -1) {
			if li.resolve(m[1]) == "" {
				r.Warnings = append(r.Warnings, fmt.Sprintf("%s: link [[%s]] has no matching note", e.ID, m[1]))
			}
		}
	}
	for stem, ids := range li.byStem {
		if len(ids) > 1 {
			r.Warnings = append(r.Warnings, fmt.Sprintf("notes share the name %q: %s; links by name go to %s", stem, strings.Join(ids, ", "), ids[0]))
		}
	}
	sort.Strings(r.Errors)
	sort.Strings(r.Warnings)
	return r, nil
}

// frontmatterProblem reports why a note's properties block doesn't parse, or nil.
func frontmatterProblem(text string) error {
	y, _, ok := splitFrontmatter(text)
	if !ok || strings.TrimSpace(y) == "" {
		return nil
	}
	var raw map[string]any
	return yaml.Unmarshal([]byte(y), &raw)
}
```

- [ ] **Step 4: Write `cmd/brainvault/cli.go`**

```go
package main

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/poom-h/brainvault/internal/audit"
	"github.com/poom-h/brainvault/internal/vault"
)

// cli runs one command against a vault and prints JSON. Calls are logged like MCP calls.
type cli struct {
	vault *vault.Vault
	log   *audit.Log
	actor string
	out   io.Writer
}

func (c cli) record(tool string, e audit.Entry, err error) {
	e.Actor, e.Tool, e.Outcome = c.actor, tool, vault.OutcomeOf(err)
	_ = c.log.Record(e) // a CLI call still succeeds if the log can't be written
}

func (c cli) print(v any) error {
	enc := json.NewEncoder(c.out)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func oneID(args []string) (string, error) {
	if len(args) != 1 {
		return "", fmt.Errorf("expected exactly one note ID (put flags before it)")
	}
	return args[0], nil
}

func (c cli) search(query, folder string, limit int) error {
	matches, err := c.vault.Search(query, folder, limit)
	ids := make([]string, 0, len(matches))
	for _, m := range matches {
		ids = append(ids, m.ID)
	}
	c.record("vault_search", audit.Entry{Query: query, Folder: folder, Results: ids}, err)
	if err != nil {
		return err
	}
	return c.print(matches)
}

func (c cli) read(args []string) error {
	id, err := oneID(args)
	if err != nil {
		return err
	}
	note, err := c.vault.Read(id)
	c.record("vault_read", audit.Entry{ID: id}, err)
	if err != nil {
		return err
	}
	return c.print(note)
}

func (c cli) list(folder string, recursive bool) error {
	notes, err := c.vault.List(folder, recursive)
	c.record("vault_list", audit.Entry{Folder: folder}, err)
	if err != nil {
		return err
	}
	return c.print(notes)
}

func (c cli) backlinks(args []string) error {
	id, err := oneID(args)
	if err != nil {
		return err
	}
	ids, err := c.vault.Backlinks(id)
	c.record("vault_backlinks", audit.Entry{ID: id}, err)
	if err != nil {
		return err
	}
	return c.print(ids)
}

func (c cli) write(args []string, version string, in io.Reader) error {
	id, err := oneID(args)
	if err != nil {
		return err
	}
	content, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	saved, err := c.vault.Write(id, string(content), version)
	c.record("vault_write", audit.Entry{ID: id}, err)
	if err != nil {
		return err
	}
	return c.print(saved)
}

// doctor prints the vault check and reports whether it found no errors.
func (c cli) doctor() (bool, error) {
	r, err := c.vault.Check()
	if err != nil {
		return false, err
	}
	return len(r.Errors) == 0, c.print(r)
}
```

- [ ] **Step 5: Replace `cmd/brainvault/main.go`**

```go
// Command brainvault serves a Markdown vault to agents as MCP tools, and offers the same operations as a CLI.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/poom-h/brainvault/internal/audit"
	"github.com/poom-h/brainvault/internal/mcpserver"
	"github.com/poom-h/brainvault/internal/vault"
)

// version is set at release time with -ldflags "-X main.version=…".
var version = "dev"

const usage = `brainvault: the Memory Vault as a tool

Usage:
  brainvault mcp                                      run the MCP server over stdio
  brainvault search [--folder F] [--limit N] QUERY
  brainvault read ID
  brainvault list [--folder F] [--flat]
  brainvault backlinks ID
  brainvault write [--version V] ID < content
  brainvault doctor                                   check the vault; exits 1 on errors
  brainvault version

Every command takes --vault (default $BRAINVAULT_PATH) and --actor (default $BRAINVAULT_ACTOR).
Put flags before the note ID or query.`

var commands = map[string]bool{"mcp": true, "search": true, "read": true, "list": true, "backlinks": true, "write": true, "doctor": true}

func main() { os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "help", "-h", "--help":
		fmt.Fprintln(stdout, usage)
		return 0
	case "version":
		fmt.Fprintln(stdout, version)
		return 0
	}
	if !commands[cmd] {
		fmt.Fprintf(stderr, "brainvault: unknown command %q\n\n%s\n", cmd, usage)
		return 2
	}

	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	vaultPath := fs.String("vault", os.Getenv("BRAINVAULT_PATH"), "vault folder (default $BRAINVAULT_PATH)")
	actor := fs.String("actor", envOr("BRAINVAULT_ACTOR", "unknown"), "caller name recorded in the log (default $BRAINVAULT_ACTOR)")
	folder := fs.String("folder", "", "limit to this vault folder (search, list)")
	limit := fs.Int("limit", 20, "maximum results (search)")
	flat := fs.Bool("flat", false, "only notes directly in the folder (list)")
	noteVersion := fs.String("version", "", "version from your last read, to replace a note (write)")
	if err := fs.Parse(rest); err != nil {
		return 2
	}
	if *vaultPath == "" {
		fmt.Fprintln(stderr, "brainvault: no vault folder; set BRAINVAULT_PATH or pass --vault")
		return 1
	}
	v, err := vault.Open(*vaultPath)
	if err != nil {
		fmt.Fprintln(stderr, "brainvault:", err)
		return 1
	}
	log := audit.New(v.Root)

	if cmd == "mcp" {
		srv := mcpserver.New(v, log, *actor, version)
		if err := srv.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
			fmt.Fprintln(stderr, "brainvault:", err)
			return 1
		}
		return 0
	}

	c := cli{vault: v, log: log, actor: *actor, out: stdout}
	switch cmd {
	case "search":
		err = c.search(strings.Join(fs.Args(), " "), *folder, *limit)
	case "read":
		err = c.read(fs.Args())
	case "list":
		err = c.list(*folder, !*flat)
	case "backlinks":
		err = c.backlinks(fs.Args())
	case "write":
		err = c.write(fs.Args(), *noteVersion, stdin)
	case "doctor":
		var clean bool
		clean, err = c.doctor()
		if err == nil && !clean {
			return 1
		}
	}
	if err != nil {
		fmt.Fprintln(stderr, "brainvault:", err)
		return 1
	}
	return 0
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `go test ./... -v`
Expected: every test passes, including `TestToolsOverStdio` from Task 9.

- [ ] **Step 7: Commit**

```bash
git add .
git commit -m "feat: CLI subcommands and vault doctor" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Conformance vaults, CI on three OSes, releases and README

**Files:**
- Create: `testdata/vaults/claudedesk-template/` (copied), `testdata/vaults/edge/` (generated)
- Create: `internal/vault/conformance_test.go`
- Create: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.goreleaser.yaml`, `README.md`

**Interfaces:**
- Consumes: `Open`, `Check`, `List`, `Read`, `Search`.
- Produces: release archives named `brainvault_<version>_<os>_<arch>`, which Plan 2 bundles into ClaudeDesk.

- [ ] **Step 1: Create the conformance vaults**

```bash
mkdir -p testdata/vaults
cp -R /Users/poomhirunwiwatkul/Documents/Code/BrainHub/ManageMyClaude/Resources/VaultTemplate testdata/vaults/claudedesk-template
E=testdata/vaults/edge
mkdir -p "$E/Notes" "$E/Deep/Er"
printf '# Home\n[[Alpha]] [[Notes/Alpha]] [[Crlf note]] [[Still a note|deep]]\n' > "$E/Home.md"
printf 'root alpha\n' > "$E/Alpha.md"
printf -- '---\ntags: [edge]\n---\nnested alpha\n' > "$E/Notes/Alpha.md"
printf 'first line\r\nsecond line\r\n' > "$E/Notes/Crlf note.md"
printf 'deep note\n' > "$E/Deep/Er/Still a note.md"
printf 'Ünïcödé title\n' > "$E/Notes/Ünïcödé.md"
```

- [ ] **Step 2: Write the conformance test**

`internal/vault/conformance_test.go`:

```go
package vault

import (
	"path/filepath"
	"testing"
)

// Every vault in testdata/vaults must pass the doctor and be fully readable and searchable.
func TestConformanceVaults(t *testing.T) {
	dirs, err := filepath.Glob(filepath.Join("..", "..", "testdata", "vaults", "*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(dirs) == 0 {
		t.Fatal("no conformance vaults in testdata/vaults")
	}
	for _, dir := range dirs {
		t.Run(filepath.Base(dir), func(t *testing.T) {
			v, err := Open(dir)
			if err != nil {
				t.Fatal(err)
			}
			r, err := v.Check()
			if err != nil {
				t.Fatal(err)
			}
			if len(r.Errors) > 0 {
				t.Fatalf("doctor errors: %v", r.Errors)
			}
			notes, err := v.List("", true)
			if err != nil || len(notes) == 0 {
				t.Fatalf("list: %d notes, %v", len(notes), err)
			}
			for _, n := range notes {
				if _, err := v.Read(n.ID); err != nil {
					t.Errorf("read %s: %v", n.ID, err)
				}
			}
			if _, err := v.Search("note", "", 20); err != nil {
				t.Errorf("search: %v", err)
			}
		})
	}
}
```

- [ ] **Step 3: Run it**

Run: `go test ./internal/vault/ -run TestConformanceVaults -v`
Expected: PASS for `claudedesk-template` and `edge`.
If the template reports doctor errors, they are real format problems in ClaudeDesk's `Resources/VaultTemplate`. Stop and report them to the user. Do not edit the copied template to make the test pass.

- [ ] **Step 4: Add CI**

`.github/workflows/ci.yml`:

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - run: go vet ./...
      - run: go test ./...
```

- [ ] **Step 5: Add GoReleaser config and the release workflow**

```bash
brew install goreleaser
```

`.goreleaser.yaml`:

```yaml
version: 2
project_name: brainvault
before:
  hooks:
    - go mod tidy
builds:
  - main: ./cmd/brainvault
    env:
      - CGO_ENABLED=0
    goos: [darwin, linux, windows]
    goarch: [amd64, arm64]
    ldflags:
      - -s -w -X main.version={{.Version}}
archives:
  - formats: [tar.gz]
    format_overrides:
      - goos: windows
        formats: [zip]
    files:
      - README.md
      - SPEC.md
checksum:
  name_template: checksums.txt
notarize:
  macos:
    - enabled: '{{ isEnvSet "MACOS_SIGN_P12" }}'
      sign:
        certificate: "{{.Env.MACOS_SIGN_P12}}"
        password: "{{.Env.MACOS_SIGN_PASSWORD}}"
      notarize:
        issuer_id: "{{.Env.MACOS_NOTARY_ISSUER_ID}}"
        key_id: "{{.Env.MACOS_NOTARY_KEY_ID}}"
        key: "{{.Env.MACOS_NOTARY_KEY}}"
        wait: true
```

`.github/workflows/release.yml`:

```yaml
name: release
on:
  push:
    tags: ["v*"]
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - uses: goreleaser/goreleaser-action@v6
        with:
          version: "~> v2"
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          MACOS_SIGN_P12: ${{ secrets.MACOS_SIGN_P12 }}
          MACOS_SIGN_PASSWORD: ${{ secrets.MACOS_SIGN_PASSWORD }}
          MACOS_NOTARY_ISSUER_ID: ${{ secrets.MACOS_NOTARY_ISSUER_ID }}
          MACOS_NOTARY_KEY_ID: ${{ secrets.MACOS_NOTARY_KEY_ID }}
          MACOS_NOTARY_KEY: ${{ secrets.MACOS_NOTARY_KEY }}
```

Signing and notarising run only when the `MACOS_SIGN_P12` secret is set. Without it, releases are unsigned. Adding the Apple Developer ID secrets is the user's step.

- [ ] **Step 6: Validate the release config and build every platform locally**

Run: `goreleaser check && goreleaser release --snapshot --clean && ls dist/*.tar.gz dist/*.zip`
Expected: `config is valid`, then 6 archives (darwin, linux and windows, each in amd64 and arm64).
If `goreleaser check` rejects a key, fix it using the GoReleaser docs for the installed version (`goreleaser --version`). Keep the same targets, ldflags and conditional notarising.

- [ ] **Step 7: Write the README**

`README.md`:

````markdown
# brainvault

The Memory Vault as a tool. `brainvault` serves a folder of Markdown notes (an Obsidian-style vault) to AI agents as MCP tools, and offers the same operations on the command line. It runs on macOS, Windows and Linux as a single binary.

## Tools

| Tool | What it does |
|---|---|
| `vault_search` | Find notes; every word must match the title, path or text |
| `vault_read` | A note's Markdown, properties, outgoing links and version |
| `vault_list` | Notes in the vault or one folder |
| `vault_backlinks` | Notes that link to a note |
| `vault_write` | Create a note, or replace one (pass its version) |
| `vault_append` | Add text to the end of a note |
| `vault_edit` | Replace one exact passage (pass its version) |

Changes are confined to the vault, rejected if the note changed since it was read (`stale_version`), written atomically under a lock, and logged to `<vault>/.brainvault/audit.jsonl` without note content. The format is described in [SPEC.md](SPEC.md).

## Use it from an MCP client

Add this to the client's MCP configuration (for Claude Code, a project's `.mcp.json`):

```json
{
  "mcpServers": {
    "brainvault": {
      "command": "/path/to/brainvault",
      "args": ["mcp"],
      "env": {
        "BRAINVAULT_PATH": "/path/to/your/vault",
        "BRAINVAULT_ACTOR": "my-agent"
      }
    }
  }
}
```

`BRAINVAULT_ACTOR` names the caller in the audit log.

## Command line

```sh
brainvault search --vault ~/Vault "langgraph agents"
brainvault read --vault ~/Vault "Notes/LangGraph basics.md"
brainvault doctor --vault ~/Vault
```

Run `brainvault help` for every command.

## Build

```sh
go test ./...
go build ./cmd/brainvault
```
````

- [ ] **Step 8: Run everything once more**

Run: `go vet ./... && go test ./... && GOOS=windows GOARCH=amd64 go vet ./...`
Expected: no vet output, and every package reports `ok`.

- [ ] **Step 9: Commit**

```bash
git add .
git commit -m "chore: conformance vaults, three-OS CI, releases and README" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 10: Publish (only with the user's go-ahead)**

Creating the public GitHub repository, pushing, and tagging `v0.1.0` are outward-facing steps. Ask the user first, then:

```bash
gh repo create poom-h/brainvault --public --source . --push
git tag v0.1.0 && git push origin v0.1.0
```

Expected: the CI workflow passes on all three OSes, and the release workflow publishes 6 archives plus `checksums.txt`.

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| SPEC.md vault format | 1 |
| `BRAINVAULT_PATH`, `BRAINVAULT_ACTOR`, `--vault`, `--actor` | 9, 10 |
| Seven MCP tools with the specified inputs and outputs | 3, 4, 5, 7, 9 |
| Search matches ClaudeDesk `VaultSearch` | 5 |
| Confinement: absolute, `..`, symlink escape, dot-folders, `.md` only | 2 |
| Stale-version checks | 7 |
| Atomic writes, creating missing folders | 7 |
| Lock file, 5-second wait, `flock` and `LockFileEx` | 6, 7 |
| Line endings and NFC | 2, 7 |
| Case-insensitive matching; case-only create fails `exists` | 2, 7 |
| Audit log without content | 8, 9 |
| Typed error codes; server never exits on a bad call | 1, 9 |
| Startup error, non-zero exit | 9 |
| Unit, concurrency, end-to-end, conformance tests; CI on three OSes | 2–11 |
| GoReleaser for six targets, checksums, signing and notarising | 11 |
| ClaudeDesk integration | Plan 2 |
