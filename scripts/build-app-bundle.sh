#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/prepare-mitmproxy-runtime.sh"
swift run --package-path "$ROOT" codex-multihome install --with-app --repo "$ROOT"
