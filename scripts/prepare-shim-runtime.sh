#!/bin/sh
# Downloads and prepares the architecture-specific Python runtime that ships in
# the app bundle. This is an install-time step; the resulting app runs offline.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SHIM="$ROOT/Sources/CodexMultihomeApp/Resources/codex-shim"
RUNTIME="$SHIM/runtime"
PYTHON_VERSION="3.14.5"
BUILD_DATE="20260510"
AIOHTTP_VERSION="3.13.5"

case "$(uname -m)" in
    arm64) host_platform="aarch64" ;;
    x86_64) host_platform="x86_64" ;;
    *) echo "Unsupported macOS architecture for bundled shim runtime: $(uname -m)" >&2; exit 1 ;;
esac

if [ "${1:-}" = "--all" ]; then
    platforms="aarch64 x86_64"
else
    platforms="$host_platform"
fi

prepare_runtime() {
    platform="$1"
    archive="cpython-${PYTHON_VERSION}+${BUILD_DATE}-${platform}-apple-darwin-install_only_stripped.tar.gz"
    download_archive="cpython-${PYTHON_VERSION}%2B${BUILD_DATE}-${platform}-apple-darwin-install_only_stripped.tar.gz"
    case "$platform" in
        aarch64) checksum="1bb0b3d45448dfe7e916dc62144cfd7d7a611dc6ccf05b8bb71662cc5c2a1ad2"; wheel_platform="macosx_11_0_arm64" ;;
        x86_64) checksum="38662e526797db4e90b3381706b96821979fece0b536ac14b5c4e1a97e0590d5"; wheel_platform="macosx_10_13_x86_64" ;;
    esac
    destination="$RUNTIME/$platform"
    python="$destination/python/bin/python3"

    if [ -x "$python" ] && "$python" -c "import aiohttp; raise SystemExit(0 if aiohttp.__version__ == '$AIOHTTP_VERSION' else 1)" >/dev/null 2>&1; then
        return
    fi

    tmp="$(mktemp -d)"
    mkdir -p "$RUNTIME"
    curl --fail --location --silent --show-error \
        "https://github.com/astral-sh/python-build-standalone/releases/download/${BUILD_DATE}/${download_archive}" \
        --output "$tmp/$archive"
    echo "$checksum  $tmp/$archive" | shasum -a 256 -c -
    tar -xzf "$tmp/$archive" -C "$tmp"
    rm -rf "$destination"
    mkdir -p "$destination"
    mv "$tmp/python" "$destination/python"

    if [ "$platform" = "$host_platform" ]; then
        "$python" -m pip install --disable-pip-version-check --no-input --requirement "$SHIM/requirements.txt"
    else
        command -v python3 >/dev/null 2>&1 || {
            echo "Preparing both runtime architectures requires python3 on the release machine." >&2
            exit 1
        }
        python3 -m pip download --disable-pip-version-check --only-binary=:all: \
            --platform "$wheel_platform" --implementation cp --python-version 3.14 --abi cp314 \
            --dest "$tmp/wheels" --requirement "$SHIM/requirements.txt"
        mkdir -p "$destination/python/lib/python3.14/site-packages"
        for wheel in "$tmp"/wheels/*.whl; do
            unzip -q "$wheel" -d "$destination/python/lib/python3.14/site-packages"
        done
    fi
    rm -rf "$tmp"
}

for platform in $platforms; do
    prepare_runtime "$platform"
done
