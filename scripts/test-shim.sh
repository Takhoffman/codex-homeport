#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SHIM="$ROOT/Sources/CodexMultihomeApp/Resources/codex-shim"

"$ROOT/scripts/prepare-shim-runtime.sh"

case "$(uname -m)" in
    arm64) platform="aarch64" ;;
    x86_64) platform="x86_64" ;;
    *) echo "Unsupported macOS architecture for bundled shim tests: $(uname -m)" >&2; exit 1 ;;
esac

export PYTHONDONTWRITEBYTECODE=1
"$SHIM/runtime/$platform/python/bin/python3" -m unittest discover \
    -s "$SHIM/tests" \
    -p 'test_*.py' \
    -v
