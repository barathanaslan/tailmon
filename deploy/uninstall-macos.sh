#!/usr/bin/env bash
# Remove the tailmon LaunchAgent and binary (keeps logs).
set -euo pipefail

if [[ -x "$HOME/bin/tailmon" ]]; then
  "$HOME/bin/tailmon" service uninstall
fi
rm -f "$HOME/bin/tailmon"
echo "removed ~/bin/tailmon"
