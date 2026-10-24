# Arkangel

Un investigador defensivo para macOS: observaciones locales, una IA que elige las
consultas de evidencia y una interfaz nativa para revisar los hallazgos. Es un
prototipo temprano, no un antivirus validado ni un monitor de endpoints completo.

## Monorepo

- `apps/macos`: app nativa de SwiftUI para la barra de menús y cliente de socket Unix.
- `services/agent`: servicio local en Python, historial en SQLite, recolectores e investigación guiada por modelo.
- `packages/contracts`: contrato compartido de la API local.
- `docs`: arquitectura y límites operativos.

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
automática revisa la evidencia modificada como máximo una vez por minuto y hace una
revisión exploratoria al menos cada quince minutos mientras el monitoreo está activo.
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

See the [testing README](docs/testing/README.md) for a repeatable local smoke test,
the colleague/attacker exercise, and separate detection and prevention criteria.

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m unittest discover -s services/agent/tests -v
```

Las pruebas usan registros sintéticos y respuestas simuladas del modelo y del sistema
operativo, además de un socket Unix temporal. No ejecutes compilaciones del proyecto
como verificación. Usa la comprobación de tipos de Swift como se documenta en las
instrucciones de la app para macOS.

## Límites actuales

- Instantáneas de procesos y escuchas TCP, además de metadatos de los LaunchAgents del usuario.
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
- Las acciones son solo propuestas. No se expone ninguna capacidad para detener
  procesos, borrar archivos, modificar el firewall o cambiar la persistencia.

No se incluye código de HolmesGPT/Vigil. Las investigaciones con Anthropic usan el
Claude Agent SDK oficial; los modelos locales compatibles con OpenAI mantienen el
pequeño bucle propio.
