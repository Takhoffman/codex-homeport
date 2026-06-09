#!/bin/sh
set -eu

REPO_URL="${HOMEPORT_REPO_URL:-https://github.com/Takhoffman/codex-homeport.git}"
SOURCE_DIR="${HOMEPORT_SOURCE_DIR:-$HOME/Library/Application Support/CodexHomeport/Source}"
PREFIX="${HOMEPORT_INSTALL_DIR:-$HOME/bin}"
APP_DIR="${HOMEPORT_APP_DIR:-$HOME/Applications}"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required. Install Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required. Install Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$(dirname "$SOURCE_DIR")"

if [ -d "$SOURCE_DIR/.git" ]; then
  git -C "$SOURCE_DIR" pull --ff-only
elif [ -e "$SOURCE_DIR" ]; then
  echo "$SOURCE_DIR exists but is not a git checkout. Move it aside or set HOMEPORT_SOURCE_DIR." >&2
  exit 1
else
  git clone "$REPO_URL" "$SOURCE_DIR"
fi

swift run --package-path "$SOURCE_DIR" homeport install \
  --repo "$SOURCE_DIR" \
  --prefix "$PREFIX" \
  --with-app \
  --app-dir "$APP_DIR"

"$PREFIX/homeport" autostart enable --app-dir "$APP_DIR"
"$PREFIX/homeport" restart --app-dir "$APP_DIR"

echo "Codex Homeport is installed."
echo "Update later with: $PREFIX/homeport update"
