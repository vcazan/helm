#!/usr/bin/env bash
# Builds an unsigned (ad-hoc signed) Helm.dmg for GitHub Releases into mac/build/.
# People opening it get Gatekeeper's warning once; the README explains Open Anyway.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MAC_DIR"
VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)"
PREFIX="${HELM_RELEASE_BUNDLE_PREFIX:-io.github.vcazan}"

rm -rf build/release
xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Release -derivedDataPath build/release -quiet \
  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual HELM_BUNDLE_PREFIX="$PREFIX" build 2>&1 \
  | grep -v "exit code 0 but produced no further output" || true
APP="build/release/Build/Products/Release/Helm.app"
[[ -d "$APP" ]] || { echo "Build failed" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Helm.app"
ln -s /Applications "$STAGE/Applications"
DMG="build/Helm-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Helm" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null 2>&1
echo "$MAC_DIR/$DMG"
