#!/usr/bin/env bash
#
# uninstall.sh -- reverse install.sh. Idempotent.

set -euo pipefail

APP_NAME="StudioMenuBar"
BUNDLE_ID="com.bosphorify.studiomenubar"
DEST_APP="/Applications/${APP_NAME}.app"
PLIST_DEST="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
UID_NUMERIC="$(id -u)"
AGENT_TARGET="gui/${UID_NUMERIC}/${BUNDLE_ID}"

echo "==> stopping launchd agent"
launchctl bootout "${AGENT_TARGET}" 2>/dev/null || true
pkill -x "${APP_NAME}" 2>/dev/null || true

if [ -f "${PLIST_DEST}" ]; then
    echo "==> removing ${PLIST_DEST}"
    rm -f "${PLIST_DEST}"
fi

if [ -d "${DEST_APP}" ]; then
    echo "==> removing ${DEST_APP}"
    rm -rf "${DEST_APP}"
fi

echo ""
echo "Uninstalled. Logs at ~/Library/Logs/studiomenubar.* were left in place."
