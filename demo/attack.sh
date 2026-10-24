#!/bin/sh
# Demo del hackathon: simula dos puntos de apoyo de un atacante en ESTE Mac para que Arkangel los detecte.
# Inofensivo y reversible con demo/cleanup.sh:
# - un LaunchAgent que imita una etiqueta de Apple (nunca se carga; como mucho se ejecuta una vez en el próximo inicio de sesión y termina),
# - una copia renombrada de /usr/bin/nc escuchando en 127.0.0.1:4444 (solo loopback, nada sale del Mac).
set -eu
STATE="${TMPDIR:-/tmp}/arkangel-demo"
BINARY="$STATE/softwareupdated"
PLIST="$HOME/Library/LaunchAgents/com.apple.softwareupdate.helper.plist"

mkdir -p "$STATE" "$HOME/Library/LaunchAgents"
cp /usr/bin/nc "$BINARY"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.apple.softwareupdate.helper</string>
  <key>ProgramArguments</key><array><string>$BINARY</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

"$BINARY" -lk 127.0.0.1 4444 >/dev/null 2>&1 &
echo $! > "$STATE/listener.pid"

echo "Plantado $PLIST"
echo "Escuchando como softwareupdated en 127.0.0.1:4444 (pid $(cat "$STATE/listener.pid"))"
echo "Ejecuta demo/cleanup.sh al terminar la demo y antes de cerrar sesión."
