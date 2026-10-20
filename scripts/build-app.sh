#!/bin/bash
# Builds Skreener.app into ./build. Set SIGN_IDENTITY to choose a codesigning identity;
# a stable identity keeps the Screen Recording permission across rebuilds (ad-hoc "-" does not).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
APP=build/Skreener.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Skreener" "$APP/Contents/MacOS/Skreener"
cp Resources/Info.plist "$APP/Contents/Info.plist"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --entitlements Resources/Skreener.entitlements --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:--})"
