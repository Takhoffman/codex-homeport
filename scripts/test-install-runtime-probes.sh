#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/scripts"
cp "$ROOT/scripts/prepare-mitmproxy-runtime.sh" "$TMP_ROOT/scripts/prepare-mitmproxy-runtime.sh"

case "$(uname -m)" in
    arm64) platform="arm64" ;;
    x86_64) platform="x86_64" ;;
    *) echo "Unsupported test architecture: $(uname -m)" >&2; exit 1 ;;
esac

APP="$TMP_ROOT/Sources/CodexMultihomeApp/Resources/mitmproxy-runtime/$platform/mitmproxy.app"
MACOS="$APP/Contents/MacOS"
WEB="$APP/Contents/Resources/mitmproxy/tools/web"
PATCHES="$TMP_ROOT/Sources/CodexMultihomeApp/MitmwebPatch"
MARKERS="$TMP_ROOT/markers"
mkdir -p "$MACOS" "$WEB/static" "$PATCHES" "$MARKERS"

printf '%s\n' '#!/bin/sh' 'touch "$TEST_MARKER_DIR/mitmweb"' "printf 'Mitmproxy: 12.2.3 binary\\n'" > "$MACOS/mitmweb"
printf '%s\n' '#!/bin/sh' 'touch "$TEST_MARKER_DIR/mitmdump"' "printf 'Mitmproxy: 12.2.3 binary\\n'" > "$MACOS/mitmdump"
chmod +x "$MACOS/mitmweb" "$MACOS/mitmdump"

: > "$PATCHES/readable-websocket.js"
: > "$PATCHES/readable-websocket.css"
printf '<html><head></head><body></body></html>\n' > "$WEB/index.html"

TEST_MARKER_DIR="$MARKERS" sh "$TMP_ROOT/scripts/prepare-mitmproxy-runtime.sh"

test -f "$MARKERS/mitmdump"
test ! -e "$MARKERS/mitmweb"
grep -q "homeport-readable-websocket" "$WEB/index.html"

echo "Installer runtime probe test passed."
