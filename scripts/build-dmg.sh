#!/usr/bin/env bash
# Empaqueta el bundle de scripts/package-macos.sh en un DMG para arrastrar a Aplicaciones.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$REPO_ROOT/.guardian/Arkangel.app}"
OUTPUT="${2:-$REPO_ROOT/.guardian/Arkangel.dmg}"
BACKGROUND="$REPO_ROOT/apps/macos/Installer/dmg-background.png"
command -v create-dmg >/dev/null || { echo "Instala create-dmg primero: brew install create-dmg" >&2; exit 1; }
[[ -d "$APP_PATH" && "$APP_PATH" == *.app ]] || { echo "No hay un bundle de app en $APP_PATH. Ejecuta primero scripts/package-macos.sh." >&2; exit 1; }
[[ ! -e "$OUTPUT" ]] || { echo "La salida ya existe: $OUTPUT" >&2; exit 1; }
APP_NAME="$(basename "$APP_PATH")"
SAFE_NAME='^[[:alnum:]_. -]+$'
[[ "$APP_NAME" =~ $SAFE_NAME ]] || { echo "create-dmg requiere un nombre de app que solo contenga letras, números, espacios, puntos, guiones bajos o guiones." >&2; exit 1; }
STAGING="$(mktemp -d -t guardian-dmg)"
trap 'rm -rf -- "$STAGING"' EXIT
ditto "$APP_PATH" "$STAGING/$APP_NAME"
create-dmg \
  --volname "${APP_NAME%.app}" \
  --window-size 642 406 \
  --icon-size 96 \
  --text-size 14 \
  --icon "$APP_NAME" 170 180 \
  --app-drop-link 472 180 \
  --hide-extension "$APP_NAME" \
  --background "$BACKGROUND" \
  "$OUTPUT" "$STAGING"
echo "$OUTPUT"
