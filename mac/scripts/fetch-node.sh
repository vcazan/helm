#!/usr/bin/env bash
# Downloads the Node.js runtime the Mac app ships with into mac/vendor (git ignores it), checking its SHA-256.
# Prints the path of the unpacked Node directory.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$MAC_DIR/node-version")"
NAME="node-v${VERSION}-darwin-arm64"
DEST="$MAC_DIR/vendor/$NAME"

if [[ ! -x "$DEST/bin/node" ]]; then
  mkdir -p "$MAC_DIR/vendor"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  BASE="https://nodejs.org/dist/v${VERSION}"
  curl -fsSL "$BASE/$NAME.tar.gz" -o "$TMP/node.tar.gz" >&2
  EXPECTED="$(curl -fsSL "$BASE/SHASUMS256.txt" | awk -v f="$NAME.tar.gz" '$2 == f { print $1 }')"
  ACTUAL="$(shasum -a 256 "$TMP/node.tar.gz" | awk '{ print $1 }')"
  if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    echo "Node download failed its checksum check" >&2
    exit 1
  fi
  tar -xzf "$TMP/node.tar.gz" -C "$TMP"
  rm -rf "$DEST"
  mv "$TMP/$NAME" "$DEST"
fi

echo "$DEST"
