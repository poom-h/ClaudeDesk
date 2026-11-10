#!/bin/bash
set -euo pipefail
CLAUDE_TEST_BIN="${CLAUDE_TEST_BIN:-$HOME/.local/bin/claude}"
SCOPE_TEST_ROOT=$(mktemp -d /tmp/claudedesk-scopes.XXXXXX)
trap 'rm -rf "$SCOPE_TEST_ROOT"' EXIT
mkdir -p "$SCOPE_TEST_ROOT/profile" "$SCOPE_TEST_ROOT/project" "$SCOPE_TEST_ROOT/agent/.runtime"
cd "$SCOPE_TEST_ROOT/project"
CLAUDE_CONFIG_DIR="$SCOPE_TEST_ROOT/profile" "$CLAUDE_TEST_BIN" mcp add-json --scope user -- global-probe '{"type":"http","url":"https://example.invalid/mcp"}'
CLAUDE_CONFIG_DIR="$SCOPE_TEST_ROOT/profile" "$CLAUDE_TEST_BIN" mcp add-json --scope local -- project-probe '{"type":"http","url":"https://example.invalid/mcp"}'
cd "$SCOPE_TEST_ROOT/agent"
CLAUDE_CONFIG_DIR="$SCOPE_TEST_ROOT/agent/.runtime" "$CLAUDE_TEST_BIN" mcp add-json --scope local -- agent-probe '{"type":"http","url":"https://example.invalid/mcp"}'
python3 - "$SCOPE_TEST_ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
normal='\n'.join(p.read_text() for p in (root/'profile').rglob('*.json'))
agent='\n'.join(p.read_text() for p in (root/'agent'/'.runtime').rglob('*.json'))
assert 'global-probe' in normal and 'project-probe' in normal
assert 'agent-probe' not in normal
assert 'agent-probe' in agent and 'global-probe' not in agent and 'project-probe' not in agent
assert not (root/'project'/'.mcp.json').exists()
print('Passed: user/local scopes, exact add-json arguments, and isolated agent profile; no real profile modified.')
PY
