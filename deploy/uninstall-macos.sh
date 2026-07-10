#!/usr/bin/env bash
# Remove the tailmon LaunchAgent and binary (keeps logs).
set -euo pipefail

LABEL="com.bosphorify.tailmon"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST_DST" "$HOME/bin/tailmon"
echo "uninstalled $LABEL (log left at ~/Library/Logs/tailmon-agent.log)"
