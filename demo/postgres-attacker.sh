#!/bin/sh
# Demo del hackathon: se ejecuta en un SEGUNDO equipo de la misma red y simula a un intruso
# que inserta filas sin parar en el Postgres de tu Mac. Solo toca la base desechable arkangel_demo.
#
# Preparación en el Mac (solo para la demo, base desechable):
#   createdb arkangel_demo
#   postgresql.conf: listen_addresses = '*'
#   pg_hba.conf:     host arkangel_demo all 192.168.0.0/16 trust
#   brew services restart postgresql@16   # o reinicia Postgres.app
# Abre Arkangel y espera un escaneo antes de lanzar este script: la primera
# instantánea establece la línea base.
#
# Uso en el segundo equipo: demo/postgres-attacker.sh <ip-de-tu-mac>
# Al terminar, en el Mac: dropdb arkangel_demo y revierte listen_addresses y pg_hba.conf.
set -eu
HOST="${1:?Uso: $0 <ip-de-tu-mac>}"
USER_NAME="${PGUSER:-$(whoami)}"

psql -h "$HOST" -U "$USER_NAME" -d arkangel_demo -v ON_ERROR_STOP=1 -q \
  -c "CREATE TABLE IF NOT EXISTS intrusion (id serial PRIMARY KEY, created_at timestamptz DEFAULT now(), junk text)"
echo "Conectado a $HOST. Insertando filas en arkangel_demo.intrusion; Ctrl-C para terminar."
# Una sola sesión abierta: así se ve que Bloquear equipo corta también la conexión en curso.
while :; do
  echo "INSERT INTO intrusion (junk) SELECT md5(random()::text) FROM generate_series(1, 100);"
  echo "SELECT 'filas: ' || count(*) FROM intrusion;"
  sleep 1
done | psql -h "$HOST" -U "$USER_NAME" -d arkangel_demo -q -t
