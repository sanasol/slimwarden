#!/bin/bash
# Builds a release Slimwarden.app into ./build (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Slimwarden
APP=build/Slimwarden.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Slimwarden "$APP/Contents/MacOS/Slimwarden"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
sed -e "s/__VERSION__/$VERSION/; s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Prefer a stable Developer ID signature so the keychain keeps trusting new builds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" --options runtime $([ -n "${RELEASE:-}" ] && echo --timestamp || echo --timestamp=none) "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP ($VERSION build $BUILD)"
