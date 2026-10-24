#!/bin/sh
set -eu

# Serve only synthetic data, never the repository or the user's files.
DEMO_DIR=$(mktemp -d /tmp/arkangel-demo.XXXXXX)
trap 'rm -rf -- "$DEMO_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' 'ARKANGEL-DEMO-ONLY-NOT-A-SECRET' > "$DEMO_DIR/canary.txt"
test "$(cat "$DEMO_DIR/canary.txt")" = 'ARKANGEL-DEMO-ONLY-NOT-A-SECRET'

printf '%s\n' 'Simulación: archivo ficticio disponible en http://127.0.0.1:8765/canary.txt' \
  'Abre Arkangel, espera un escaneo y solicita una investigación. Pulsa Ctrl-C para terminar.'
"${GUARDIAN_PYTHON:-python3}" -m http.server 8765 --bind 127.0.0.1 --directory "$DEMO_DIR"
