# Arkangel

Un investigador defensivo para macOS: observaciones locales, una IA que elige las
consultas de evidencia y una interfaz nativa para revisar los hallazgos. Es un
prototipo temprano, no un antivirus validado ni un monitor de endpoints completo.

## Monorepo

- `apps/macos`: app nativa de SwiftUI para la barra de menús y cliente de socket Unix.
- `apps/web`: landing page con TanStack Start (`npm install && npm run dev:web` desde la raíz).
- `packages/figure`: la figura interactiva "Anatomy of an investigation" compartida por ambos clientes. `node packages/figure/build.mjs` regenera `apps/web/public/anatomy.html` y `apps/macos/Sources/Guardian/AnatomyFigure.swift`.
- `services/agent`: servicio local en Python, historial en SQLite, recolectores e investigación guiada por modelo.
- `packages/contracts`: contrato compartido de la API local.
- `docs`: arquitectura y límites operativos.

## Web deployment (Vercel)

Import this repository with **Root Directory** set to the repository root (`.`),
not `apps/web`. The root `vercel.json` sets the build command and publishes
`apps/web/dist/client`. TanStack Start prerenders the landing page to static HTML;
this deployment does not need a server adapter or environment variables.

After pushing changes, redeploy and check `/`, `/anatomy.html`, and `/icon.png`.
If server functions or request-time rendering are added later, this static
deployment will need a server adapter.

## Configuración inicial

Se necesitan Python 3.11+ y el Claude Agent SDK oficial para las investigaciones con
Anthropic. Instala el SDK fijado y el paquete local en un entorno virtual propio del
repositorio:

```sh
bash scripts/setup-agent.sh
```

Si tu Python predeterminado se ejecuta con Rosetta, elige un Python 3.11+ nativo para
el entorno inicial: `GUARDIAN_PYTHON=/ruta/a/python3/nativo bash scripts/setup-agent.sh`.
Un `.venv` existente se conserva.

Abre la app nativa, introduce tu clave de API de Anthropic en **Conecta tu investigador**
y revisa la casilla de procesamiento en la nube y costos de API. Conectar inicia un
servicio local si hace falta, verifica que la clave tenga acceso a Haiku 5.5 y guarda la
clave en el **Llavero de macOS**. La verificación es una solicitud de metadatos del
modelo, no una inferencia de pago, y no demuestra que la cuenta tenga créditos
suficientes para una investigación. Las claves rechazadas y los fallos de conexión
dejan la configuración abierta con un mensaje para reintentar.

Ninguna clave de API se guarda en UserDefaults, SQLite, el código fuente ni los
argumentos del proceso. Las claves enviadas al servicio permanecen en el entorno de
su proceso para la autenticación del SDK. Usa **Configurar proveedor…** en el menú
para reemplazar la clave. La app de desarrollo actual requiere este repositorio y su
`.venv`; no es un paquete distribuible independiente.

## Ejecutar el servicio local manualmente

Desde la raíz del repositorio, como alternativa al servicio gestionado por la app:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m guardian serve --watch
```

Se ejecuta en primer plano hasta pulsar Ctrl-C. No instala un launch agent ni cambia
permisos del sistema. La app se conecta a `/tmp/guardian-<uid>/agent.sock`. El
historial de SQLite se guarda en `~/Library/Application Support/Guardian` con una
retención de siete días. Cambia el almacenamiento con `--data-dir /ruta/a/directorio-privado`.
Detener el monitoreo pausa las instantáneas; detener el proceso en primer plano
termina el servicio.

Para tomar una única instantánea local de solo lectura:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m guardian scan
```

## Conectar un modelo

Anthropic es el proveedor predeterminado, con **Claude Haiku 5.5** (`claude-haiku-5-5`).
Define `ANTHROPIC_API_KEY` de forma privada en el entorno del servicio (no en un chat
ni en el código fuente). Después inicia el servicio desde esa misma terminal:

```sh
export GUARDIAN_PROVIDER=anthropic
export GUARDIAN_ALLOW_CLOUD=1
PYTHONPATH=services/agent/src .venv/bin/python -m guardian serve --watch --auto-investigate
```

`GUARDIAN_ALLOW_CLOUD=1` permite solicitudes de pago a Anthropic con metadatos
minimizados: identificadores opacos, categorías de observación, marcas de tiempo y
relaciones numéricas entre procesos. Se omiten las rutas privadas, el código, los
secretos y la pregunta en texto libre. La clave de API solo se usa en la cabecera de
autenticación; no se guarda en SQLite ni se envía en los prompts del modelo. Cambia el
modelo con `GUARDIAN_MODEL` si lo necesitas.

El servicio usa el **Claude Agent SDK**, incluido su runtime de Claude. El SDK gestiona
el bucle del agente de Anthropic; Guardian aporta herramientas de evidencia de solo
lectura, filtrado de privacidad y validación de citas. Las herramientas integradas de
shell y archivos y la configuración del proyecto están desactivadas. Las
investigaciones usan una configuración temporal aislada y desactivan la persistencia
de sesiones. No se usa ningún inicio de sesión existente de una suscripción a Claude.
Su estado muestra el proveedor y el modelo, y si el acceso a la nube está desactivado.
Con esta configuración manual, reinicia el servicio después de cambiar su entorno.

Las investigaciones responden en español; las claves JSON y los valores de estado del
protocolo se mantienen en inglés.

### Alternativa con modelo local

Usa un endpoint de modelo local compatible con OpenAI que ya esté en ejecución y admita
llamadas a herramientas. Guardian no instala un ejecutor de modelos ni elige o descarga
un modelo.

```sh
export GUARDIAN_PROVIDER=openai
export GUARDIAN_MODEL_ENDPOINT=http://127.0.0.1:1234/v1/chat/completions
export GUARDIAN_MODEL=id-de-tu-modelo-local
PYTHONPATH=services/agent/src .venv/bin/python -m guardian serve --watch --auto-investigate
```

La URL debe incluir `/v1/chat/completions`. La variable opcional `GUARDIAN_MODEL_KEY`
se lee del entorno; nunca pongas una clave real en el repositorio. La investigación
automática requiere autorización separada: la casilla de Señales o `--auto-investigate`.
Agrupa señales pendientes, con un máximo de un intento cada cinco minutos y doce
intentos en una ventana móvil de 24 horas, incluidos los fallidos. La autorización y
los intentos se conservan al reiniciar. No hay investigaciones periódicas sin señales.
Las llamadas al modelo no bloquean el recolector de instantáneas. La investigación
manual está disponible en la app o en la CLI:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m guardian investigate --question '¿Qué merece investigarse?'
```

Sin una clave de API configurada o un modelo local, las investigaciones se informan
como no concluyentes o no disponibles. No hay una IA simulada de respaldo. Los
endpoints HTTPS remotos requieren `GUARDIAN_ALLOW_CLOUD=1`; su evidencia se minimiza
de forma agresiva, lo que reduce su utilidad para investigar. Las pruebas no hacen
llamadas a modelos alojados.

## App nativa

Consulta las [instrucciones para macOS](apps/macos/README.md). La app nunca instala
dependencias ni registra elementos de inicio. Conectar puede lanzar un servicio en
primer plano propiedad de la app, que se detiene al salir de ella. La app no detiene
un servicio lanzado externamente.

## Verificación

Consulta la [guía de pruebas](docs/testing/README.md) para la comprobación local,
el ejercicio controlado y los criterios separados de detección y prevención.

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m unittest discover -s services/agent/tests -v
```

Las pruebas usan registros sintéticos y respuestas simuladas del modelo y del sistema
operativo, además de un socket Unix temporal. No ejecutes compilaciones del proyecto
como verificación. Usa la comprobación de tipos de Swift como se documenta en las
instrucciones de la app para macOS.

## Límites actuales

- Instantáneas de procesos, escuchas TCP, firewall y metadatos de los LaunchAgents del usuario,
  además de los archivos seleccionados descritos a continuación.
- Sin historial de conexiones salientes, rastreo de acceso al sistema de archivos,
  escaneos remotos, inspección completa del disco ni captura garantizada de procesos
  de corta duración.
- Solo se detecta si osquery está disponible; su integración y la evaluación de
  permisos de Endpoint Security quedan como trabajo futuro.
- Las observaciones guardadas describen lo que se vio o cambió, no un registro de
  ejecución completo. Que algo no aparezca en una instantánea posterior no demuestra
  que terminó o se limpió.
- La salida del modelo está vinculada a evidencia, pero sigue pudiendo fallar. No se
  afirma protección frente a ataques desconocidos ni atacantes guiados por IA.
- Las únicas acciones son bloquear o desbloquear el TCP entrante a un puerto (un ancla
  de pf bajo `com.apple/*`, que se borra al reiniciar) y activar el firewall de
  aplicaciones con modo sigiloso. Cada una requiere tu aprobación en el aviso de
  administrador de macOS; Claude solo puede proponerlas, y solo para puertos que se
  observaron accesibles desde otros dispositivos. No se expone ninguna capacidad para
  detener procesos, borrar archivos, permitir o abrir acceso, ni cambiar la persistencia.
- Solo se ven las escuchas del usuario actual: los servicios de root (por ejemplo SSH)
  no aparecen. Los bloqueos se guardan en memoria, así que tras reiniciar el servicio la
  app puede mostrar como desbloqueado un bloqueo que sigue activo hasta que lo bloquees
  o desbloquees de nuevo.

No se incluye código de HolmesGPT/Vigil. Las investigaciones con Anthropic usan el
Claude Agent SDK oficial; los modelos locales compatibles con OpenAI mantienen el
pequeño bucle propio.

## Vigilancia de cambios y señales

En la app puedes **Vigilar localmente sin conectar Claude**. El servicio consulta la
telemetría aproximadamente cada cinco segundos después de terminar el ciclo anterior
y revisa archivos cada treinta segundos como mínimo entre revisiones terminadas.
Una instantánea manual fuerza también la revisión de archivos, sin esperar al intervalo.
No se solapan los escaneos. La suspensión del Mac y los recolectores lentos pueden
retrasarlos; no se garantiza capturar cambios transitorios.

Se vigilan los `.plist` directamente en `~/Library/LaunchAgents`,
`/Library/LaunchAgents` y `/Library/LaunchDaemons`, además de `~/.zshenv`,
`~/.zprofile`, `~/.zshrc`, `~/.zlogin`, `~/.bash_profile`, `~/.bashrc` y `~/.profile`.
Solo se leen archivos regulares de hasta 1 MiB. Se guardan presencia, tipo,
propietario, permisos, tamaño y SHA-256; nunca su contenido. Los enlaces no se siguen.
Los archivos mayores conservan solo metadatos y declaran cobertura parcial.
Una lectura inestable o denegada conserva la referencia anterior y no inventa una
eliminación. La referencia persiste independientemente del historial de siete días.
La primera lectura establece una referencia, no declara confiable el equipo.

Las señales registran cambios de archivos, debilitamiento del firewall y nuevas
escuchas TCP fuera de loopback. Un proceso nuevo no dispara Claude por sí solo.
Reiniciar el mismo servidor con otro PID no crea una señal si conserva ejecutable,
dirección y puerto. Las señales no son pruebas de compromiso.

**Señales** muestra evidencia anterior y posterior, cobertura, cuota y motivo de espera.
Marcar una señal como revisada no borra su evidencia ni cancela su investigación.
Las señales e investigaciones se conservan siete días. Sin proveedor o ante fallos,
las señales permanecen pendientes hasta investigarse o vencer su retención.
La cuota limita intentos automáticos, no importes monetarios ni investigaciones manuales.
Una investigación inconclusa sin hipótesis queda pendiente para reintentar con los mismos límites.

La autorización para conectar Anthropic no activa la automatización. Su casilla
separada autoriza llamadas de pago con metadatos minimizados: categorías, reglas,
cambios de presencia y permisos. No se envían rutas, nombres privados, huellas ni
contenido. El SDK mantiene sus herramientas acotadas y ninguna remediación se aplica
sin aprobación individual de macOS.

Al activar la vigilancia se pide permiso para notificaciones genéricas de señales
nuevas. Si se deniega, el indicador de la barra de menús y la pantalla de señales
siguen disponibles. La consulta de estado continúa con la ventana cerrada.
Pausar impide nuevas investigaciones automáticas; una ya iniciada puede terminar.
Salir detiene únicamente el agente iniciado por la app; no se instala un servicio de inicio.
