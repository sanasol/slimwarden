#!/bin/bash
# Builds, notarizes and zips a release: ./scripts/release.sh 0.1.0
# One-time setup (stores credentials in your keychain):
#   xcrun notarytool store-credentials slimwarden --apple-id <id> --team-id <team> --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version>}"
PROFILE="${NOTARY_PROFILE:-slimwarden}"

RELEASE=1 VERSION="$VERSION" ./scripts/build-app.sh
ZIP="build/Slimwarden-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Slimwarden.app "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/Slimwarden.app
rm -f "$ZIP"
ditto -c -k --keepParent build/Slimwarden.app "$ZIP"
spctl -a -vv build/Slimwarden.app

shasum -a 256 "$ZIP"
