#!/usr/bin/env bash
#
# build.sh -- compile StudioMenuBar and assemble an ad-hoc signed .app
# bundle at menubar/build/StudioMenuBar.app.
#
# Prereqs: Swift toolchain (Xcode or Command Line Tools), macOS 13+.
# No Apple Developer account needed -- we codesign with `- -- ad-hoc.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="StudioMenuBar"
BUNDLE_ID="com.bosphorify.studiomenubar"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH=".build/release/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
    echo "error: expected built binary at ${BIN_PATH} not found" >&2
    exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

echo "==> ad-hoc codesign"
codesign --force --sign - \
    --entitlements Entitlements.plist \
    --options runtime \
    "${APP_DIR}" 2>/dev/null || \
codesign --force --sign - "${APP_DIR}"

echo "==> verify"
codesign -v "${APP_DIR}"

echo ""
echo "Built ${APP_DIR}"
echo "To install:"
echo "  bash ${PWD}/install.sh"
