# Arkangel — team-8 Platanus Hack 26: Caracas ft. Yummy

<img src="./project-logo.png" alt="Logo de Arkangel" width="200" />

Track: 🧊 Three-Dimensional

Investigador defensivo para macOS: observa tu Mac localmente, detecta cambios
sospechosos y deja que Claude investigue con evidencia citada. Es un prototipo, no
un antivirus.

- Landing: https://web-sage-three-12.vercel.app

## Equipo

- Chris Pacheco ([@chrisdadev13](https://github.com/chrisdadev13))
- Isaac ([@bigdog1400](https://github.com/bigdog1400))
- Michael Chacon ([@mcljs](https://github.com/mcljs))
- Antonio Rojas ([@antonio-innova](https://github.com/antonio-innova))

## Monorepo

- `apps/macos`: app nativa de SwiftUI para la barra de menús.
- `apps/web`: landing con TanStack Start (`npm install && npm run dev:web`).
- `services/agent`: servicio local en Python (recolectores, SQLite, investigación con el Claude Agent SDK).
- `packages/contracts`: protocolo compartido entre clientes y servicio.
- `packages/figure`: figura interactiva compartida por ambos clientes.
- `demo`: ejercicio controlado de ataque y limpieza.
- `docs`: arquitectura, límites y pruebas.

## Inicio rápido

```sh
bash scripts/setup-agent.sh
PYTHONPATH=services/agent/src .venv/bin/python -m guardian serve --watch
```

Abre la app de macOS ([instrucciones](apps/macos/README.md)) y conecta tu clave de
Anthropic; se guarda en el Llavero de macOS.

Pruebas:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m unittest discover -s services/agent/tests -v
```

Configuración de modelos, privacidad, vigilancia, despliegue en Vercel y límites
actuales: [guía detallada](docs/setup.md).
