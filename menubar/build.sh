#!/usr/bin/env bash
# Build Tailmon.app (menu bar monitor) from the SPM package. Ad-hoc signed —
# fine for personal use on the owner's own machines.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/Tailmon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Tailmon "$APP/Contents/MacOS/Tailmon"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "built: menubar/$APP"
