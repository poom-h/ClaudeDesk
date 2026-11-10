#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/compiler-env.sh
swiftc -parse-as-library "${COMPILER_FLAGS[@]}" -I .build/SwiftTerm -L .build/SwiftTerm -lSwiftTerm \
    scripts/terminal-check.swift -o .build/terminal-checks
.build/terminal-checks
