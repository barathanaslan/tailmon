#!/usr/bin/env bash
# Remove Tailmon.app. If 'Launch at login' was enabled, unregistering happens
# implicitly when the app is deleted (SMAppService items for missing apps are
# pruned by macOS; check System Settings > General > Login Items if in doubt).
set -euo pipefail
killall Tailmon 2>/dev/null || true
rm -rf /Applications/Tailmon.app
echo "removed /Applications/Tailmon.app"
