#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/compiler-env.sh
mkdir -p .build/release
mkdir -p .build/SwiftTerm
find Vendor/SwiftTerm/Sources/SwiftTerm -name '*.swift' -not -path '*/iOS/*' -print > .build/SwiftTerm/sources.txt
if [[ ! -f .build/SwiftTerm/libSwiftTerm.a ]] || find Vendor/SwiftTerm/Sources/SwiftTerm -name '*.swift' -newer .build/SwiftTerm/libSwiftTerm.a | read -r; then
    swiftc -O -whole-module-optimization -emit-library -static -emit-module -module-name SwiftTerm \
        -swift-version 5 -target "$(uname -m)-apple-macosx14.0" "${COMPILER_FLAGS[@]}" \
        @.build/SwiftTerm/sources.txt -o .build/SwiftTerm/libSwiftTerm.a \
        -emit-module-path .build/SwiftTerm/SwiftTerm.swiftmodule
fi
swiftc -O -parse-as-library -module-name ClaudeDesk -target "$(uname -m)-apple-macosx14.0" \
    "${COMPILER_FLAGS[@]}" -I .build/SwiftTerm -L .build/SwiftTerm -lSwiftTerm Sources/ClaudeDesk/*.swift -o .build/release/ClaudeDesk
RUNNER_SOURCES=(Sources/ClaudeDesk/Models.swift Sources/ClaudeDesk/AgentEnvironment.swift Sources/ClaudeDesk/Workspace.swift
    Sources/ClaudeDesk/Frontmatter.swift Sources/ClaudeDesk/ActivityLog.swift Sources/ClaudeDesk/SkillLibrary.swift
    Sources/ClaudeDesk/Inbox.swift Sources/ClaudeDesk/Routines.swift Sources/ClaudeDesk/RoutineRunner.swift Sources/ClaudeDesk/RunSteps.swift Sources/ClaudeDesk/CockpitData.swift Runner/main.swift)
swiftc -O -module-name ClaudeDeskRunner -target "$(uname -m)-apple-macosx14.0" "${COMPILER_FLAGS[@]}" \
    "${RUNNER_SOURCES[@]}" -o .build/release/claudedesk-runner
APP="${APP_PATH:-$PWD/dist/ClaudeDesk.app}"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Vendor/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp .build/release/ClaudeDesk "$APP/Contents/MacOS/ClaudeDesk"
cp .build/release/claudedesk-runner "$APP/Contents/MacOS/claudedesk-runner"
cp design/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$APP/Contents/Resources/VaultTemplate"
cp -R Resources/VaultTemplate "$APP/Contents/Resources/VaultTemplate"
rm -rf "$APP/Contents/Resources/SkillTemplates"
cp -R Resources/SkillTemplates "$APP/Contents/Resources/SkillTemplates"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClaudeDesk</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.claudedesk.app</string>
<key>CFBundleName</key><string>ClaudeDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>3.7.0</string>
<key>CFBundleVersion</key><string>12</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>ClaudeDesk shows your upcoming events in the Cockpit's Schedule widget and gives Atlas your day when you ask. It only reads your calendars.</string>
<key>NSCalendarsUsageDescription</key><string>ClaudeDesk shows your upcoming events in the Cockpit's Schedule widget. It only reads your calendars.</string>
<key>NSAppleEventsUsageDescription</key><string>ClaudeDesk reads your recent inbox from Mail so Jev can sort it in the Cockpit. It only reads mail; it never sends, moves or deletes anything.</string>
</dict></plist>
PLIST
# Sign with the local "ClaudeDesk Local" certificate when it's in the keychain. Its identity stays the same across
# builds, so macOS keeps ClaudeDesk's permissions (Keychain, Documents, Calendar, Mail) after updates. Ad-hoc otherwise.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | awk '/"ClaudeDesk Local"/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/claudedesk-runner"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with ${IDENTITY:-ad-hoc signature}"
echo "Built $APP"
