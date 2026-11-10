# Sourced from the build and test scripts, after changing to the project root.
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/FixedModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
COMPILER_FLAGS=(-module-cache-path "$CLANG_MODULE_CACHE_PATH")
# Some Command Line Tools installations contain two copies of SwiftBridging.
# Hide the obsolete copy only from this compiler invocation; do not alter Xcode.
SWIFT_INCLUDE="$(xcode-select -p)/usr/include/swift"
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]] &&
   cmp -s <(sed '/^\/\//d' "$SWIFT_INCLUDE/module.modulemap") <(sed '/^\/\//d' "$SWIFT_INCLUDE/bridging.modulemap"); then
    : > .build/empty.modulemap
    python3 - "$SWIFT_INCLUDE/module.modulemap" "$PWD/.build" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[2])
(root / 'toolchain-overlay.json').write_text(json.dumps({'version': 0, 'roots': [
    {'type': 'file', 'name': sys.argv[1], 'external-contents': str(root / 'empty.modulemap')}
]}))
PY
    COMPILER_FLAGS+=(-vfsoverlay "$PWD/.build/toolchain-overlay.json")
fi
