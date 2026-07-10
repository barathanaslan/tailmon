#!/usr/bin/env bash
# Cross-compile tailmon for the fleet into dist/.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/opt/homebrew/bin:$PATH"
export CGO_ENABLED=0

LDFLAGS="-s -w"

build() {
  local goos="$1" goarch="$2" out="$3"
  echo "building dist/$out (${goos}/${goarch})"
  GOOS="$goos" GOARCH="$goarch" go build -trimpath -ldflags "$LDFLAGS" -o "dist/$out" ./cmd/tailmon
}

mkdir -p dist
build darwin arm64 tailmon-darwin-arm64
build windows amd64 tailmon-windows-amd64.exe
build linux amd64 tailmon-linux-amd64

echo "done:"
ls -lh dist/
