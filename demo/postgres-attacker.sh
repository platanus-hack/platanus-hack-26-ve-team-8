#!/bin/sh
# Demo del hackathon: se ejecuta en un SEGUNDO equipo de la misma red y simula a un intruso
# que inserta filas sin parar en el Postgres de tu Mac. Solo toca la base desechable arkangel_demo.
#
# Preparación en el Mac: demo/start.sh (Postgres desechable en todas las interfaces y panel
# en http://localhost:3000). Abre Arkangel y espera un escaneo antes de lanzar este script: la
# primera instantánea establece la línea base.
#
# Uso en el segundo equipo: PGPASSWORD=arkangel-demo demo/postgres-attacker.sh <ip-de-tu-mac>
# Al terminar, en el Mac: demo/stop.sh
set -eu
HOST="${1:?Uso: $0 <ip-de-tu-mac>}"
USER_NAME="${PGUSER:-demo}"

psql -h "$HOST" -U "$USER_NAME" -d arkangel_demo -v ON_ERROR_STOP=1 -q \
  -c "CREATE TABLE IF NOT EXISTS intrusion (id serial PRIMARY KEY, created_at timestamptz DEFAULT now(), junk text)"
echo "Conectado a $HOST. Insertando filas en arkangel_demo.intrusion; Ctrl-C para terminar."
# Una sola sesión abierta: así se ve que Bloquear equipo corta también la conexión en curso.
while :; do
  echo "INSERT INTO intrusion (junk) SELECT md5(random()::text) FROM generate_series(1, 100);"
  echo "SELECT 'filas: ' || count(*) FROM intrusion;"
  sleep 1
done | psql -h "$HOST" -U "$USER_NAME" -d arkangel_demo -q -t
