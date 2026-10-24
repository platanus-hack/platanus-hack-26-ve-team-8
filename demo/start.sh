#!/bin/sh
# Demo del hackathon: Postgres desechable (sin Docker) + panel web en vivo.
# Todo vive en demo/.state y demo/stop.sh lo borra. No toca el Postgres de Homebrew ni su configuración.
#
# Postgres escucha en todas las interfaces (puerto 5432) para que un segundo equipo lance
# demo/postgres-attacker.sh. Desde la red solo entra el rol "demo" (sin superusuario, con
# contraseña) y solo a la base arkangel_demo.
set -eu
DEMO=$(cd "$(dirname "$0")" && pwd)
STATE="$DEMO/.state"
PG_BIN="${PG_BIN:-$(brew --prefix postgresql@16)/bin}"
PASSWORD="arkangel-demo"
export PGHOST="$STATE" PGPORT=5432 PG_BIN LC_ALL=C  # Postgres aborta con un locale inválido

if [ ! -d "$STATE/pg" ]; then
  mkdir -p "$STATE"
  "$PG_BIN/initdb" -D "$STATE/pg" -A trust -E UTF8 >/dev/null
  cat >> "$STATE/pg/postgresql.conf" <<EOF
listen_addresses = '*'
port = 5432
unix_socket_directories = '$STATE'
EOF
  echo "host arkangel_demo demo samenet scram-sha-256" >> "$STATE/pg/pg_hba.conf"
  "$PG_BIN/pg_ctl" -D "$STATE/pg" -l "$STATE/postgres.log" -w start >/dev/null
  "$PG_BIN/psql" -X -q -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE demo LOGIN PASSWORD '$PASSWORD'" \
    -c "CREATE DATABASE arkangel_demo OWNER demo"
  "$PG_BIN/psql" -X -q -U demo -d arkangel_demo -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE intrusion (id serial PRIMARY KEY, created_at timestamptz DEFAULT now(), junk text)"
elif ! "$PG_BIN/pg_ctl" -D "$STATE/pg" status >/dev/null 2>&1; then
  "$PG_BIN/pg_ctl" -D "$STATE/pg" -l "$STATE/postgres.log" -w start >/dev/null
fi

if ! { [ -f "$STATE/dashboard.pid" ] && kill -0 "$(cat "$STATE/dashboard.pid")" 2>/dev/null; }; then
  node "$DEMO/dashboard.mjs" > "$STATE/dashboard.log" 2>&1 &
  echo $! > "$STATE/dashboard.pid"
  sleep 1
fi

IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<ip-de-tu-mac>")
echo "Postgres listo en $IP:5432 (base arkangel_demo, datos en demo/.state)."
echo "Panel en vivo: http://localhost:3000"
echo "Consola SQL:   psql -h $STATE -d arkangel_demo"
echo "En el segundo equipo: PGPASSWORD=$PASSWORD demo/postgres-attacker.sh $IP"
echo "Al terminar:   demo/stop.sh"
open http://localhost:3000 2>/dev/null || true
