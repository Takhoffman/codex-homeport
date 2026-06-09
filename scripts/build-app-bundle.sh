#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift run --package-path "$ROOT" homeport install --with-app --repo "$ROOT"
