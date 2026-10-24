#!/bin/sh
# Hackathon demo: simulate two attacker footholds on THIS Mac so Arkangel can detect them.
# Harmless and reversible with demo/cleanup.sh:
# - a LaunchAgent that imitates an Apple label (never loaded; at most runs once at next login, then exits),
# - a renamed copy of /usr/bin/nc listening on 127.0.0.1:4444 (loopback only, nothing leaves the Mac).
set -eu
STATE="${TMPDIR:-/tmp}/arkangel-demo"
BINARY="$STATE/softwareupdated"
PLIST="$HOME/Library/LaunchAgents/com.apple.softwareupdate.helper.plist"

mkdir -p "$STATE" "$HOME/Library/LaunchAgents"
cp /usr/bin/nc "$BINARY"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.apple.softwareupdate.helper</string>
  <key>ProgramArguments</key><array><string>$BINARY</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

"$BINARY" -lk 127.0.0.1 4444 >/dev/null 2>&1 &
echo $! > "$STATE/listener.pid"

echo "Planted $PLIST"
echo "Listening as softwareupdated on 127.0.0.1:4444 (pid $(cat "$STATE/listener.pid"))"
echo "Run demo/cleanup.sh when the demo is over, and before logging out."
