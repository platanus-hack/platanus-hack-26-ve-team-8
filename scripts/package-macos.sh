#!/bin/sh
# Prepara una app autónoma; las dependencias se instalan solo al empaquetar.
set -eu
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${GUARDIAN_PYTHON_RUNTIME:?Define GUARDIAN_PYTHON_RUNTIME con un Python portátil install_only para este Mac.}"
PYTHON="$GUARDIAN_PYTHON_RUNTIME/bin/python3"
[ -x "$PYTHON" ] || { echo "No se encontró el Python portátil: $PYTHON" >&2; exit 1; }
"$PYTHON" -I "$REPO_ROOT/scripts/package_macos.py" "$REPO_ROOT" "$GUARDIAN_PYTHON_RUNTIME"
