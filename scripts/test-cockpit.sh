#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/compiler-env.sh
swiftc -parse-as-library "${COMPILER_FLAGS[@]}" Sources/ClaudeDesk/Models.swift Sources/ClaudeDesk/AgentEnvironment.swift \
    Sources/ClaudeDesk/Workspace.swift Sources/ClaudeDesk/Frontmatter.swift Sources/ClaudeDesk/ActivityLog.swift \
    Sources/ClaudeDesk/SkillLibrary.swift Sources/ClaudeDesk/Inbox.swift Sources/ClaudeDesk/Routines.swift \
    Sources/ClaudeDesk/RoutineRunner.swift Sources/ClaudeDesk/RunSteps.swift Sources/ClaudeDesk/CockpitData.swift Sources/ClaudeDesk/Markdown.swift Sources/ClaudeDesk/AgentWidgets.swift Sources/ClaudeDesk/RoutineHistory.swift Sources/ClaudeDesk/VaultActivity.swift Sources/ClaudeDesk/VaultSearch.swift Sources/ClaudeDesk/MailModel.swift \
    scripts/cockpit-check.swift -o .build/cockpit-checks
.build/cockpit-checks
