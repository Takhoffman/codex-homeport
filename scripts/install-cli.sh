#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${HOMEPORT_INSTALL_DIR:-$HOME/bin}"

swift run --package-path "$ROOT" homeport install --prefix "$INSTALL_DIR" --repo "$ROOT"
