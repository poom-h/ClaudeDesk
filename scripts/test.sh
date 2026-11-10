#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
source scripts/compiler-env.sh
swiftc -parse-as-library "${COMPILER_FLAGS[@]}" Sources/ClaudeDesk/Models.swift scripts/check.swift -o .build/checks
.build/checks
