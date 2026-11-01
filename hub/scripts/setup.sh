#!/usr/bin/env bash
# One-time setup for a Mac: checks prerequisites, installs the hub as a login service,
# adds a "Cursor (Helm)" launcher, and prints the pairing code for the iPhone app.
# Safe to run again; each step skips what's already done.
set -euo pipefail

HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CURSOR_APP="/Applications/Cursor.app"
TS_CLI=""
for p in /Applications/Tailscale.app/Contents/MacOS/Tailscale /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
  [[ -x "$p" ]] && TS_CLI="$p" && break
done

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

bold "Checking this Mac"
[[ "$(uname)" == "Darwin" ]] || fail "Helm's hub runs on macOS."

command -v node >/dev/null || fail "Node.js isn't installed. Install Node 22.18 or newer (brew install node), then run this again."
NODE_VERSION="$(node -p 'process.versions.node')"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=18)?0:1)' \
  || fail "Node $NODE_VERSION is too old. Helm needs 22.18 or newer (brew upgrade node)."
ok "Node $NODE_VERSION"

[[ -x "$CURSOR_APP/Contents/MacOS/Cursor" ]] || fail "Cursor isn't installed in /Applications."
ok "Cursor"

if [[ -z "$TS_CLI" ]]; then
  fail "Tailscale isn't installed. Get it from https://tailscale.com/download/mac, sign in, then run this again."
elif "$TS_CLI" status >/dev/null 2>&1; then
  ok "Tailscale connected"
else
  warn "Tailscale is installed but not connected. Open Tailscale and sign in; the phone must be on the same tailnet."
fi

bold "Installing the hub"
(cd "$HUB_DIR" && npm ci --silent --no-audit --no-fund)
ok "Dependencies"

if (cd "$HUB_DIR" && node --disable-warning=ExperimentalWarning src/main.ts status | grep -q '"cursorLoggedIn": true'); then
  ok "Signed in to Cursor"
else
  (cd "$HUB_DIR" && npm run --silent login) || fail "Couldn't sign in to Cursor. Sign in to the Cursor app, then run this again."
  ok "Signed in to Cursor"
fi

mkdir -p "$HOME/.local/bin"
install -m 755 "$HUB_DIR/scripts/cursor-cdp" "$HOME/.local/bin/cursor-cdp"

# A Dock-friendly launcher: Helm can only drive Cursor windows started with the debugging port.
APPS="/Applications"; [[ -w "$APPS" ]] || APPS="$HOME/Applications"
LAUNCHER="$APPS/Cursor (Helm).app"
mkdir -p "$LAUNCHER/Contents/MacOS" "$LAUNCHER/Contents/Resources"
cat > "$LAUNCHER/Contents/MacOS/launch" <<EOF
#!/usr/bin/env bash
exec "$HOME/.local/bin/cursor-cdp" "\$@"
EOF
chmod +x "$LAUNCHER/Contents/MacOS/launch"
cp "$CURSOR_APP/Contents/Resources/Cursor.icns" "$LAUNCHER/Contents/Resources/Cursor.icns" 2>/dev/null || true
cat > "$LAUNCHER/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cursor (Helm)</string>
  <key>CFBundleIdentifier</key><string>ca.vcazan.helm.cursor-launcher</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIconFile</key><string>Cursor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
ok "Launcher: $LAUNCHER"

"$HUB_DIR/scripts/install-service.sh" >/dev/null
for _ in $(seq 1 20); do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:7878/api/state" && break
  sleep 0.5
done
ok "Hub running at login (logs in ~/.helm/logs)"

bold "Last steps"
if curl -sf -m 1 http://127.0.0.1:9222/json >/dev/null 2>&1; then
  ok "Cursor is running with the debugging port"
else
  warn "Quit Cursor (⌘Q) and reopen it with \"Cursor (Helm)\" so Helm can see your chats. Use that launcher from now on."
fi
echo "  Then open Helm on your iPhone and scan this code:"
(cd "$HUB_DIR" && npm run --silent pair)
