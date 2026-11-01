#!/usr/bin/env bash
# Builds Helm.app into mac/build/. Signs with your team when ios/Config/Local.xcconfig sets one, otherwise
# signs it to run on this Mac only. With --install, replaces /Applications/Helm.app and opens it.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MAC_DIR"

SIGNING=()
if ! grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]+' ../ios/Config/Local.xcconfig 2>/dev/null; then
  SIGNING=(DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi

xcodebuild -project Helm.xcodeproj -scheme Helm -configuration Release -derivedDataPath build/xcode -quiet \
  ${SIGNING[@]+"${SIGNING[@]}"} build 2>&1 | grep -v "exit code 0 but produced no further output" || true
APP="build/xcode/Build/Products/Release/Helm.app"
[[ -d "$APP" ]] || { echo "Build failed" >&2; exit 1; }
rm -rf build/Helm.app
cp -R "$APP" build/Helm.app
echo "Built $MAC_DIR/build/Helm.app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Helm 2>/dev/null && sleep 2 || true
  rm -rf /Applications/Helm.app
  cp -R build/Helm.app /Applications/Helm.app
  open /Applications/Helm.app
  echo "Installed /Applications/Helm.app"
fi
