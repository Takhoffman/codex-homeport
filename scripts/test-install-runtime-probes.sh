#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/scripts"
cp "$ROOT/scripts/prepare-mitmproxy-runtime.sh" "$TMP_ROOT/scripts/prepare-mitmproxy-runtime.sh"

case "$(uname -m)" in
    arm64)
        platform="arm64"
        expected_checksum="9d809ab66ad4e4842c7743d47ee9bc7da61bfcf04be20ea598ee5fc11e9105cf"
        ;;
    x86_64)
        platform="x86_64"
        expected_checksum="ec34e26163c8f19efec5b3c540b5c170d4c6a5680139bdb21953c69d97d6473b"
        ;;
    *) echo "Unsupported test architecture: $(uname -m)" >&2; exit 1 ;;
esac

APP="$TMP_ROOT/Sources/CodexMultihomeApp/Resources/mitmproxy-runtime/$platform/mitmproxy.app"
MACOS="$APP/Contents/MacOS"
WEB="$APP/Contents/Resources/mitmproxy/tools/web"
PATCHES="$TMP_ROOT/Sources/CodexMultihomeApp/MitmwebPatch"
MARKERS="$TMP_ROOT/markers"
mkdir -p "$MACOS" "$WEB/static" "$PATCHES" "$MARKERS" "$TMP_ROOT/bin"

for name in mitmweb mitmdump mitmproxy; do
    printf '%s\n' '#!/bin/sh' 'touch "$TEST_MARKER_DIR/executable"' "printf 'Mitmproxy: 12.2.3 binary\\n'" > "$MACOS/$name"
    chmod +x "$MACOS/$name"
done
printf '%s\n' \
    '#!/bin/sh' \
    '[ "$#" -eq 4 ] && [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ] && [ "$4" = "-" ] || exit 91' \
    'set -- $(cat)' \
    '[ "$1" = "$TEST_EXPECTED_CHECKSUM" ] || exit 92' \
    'case "$2" in */mitmweb) ;; *) exit 93 ;; esac' \
    'touch "$TEST_MARKER_DIR/shasum"' > "$TMP_ROOT/bin/shasum"
printf '%s\n' '#!/bin/sh' 'touch "$TEST_MARKER_DIR/curl"' 'exit 99' > "$TMP_ROOT/bin/curl"
chmod +x "$TMP_ROOT/bin/shasum" "$TMP_ROOT/bin/curl"

: > "$PATCHES/readable-websocket.js"
: > "$PATCHES/readable-websocket.css"
printf '<html><head></head><body></body></html>\n' > "$WEB/index.html"

PATH="$TMP_ROOT/bin:$PATH" \
    SHASUM="$TMP_ROOT/bin/shasum" \
    TEST_EXPECTED_CHECKSUM="$expected_checksum" \
    TEST_MARKER_DIR="$MARKERS" \
    sh "$TMP_ROOT/scripts/prepare-mitmproxy-runtime.sh"

test -f "$MARKERS/shasum"
test ! -e "$MARKERS/executable"
test ! -e "$MARKERS/curl"
grep -q "homeport-readable-websocket" "$WEB/index.html"

echo "Installer runtime probe test passed."
