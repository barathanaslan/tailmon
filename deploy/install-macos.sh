#!/usr/bin/env bash
# Install the tailmon agent as a user LaunchAgent (no sudo anywhere).
# Copies the built binary to ~/bin/tailmon, renders + loads the plist.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.bosphorify.tailmon"
BIN_SRC="dist/tailmon-darwin-arm64"
BIN_DST="$HOME/bin/tailmon"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: macOS only" >&2; exit 1
fi
if [[ ! -f "$BIN_SRC" ]]; then
  echo "dist/ binary missing — running ./build.sh first"
  ./build.sh
fi

mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$BIN_SRC" "$BIN_DST"
sed "s|__HOME__|$HOME|g" deploy/com.bosphorify.tailmon.plist > "$PLIST_DST"

# Reload cleanly whether or not a previous version is running.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "installed: $BIN_DST"
echo "agent loaded: $LABEL (logs: ~/Library/Logs/tailmon-agent.log)"
echo "check: curl -s http://127.0.0.1:7020/health"
