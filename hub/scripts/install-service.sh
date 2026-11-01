#!/usr/bin/env bash
# Installs the Helm hub as a LaunchAgent: it starts at login and restarts if it exits.
set -euo pipefail

HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="ca.vcazan.helm.hub"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
NODE="$(command -v node)"
LOGS="$HOME/.helm/logs"
mkdir -p "$LOGS" "$HOME/Library/LaunchAgents"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Helm hub service removed."
  exit 0
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>--disable-warning=ExperimentalWarning</string>
    <string>$HUB_DIR/src/main.ts</string>
    <string>start</string>
  </array>
  <key>WorkingDirectory</key><string>$HUB_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(dirname "$NODE"):/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOGS/service.out.log</string>
  <key>StandardErrorPath</key><string>$LOGS/service.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrapping too early fails with "Input/output error".
for _ in $(seq 1 50); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.1
done
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || { sleep 1; launchctl bootstrap "gui/$(id -u)" "$PLIST"; }
launchctl enable "gui/$(id -u)/$LABEL"
echo "Helm hub installed and running (logs: $LOGS)."
echo "Pairing code: cd $HUB_DIR && npm run pair"
