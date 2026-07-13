#!/bin/sh
# Downloads the official signed mitmproxy macOS app bundles. The resulting
# resources ship inside Codex Multihome and run fully offline.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME="$ROOT/Sources/CodexMultihomeApp/Resources/mitmproxy-runtime"
PATCH_ASSETS="$ROOT/Sources/CodexMultihomeApp/MitmwebPatch"
VERSION="12.2.3"
SHASUM="${SHASUM:-/usr/bin/shasum}"

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
        arm64)
            archive_checksum="0a09ee3b82569e8985aff8186e4792618b8e5d0c766098db093d09a87d4b013a"
            mitmweb_checksum="9d809ab66ad4e4842c7743d47ee9bc7da61bfcf04be20ea598ee5fc11e9105cf"
            ;;
        x86_64)
            archive_checksum="7998187f5a0d399ab796af4523d3ad830ebe690726a41bc3e1df47a8e477a641"
            mitmweb_checksum="ec34e26163c8f19efec5b3c540b5c170d4c6a5680139bdb21953c69d97d6473b"
            ;;
    esac
    destination="$RUNTIME/$platform"
    executable="$destination/mitmproxy.app/Contents/MacOS/mitmweb"
    if ! ([ -x "$executable" ] && printf '%s  %s\n' "$mitmweb_checksum" "$executable" \
        | "$SHASUM" -a 256 -c - >/dev/null 2>&1); then
        tmp="$(mktemp -d)"
        archive="$tmp/mitmproxy.tar.gz"
        curl --fail --location --silent --show-error \
            "https://downloads.mitmproxy.org/$VERSION/mitmproxy-$VERSION-macos-$platform.tar.gz" \
            --output "$archive"
        printf '%s  %s\n' "$archive_checksum" "$archive" | "$SHASUM" -a 256 -c -
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
