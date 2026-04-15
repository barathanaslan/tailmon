#!/usr/bin/env bash
#
# test.sh -- run the hand-rolled test harness.
#
# We don't use `swift test` because the test target is an executable, not
# a testTarget (XCTest is unavailable with Command Line Tools only, and
# swift-testing's Foundation cross-import overlay is broken in CLT).

set -euo pipefail
cd "$(dirname "$0")"
swift run StudioMenuBarTests
