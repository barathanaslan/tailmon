#!/usr/bin/env bash
#
# install.sh -- copy StudioMenuBar.app to /Applications and install a
# user launchd agent for launch-at-login. No sudo needed; everything is
# user-scope.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="StudioMenuBar"
BUNDLE_ID="com.bosphorify.studiomenubar"
SRC_APP="build/${APP_NAME}.app"
DEST_APP="/Applications/${APP_NAME}.app"
PLIST_SRC="deploy/${BUNDLE_ID}.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
UID_NUMERIC="$(id -u)"
AGENT_TARGET="gui/${UID_NUMERIC}/${BUNDLE_ID}"

if [ ! -d "${SRC_APP}" ]; then
    echo "error: ${SRC_APP} does not exist. Run 'bash build.sh' first." >&2
    exit 1
fi

echo "==> stopping any running instance"
launchctl bootout "${AGENT_TARGET}" 2>/dev/null || true
# Also kill any loose process that wasn't launched via launchd.
pkill -x "${APP_NAME}" 2>/dev/null || true

if [ -d "${DEST_APP}" ]; then
    echo "==> removing previous ${DEST_APP}"
    rm -rf "${DEST_APP}"
fi

echo "==> copying ${SRC_APP} -> ${DEST_APP}"
cp -R "${SRC_APP}" "${DEST_APP}"

echo "==> rendering launchd agent plist"
mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${HOME}/Library/Logs"
sed "s|__HOME__|${HOME}|g" "${PLIST_SRC}" > "${PLIST_DEST}"
chmod 0644 "${PLIST_DEST}"

echo "==> bootstrapping launchd agent"
launchctl bootstrap "gui/${UID_NUMERIC}" "${PLIST_DEST}"
launchctl enable "${AGENT_TARGET}" || true

echo ""
echo "App installed. Look for the icon in the menubar."
echo "Logs at: ~/Library/Logs/studiomenubar.{out,err}.log"
