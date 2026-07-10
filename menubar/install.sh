#!/usr/bin/env bash
# Install Tailmon.app to /Applications and (re)launch it. Builds first if the
# bundle is missing. No sudo (the user is an admin on their own Macs).
set -euo pipefail
cd "$(dirname "$0")"

[[ -d dist/Tailmon.app ]] || ./build.sh

# Replace atomically-ish: quit, remove, copy, relaunch.
killall Tailmon 2>/dev/null || true
rm -rf /Applications/Tailmon.app
cp -R dist/Tailmon.app /Applications/Tailmon.app
open -a /Applications/Tailmon.app

echo "installed + launched: /Applications/Tailmon.app"
echo "logs: ~/Library/Logs/tailmon-menubar.log"
echo "tip: enable 'Launch at login' from the dropdown footer"
