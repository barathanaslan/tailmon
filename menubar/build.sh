#!/usr/bin/env bash
# Build Tailmon.app (menu bar monitor) from the SPM package. Ad-hoc signed —
# fine for personal use on the owner's own machines.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# The tailmon CLI/agent travels inside the app (Contents/Resources/tailmon):
# the app installs the agent service from it on first launch when none runs,
# and the cask links it onto PATH. TAILMON_VERSION stamps release builds.
LDFLAGS="-s -w"
if [[ -n "${TAILMON_VERSION:-}" ]]; then
  LDFLAGS="$LDFLAGS -X github.com/barathanaslan/tailmon/internal/version.Version=$TAILMON_VERSION"
fi
(cd .. && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "$LDFLAGS" \
  -o menubar/.build/tailmon-agent ./cmd/tailmon)

APP="dist/Tailmon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tailmon "$APP/Contents/MacOS/Tailmon"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/tailmon-agent "$APP/Contents/Resources/tailmon"
codesign --force --sign - "$APP/Contents/Resources/tailmon"
codesign --force --sign - "$APP"

echo "built: menubar/$APP"
