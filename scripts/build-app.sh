#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/compiler-env.sh
mkdir -p .build/release
mkdir -p .build/SwiftTerm
find Vendor/SwiftTerm/Sources/SwiftTerm -name '*.swift' -not -path '*/iOS/*' -print > .build/SwiftTerm/sources.txt
RUNNER_SOURCES=(Sources/ClaudeDesk/Models.swift Sources/ClaudeDesk/AgentEnvironment.swift Sources/ClaudeDesk/MemoryTool.swift Sources/ClaudeDesk/Workspace.swift
    Sources/ClaudeDesk/Frontmatter.swift Sources/ClaudeDesk/ActivityLog.swift Sources/ClaudeDesk/SkillLibrary.swift
    Sources/ClaudeDesk/Inbox.swift Sources/ClaudeDesk/Routines.swift Sources/ClaudeDesk/RoutineRunner.swift Sources/ClaudeDesk/RunSteps.swift Sources/ClaudeDesk/CockpitData.swift Runner/main.swift)
# The app and runner are universal: built once per architecture, then joined with lipo. BUILD_ARCHS="arm64" builds
# one slice for a quicker local build. The host architecture's SwiftTerm stays in .build/SwiftTerm, where the test
# scripts link against it; other architectures get .build/SwiftTerm-<arch>.
HOST_ARCH="$(uname -m)"
read -r -a ARCHS <<< "${BUILD_ARCHS:-arm64 x86_64}"
for arch in "${ARCHS[@]}"; do
    if [[ "$arch" == "$HOST_ARCH" ]]; then ST=.build/SwiftTerm; else ST=".build/SwiftTerm-$arch"; fi
    mkdir -p "$ST" ".build/release/$arch"
    if [[ ! -f "$ST/libSwiftTerm.a" ]] || find Vendor/SwiftTerm/Sources/SwiftTerm -name '*.swift' -newer "$ST/libSwiftTerm.a" | read -r; then
        swiftc -O -whole-module-optimization -emit-library -static -emit-module -module-name SwiftTerm \
            -swift-version 5 -target "$arch-apple-macosx14.0" "${COMPILER_FLAGS[@]}" \
            @.build/SwiftTerm/sources.txt -o "$ST/libSwiftTerm.a" \
            -emit-module-path "$ST/SwiftTerm.swiftmodule"
    fi
    swiftc -O -parse-as-library -module-name ClaudeDesk -target "$arch-apple-macosx14.0" \
        "${COMPILER_FLAGS[@]}" -I "$ST" -L "$ST" -lSwiftTerm Sources/ClaudeDesk/*.swift -o ".build/release/$arch/ClaudeDesk"
    swiftc -O -module-name ClaudeDeskRunner -target "$arch-apple-macosx14.0" "${COMPILER_FLAGS[@]}" \
        "${RUNNER_SOURCES[@]}" -o ".build/release/$arch/claudedesk-runner"
done
for binary in ClaudeDesk claudedesk-runner; do
    slices=()
    for arch in "${ARCHS[@]}"; do slices+=(".build/release/$arch/$binary"); done
    lipo -create "${slices[@]}" -output ".build/release/$binary"
done
# atrium-memory, the Memory Vault MCP server, ships inside the app at the version in Resources/atrium-memory.version.
# Development builds compile it from the local checkout; otherwise the release is downloaded and its checksum checked.
MEMORY_VERSION="$(tr -d '[:space:]' < Resources/atrium-memory.version)"
MEMORY_SRC="${ATRIUM_MEMORY_SRC:-$PWD/../brainvault}"
MEMORY_OUT="$PWD/.build/atrium-memory"
rm -rf "$MEMORY_OUT" && mkdir -p "$MEMORY_OUT"
if [[ -f "$MEMORY_SRC/go.mod" ]]; then
    for arch in arm64 amd64; do
        (cd "$MEMORY_SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath \
            -ldflags "-s -w -X main.version=$MEMORY_VERSION-dev" -o "$MEMORY_OUT/atrium-memory-$arch" ./cmd/atrium-memory)
    done
else
    MEMORY_BASE="https://github.com/poom-h/atrium-memory/releases/download/v$MEMORY_VERSION"
    curl -fsSL "$MEMORY_BASE/checksums.txt" -o "$MEMORY_OUT/checksums.txt"
    for arch in arm64 amd64; do
        archive="atrium-memory_${MEMORY_VERSION}_darwin_${arch}.tar.gz"
        curl -fsSL "$MEMORY_BASE/$archive" -o "$MEMORY_OUT/$archive"
        (cd "$MEMORY_OUT" && grep " $archive\$" checksums.txt | shasum -a 256 -c -)
        tar -xzf "$MEMORY_OUT/$archive" -C "$MEMORY_OUT" atrium-memory
        mv "$MEMORY_OUT/atrium-memory" "$MEMORY_OUT/atrium-memory-$arch"
    done
fi
lipo -create "$MEMORY_OUT/atrium-memory-arm64" "$MEMORY_OUT/atrium-memory-amd64" -output "$MEMORY_OUT/atrium-memory"
APP="${APP_PATH:-$PWD/dist/ClaudeDesk.app}"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Vendor/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp .build/release/ClaudeDesk "$APP/Contents/MacOS/ClaudeDesk"
cp .build/release/claudedesk-runner "$APP/Contents/MacOS/claudedesk-runner"
cp "$MEMORY_OUT/atrium-memory" "$APP/Contents/MacOS/atrium-memory"
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
<key>CFBundleShortVersionString</key><string>3.8.1</string>
<key>CFBundleVersion</key><string>14</string>
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
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/atrium-memory"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/claudedesk-runner"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with ${IDENTITY:-ad-hoc signature}"
echo "Built $APP"
