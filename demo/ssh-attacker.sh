#!/bin/sh
# Demo del hackathon: se ejecuta en el equipo de un compañero en la misma red y simula a un
# intruso que intenta entrar por SSH en tu Mac.
#
# Preparación en tu Mac (solo para la demo): Ajustes del Sistema > General > Compartir >
# Inicio de sesión remoto. Abre Arkangel y espera un escaneo antes de lanzar este script:
# el primer escaneo establece la línea base. Desactiva Inicio de sesión remoto al terminar.
#
# Uso en el otro equipo: demo/ssh-attacker.sh <ip-de-tu-mac> [usuario-válido]
# Fase 1, sin credenciales: prueba usuarios inventados; Arkangel avisa "intenta entrar por SSH".
# Fase 2, solo con usuario válido: abre una sesión que imprime la hora cada segundo; al pulsar
# Bloquear equipo en Arkangel, la sesión se corta.
set -eu
HOST="${1:?Uso: $0 <ip-de-tu-mac> [usuario-válido]}"
OPTS="-o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

for user in admin root test oracle postgres ubuntu guest support; do
  # BatchMode no pide contraseña: cada intento falla y sshd lo registra con la IP de este equipo.
  # shellcheck disable=SC2086
  ssh $OPTS -o BatchMode=yes "$user@$HOST" true 2>/dev/null || true
  echo "Intento fallido como $user"
  sleep 1
done

[ $# -ge 2 ] || exit 0
echo "Abriendo una sesión como $2; Ctrl-C para terminar."
# shellcheck disable=SC2086
ssh $OPTS -o ServerAliveInterval=2 -o ServerAliveCountMax=2 "$2@$HOST" \
  'while :; do date "+sesión abierta %T"; sleep 1; done' || true
echo "La sesión terminó. Si no pulsaste Ctrl-C, Arkangel bloqueó este equipo."
