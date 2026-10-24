#!/bin/sh
# Undo demo/attack.sh.
set -u
STATE="${TMPDIR:-/tmp}/arkangel-demo"
PLIST="$HOME/Library/LaunchAgents/com.apple.softwareupdate.helper.plist"

if [ -f "$STATE/listener.pid" ]; then
  kill "$(cat "$STATE/listener.pid")" 2>/dev/null || true
fi
launchctl bootout "gui/$(id -u)/com.apple.softwareupdate.helper" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$STATE"
echo "Demo footholds removed. Take a snapshot in Arkangel, then Reset baseline."
