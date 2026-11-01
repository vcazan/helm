#!/usr/bin/env bash
# Xcode build phase: copies Node and the hub into Helm.app and signs every binary inside them.
set -euo pipefail

ROOT="$SRCROOT/.."
NODE_DIR="$("$SRCROOT/scripts/fetch-node.sh")"
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
HUB="$CONTENTS/Resources/hub"

if [[ ! -d "$ROOT/hub/node_modules/@cursor/sdk" ]]; then
  (cd "$ROOT/hub" && "$NODE_DIR/bin/node" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" ci --omit=dev --no-audit --no-fund)
fi

mkdir -p "$CONTENTS/Helpers" "$HUB"
install -m 755 "$NODE_DIR/bin/node" "$CONTENTS/Helpers/node"
rsync -a --delete "$ROOT/hub/src" "$ROOT/hub/runner" "$ROOT/hub/package.json" "$HUB/"
rsync -a --delete --exclude '.cache' --exclude '.package-lock.json' "$ROOT/hub/node_modules" "$HUB/"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  sign() { codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"; }
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then sign "$f"; fi
  done < <(find "$HUB/node_modules" -type f \( -name '*.node' -o -name '*.dylib' -o -perm -u+x \) -print0)
  sign --entitlements "$SRCROOT/Helm/Node.entitlements" "$CONTENTS/Helpers/node"
fi
