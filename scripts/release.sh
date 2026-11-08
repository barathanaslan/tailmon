#!/usr/bin/env bash
# Publish a tagged release from this Mac (the tag must already be pushed):
#   scripts/release.sh v0.3.0
# Builds Tailmon.app, runs GoReleaser (GitHub release, Homebrew formula,
# Scoop manifest) and writes the Tailmon.app cask to the tap. Uses the gh
# CLI's login for this one run only — nothing is stored anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release.sh vX.Y.Z}"
VERSION="${TAG#v}"
[[ "$(git describe --tags --exact-match HEAD 2>/dev/null)" == "$TAG" ]] || {
  echo "error: HEAD is not tagged $TAG (git checkout $TAG first)" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean" >&2; exit 1; }

TOKEN="$(gh auth token)"

# Tailmon.app, versioned from the tag.
plutil -replace CFBundleShortVersionString -string "$VERSION" menubar/Info.plist
(cd menubar && ./build.sh)
git checkout menubar/Info.plist
rm -rf dist-app && mkdir dist-app
ditto -c -k --keepParent menubar/dist/Tailmon.app "dist-app/Tailmon-$VERSION.zip"

GITHUB_TOKEN="$TOKEN" TAP_GITHUB_TOKEN="$TOKEN" goreleaser release --clean

# Cask for the app (GoReleaser's casks cover CLI archives, not .app bundles).
SHA=$(shasum -a 256 "dist-app/Tailmon-$VERSION.zip" | cut -d' ' -f1)
TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
gh repo clone barathanaslan/homebrew-tailmon "$TAP" -- -q
mkdir -p "$TAP/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" \
  packaging/tailmon-app.rb.tmpl > "$TAP/Casks/tailmon-app.rb"
git -C "$TAP" add Casks/tailmon-app.rb
if git -C "$TAP" commit -q -m "tailmon-app $VERSION"; then
  git -C "$TAP" push -q
  echo "cask tailmon-app $VERSION pushed"
else
  echo "cask unchanged"
fi
