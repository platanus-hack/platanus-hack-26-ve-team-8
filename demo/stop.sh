#!/bin/sh
# Deshace demo/start.sh: detiene el panel y Postgres y borra la base desechable.
set -u
DEMO=$(cd "$(dirname "$0")" && pwd)
STATE="$DEMO/.state"
PG_BIN="${PG_BIN:-$(brew --prefix postgresql@16)/bin}"

if [ -f "$STATE/dashboard.pid" ]; then
  kill "$(cat "$STATE/dashboard.pid")" 2>/dev/null || true
fi
if [ -d "$STATE/pg" ]; then
  "$PG_BIN/pg_ctl" -D "$STATE/pg" -m fast -w stop >/dev/null 2>&1 || true
fi
rm -rf "$STATE"
echo "Demo detenida: Postgres y el panel ya no escuchan y demo/.state se eliminó."
