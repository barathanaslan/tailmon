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

# Reload cleanly whether or not a previous version is running. bootout
# returns before the old job is fully gone, and bootstrapping in that window
# fails with "5: Input/output error" — wait for it to disappear first.
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "installed: $BIN_DST"
echo "agent loaded: $LABEL (logs: ~/Library/Logs/tailmon-agent.log)"
echo "check: curl -s http://127.0.0.1:7020/health"
