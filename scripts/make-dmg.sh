#!/bin/bash
# Packages dist/ClaudeDesk.app into a drag-to-Applications disk image, dist/ClaudeDesk-<version>.dmg,
# with a SHA-256 checksum file next to it. Build the app first with scripts/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP_PATH:-$PWD/dist/ClaudeDesk.app}"
[[ -d "$APP" ]] || { echo "No app at $APP. Build it first: bash scripts/build-app.sh" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="ClaudeDesk-$VERSION.dmg"
OUT_DIR="$(dirname "$APP")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/ClaudeDesk.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT_DIR/$NAME"
hdiutil create -volname "ClaudeDesk $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT_DIR/$NAME" >/dev/null
(cd "$OUT_DIR" && shasum -a 256 "$NAME" > "$NAME.sha256")
cat "$OUT_DIR/$NAME.sha256"
echo "Built $OUT_DIR/$NAME"
