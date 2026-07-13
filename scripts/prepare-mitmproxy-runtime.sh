#!/bin/sh
# Downloads the official signed mitmproxy macOS app bundles. The resulting
# resources ship inside Codex Multihome and run fully offline.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME="$ROOT/Sources/CodexMultihomeApp/Resources/mitmproxy-runtime"
PATCH_ASSETS="$ROOT/Sources/CodexMultihomeApp/MitmwebPatch"
VERSION="12.2.3"

case "$(uname -m)" in
    arm64) host_platform="arm64" ;;
    x86_64) host_platform="x86_64" ;;
    *) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ "${1:-}" = "--all" ]; then
    platforms="arm64 x86_64"
else
    platforms="$host_platform"
fi

for platform in $platforms; do
    case "$platform" in
        arm64) checksum="0a09ee3b82569e8985aff8186e4792618b8e5d0c766098db093d09a87d4b013a" ;;
        x86_64) checksum="7998187f5a0d399ab796af4523d3ad830ebe690726a41bc3e1df47a8e477a641" ;;
    esac
    destination="$RUNTIME/$platform"
    executable="$destination/mitmproxy.app/Contents/MacOS/mitmweb"
    version_probe="$destination/mitmproxy.app/Contents/MacOS/mitmdump"
    if ! ([ -x "$executable" ] && [ -x "$version_probe" ] && "$version_probe" --version 2>/dev/null \
        | awk -v expected="$VERSION" '$1 == "Mitmproxy:" && $2 == expected { found = 1 } END { exit !found }'); then
        tmp="$(mktemp -d)"
        archive="$tmp/mitmproxy.tar.gz"
        curl --fail --location --silent --show-error \
            "https://downloads.mitmproxy.org/$VERSION/mitmproxy-$VERSION-macos-$platform.tar.gz" \
            --output "$archive"
        echo "$checksum  $archive" | shasum -a 256 -c -
        rm -rf "$destination"
        mkdir -p "$destination"
        tar -xzf "$archive" -C "$destination"
        rm -rf "$tmp"
    fi

    web_root="$destination/mitmproxy.app/Contents/Resources/mitmproxy/tools/web"
    cp "$PATCH_ASSETS/readable-websocket.js" "$web_root/static/homeport-readable-websocket.js"
    cp "$PATCH_ASSETS/readable-websocket.css" "$web_root/static/homeport-readable-websocket.css"
    if ! grep -q "homeport-readable-websocket" "$web_root/index.html"; then
        perl -0pi -e 's#</head>#      <link rel="stylesheet" href="./static/homeport-readable-websocket.css">\n      <script defer src="./static/homeport-readable-websocket.js"></script>\n    </head>#' "$web_root/index.html"
    fi
done
