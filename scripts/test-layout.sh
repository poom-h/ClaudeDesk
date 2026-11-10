#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/compiler-env.sh
swiftc -parse-as-library "${COMPILER_FLAGS[@]}" Sources/ClaudeDesk/WorkspaceLayout.swift scripts/layout-check.swift -o .build/layout-checks
.build/layout-checks
