#!/usr/bin/env bash
# Install the tailmon agent as a user LaunchAgent (no sudo anywhere).
# Copies the built binary to ~/bin/tailmon, then `tailmon service install`.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_SRC="dist/tailmon-darwin-arm64"
BIN_DST="$HOME/bin/tailmon"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: macOS only" >&2; exit 1
fi
if [[ ! -f "$BIN_SRC" ]]; then
  echo "dist/ binary missing — running ./build.sh first"
  ./build.sh
fi

mkdir -p "$HOME/bin"
install -m 755 "$BIN_SRC" "$BIN_DST"

# The LaunchAgent itself (plist, launchctl bootstrap) is written by the
# binary, the same code every install route uses.
"$BIN_DST" service install

echo "check: $BIN_DST service status"
