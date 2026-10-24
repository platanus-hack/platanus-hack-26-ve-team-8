#!/usr/bin/env bash
# Wrap the bundle from scripts/package-macos.sh in a drag-to-Applications DMG.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$REPO_ROOT/.guardian/Arkangel.app}"
OUTPUT="${2:-$REPO_ROOT/.guardian/Arkangel.dmg}"
BACKGROUND="$REPO_ROOT/apps/macos/Installer/dmg-background.gif"
command -v create-dmg >/dev/null || { echo "Install create-dmg first: brew install create-dmg" >&2; exit 1; }
[[ -d "$APP_PATH" && "$APP_PATH" == *.app ]] || { echo "No app bundle at $APP_PATH. Run scripts/package-macos.sh first." >&2; exit 1; }
[[ ! -e "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }
APP_NAME="$(basename "$APP_PATH")"
SAFE_NAME='^[[:alnum:]_. -]+$'
[[ "$APP_NAME" =~ $SAFE_NAME ]] || { echo "create-dmg requires an app filename containing only letters, numbers, spaces, dots, underscores, or hyphens." >&2; exit 1; }
STAGING="$(mktemp -d -t guardian-dmg)"
trap 'rm -rf -- "$STAGING"' EXIT
ditto "$APP_PATH" "$STAGING/$APP_NAME"
create-dmg \
  --volname "${APP_NAME%.app}" \
  --window-size 642 406 \
  --icon-size 128 \
  --icon "$APP_NAME" 95 90 \
  --app-drop-link 367 213 \
  --hide-extension "$APP_NAME" \
  --background "$BACKGROUND" \
  "$OUTPUT" "$STAGING"
echo "$OUTPUT"
