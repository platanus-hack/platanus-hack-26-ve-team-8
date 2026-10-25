# Arkangel

**Un investigador de seguridad con IA para tu Mac.**

Los antivirus te dicen "amenaza detectada" y nada más. Arkangel te explica qué cambió,
por qué importa y qué evidencia lo respalda.

## Cómo funciona

1. **Observa localmente.** Un servicio en Python toma instantáneas de procesos,
   escuchas TCP, firewall, LaunchAgents y archivos de inicio de shell.
2. **Detecta señales.** Nuevos puertos expuestos, firewall debilitado o persistencia
   modificada generan señales con evidencia antes y después.
3. **Investiga con Claude.** El Claude Agent SDK elige qué evidencia consultar con
   herramientas de solo lectura. Solo recibe metadatos minimizados: nunca rutas
   privadas, secretos ni contenido de archivos.
4. **Responde con tu permiso.** Bloquear un puerto o un equipo remoto requiere la
   aprobación de administrador de macOS; la cuarentena de archivos propios es
   recuperable y cada intento queda registrado.

## Stack

SwiftUI (app de barra de menús) · Python + SQLite (servicio local) · Claude Agent SDK ·
TanStack Start (landing).
