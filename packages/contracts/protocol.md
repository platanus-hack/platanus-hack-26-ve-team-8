# Protocolo local de Guardian v1

Transporte: JSON delimitado por saltos de línea sobre un socket de dominio Unix. Una
solicitud y una respuesta por conexión; sin puerto TCP. Socket predeterminado:
/tmp/guardian-<uid>/agent.sock (se cambia con GUARDIAN_SOCKET en ambos lados), con el
directorio en modo 0700. Solicitud: {"id":"uuid", "method":"status", "params":{}}.
Respuesta: {"id":"uuid", "result": ...} o {"id":"uuid", "error":{"message":"..."}}.

Idioma: los nombres de métodos, campos y valores enumerados (status, source, kind,
tool, "not_configured") se mantienen en inglés porque forman parte del contrato. Todo
el texto libre para personas (mensajes de error, summary, detail, title, statement,
counterevidence, limitations, descripciones de acciones) se escribe en español. Los
clientes traducen los valores enumerados solo al mostrarlos.

Métodos:
- status -> {"monitoring":bool,"provider":str,"coverage":[{"source":str,"status":str,"detail":str}],"observation_count":int,"last_scan":str|null,"onboarding_required":bool,"sdk_available":bool,
  "firewall":{"firewall_enabled":bool,"stealth_mode":bool}|null,
  "exposed":[{"port":int,"executable":str,"bind_scope":"any"|"interface","blocked":bool}],
  "blocked_ports":[int],
  "blocked_peers":[str],
  "last_file_scan":str|null,
  "alerts":{"unacknowledged":int,"pending":int},
  "automation":{"enabled":bool,"reason":str,"remaining":int,"cooldown_seconds":int}}
- provider.configure -> status (params api_key string, allow_cloud true). La
  configuración inicial, iniciada por el usuario, comprueba la disponibilidad del SDK y
  después valida la clave y el modelo con un GET a la API Models de Anthropic. Sin
  llamada de inferencia. Si tiene éxito, selecciona Anthropic / claude-haiku-5-5 solo
  para el proceso del servicio; el cliente nativo guarda la clave en el Llavero. La
  clave nunca aparece en respuestas, registros ni en la base de datos.
- observations -> {"items":[Observation]} (params limit, predeterminado 100, máximo 500)
- investigations -> {"items":[Investigation]}
- scan -> status (instantánea local explícita de solo lectura)
- investigate -> Investigation (params question opcional; usa la evidencia registrada)
- defense.apply -> status (params action "block_port"|"unblock_port"|"enable_firewall"|
  "block_peer"|"unblock_peer", port int 1-65535 para las acciones de puerto). block_peer
  recibe observation_id de una observación tcp_connection registrada; el servicio lee la
  IP remota de esa evidencia local, nunca del cliente ni del modelo. Bloquea paquetes
  entrantes de esa IP y elimina sus estados de pf, lo que corta también la sesión ya
  abierta. unblock_peer recibe address, que debe estar en blocked_peers. Muestra el aviso
  de administrador de macOS y espera al usuario; si cancela, devuelve un error y no
  cambia nada. No existen acciones para permitir o abrir acceso.
- monitoring.set -> status (params enabled bool; solo afecta al ciclo de vida del servicio en primer plano)
- alerts -> {"items":[Alert]} (params limit opcional, predeterminado 100, máximo 500).
  Orden descendente de creación; conserva siete días.
- alerts.acknowledge -> status (params id string, 1–100 caracteres). Marca una señal
  como revisada; un ID desconocido devuelve error. No borra evidencia ni referencia y
  no la retira de la cola de investigación.
- automation.set -> status (params enabled bool, consent true al activar). Consentimiento
  explícito para investigaciones automáticas y sus cargos, independiente de
  provider.configure. Se persiste en SQLite; desactivar no cancela trabajos ya iniciados.
- investigation.progress -> {"active":bool,"started_at":str|null,"steps":[{"tool":str,"summary":str,
  "evidence_ids":[str]}]} (última investigación, incluida una iniciada por --watch; consultar periódicamente mientras esté activa)

Observation: {"id":str,"timestamp":str ISO8601 UTC,"kind":str,
"source":str,"entity":str,"summary":str,"attributes":object}.
Investigation: {"id":str,"created_at":str,"status":str,"title":str,
"summary":str,"hypotheses":[{"statement":str,"status":str,
"evidence_ids":[str],"counterevidence":str}],"steps":[{"tool":str,
"summary":str}],"proposed_actions":[{"title":str,"description":str,
"action"?:{"type":"block_port","port":int}|{"type":"block_peer","observation_id":str}|
{"type":"enable_firewall"}}],
"limitations":[str]}.
Ejemplos de status: inconclusive, needs_review, no_finding. Ningún número de confianza
implica seguridad. La action de una propuesta solo se conserva si es válida; block_port
debe nombrar un puerto observado escuchando en una dirección que no sea loopback y
block_peer una observación tcp_connection que el modelo inspeccionó. Nada
se aplica hasta que el usuario llama a defense.apply y lo aprueba. Los atributos de
tcp_listener añaden bind_scope ("any"|"loopback"|"interface") y port; una observación
firewall tiene firewall_enabled y stealth_mode. Una observación `tcp_connection` (fuente
`tcp_connections`) es una conexión TCP establecida desde otro equipo hacia un puerto local
en escucha; se omiten loopback, las salientes y las del propio Mac a su IP. Atributos:
pid, executable, direction ("inbound"), local_address, local_port, remote_address,
remote_port y remote_scope ("lan"|"public"). lsof ve los procesos del usuario y netstat
añade los sockets de otros usuarios (como el sshd de root de Inicio de sesión remoto) en
las mismas fuentes `tcp_listeners` y `tcp_connections`. La fuente `ssh_logins` produce una
`tcp_connection` por equipo con intentos de SSH fallidos en el registro del sistema de los
últimos dos minutos: executable "sshd", local_port 22, sin remote_port ni pid, y
auth_failures int (intentos distintos). El usuario probado no se guarda. block_peer la acepta
igual que cualquier tcp_connection.
La nube recibe local_port, remote_port, auth_failures, remote_scope y direction, nunca remote_address.

Cargas de ejemplo: fixtures.json. services/agent/tests/test_contract.py comprueba la
salida de Python contra ese archivo; mantenlo sincronizado con los modelos de Swift en
AgentClient.swift.

## Interfaces de los módulos de Python

telemetry.py: collect_snapshot() -> tuple[list[dict], list[dict]] (observaciones, cobertura).
Cada observación tiene todos los campos anteriores, IDs UUID y hora UTC. El recolector no
guarda estado persistente. Solo inspección local de solo lectura con comandos fijos; sin
secretos del entorno ni de la línea de comandos.

investigator.py: investigate(observations: list[dict], question: str = "",
coverage: list[dict] | None = None, on_step=None) -> dict (Investigation).
Si se proporciona on_step, recibe cada paso de herramienta con los IDs reales de las
observaciones que leyó.
Selección del proveedor con GUARDIAN_MODEL_ENDPOINT / GUARDIAN_MODEL / GUARDIAN_MODEL_KEY.
GUARDIAN_PROVIDER selecciona anthropic u openai. El predeterminado es anthropic con
claude-haiku-5-5 y ANTHROPIC_API_KEY; si existe GUARDIAN_MODEL_ENDPOINT y no se definió
el proveedor, se selecciona openai. La falta de credenciales o configuración produce un
resultado explícito no disponible/no concluyente (nunca se finge una inferencia).
Anthropic usa el Claude Agent SDK oficial con herramientas MCP propias de evidencia de
solo lectura, sin herramientas integradas ni configuración del proyecto, y con turnos y
tiempo acotados. Los proveedores locales compatibles con OpenAI mantienen el endpoint
de chat completions configurado y el bucle local de herramientas.
Un endpoint en la nube requiere GUARDIAN_ALLOW_CLOUD=1; incluso así, usa metadatos
minimizados. El bucle de herramientas opera sobre las observaciones registradas
recibidas. Las pruebas pueden inyectar o simular respuestas HTTP; sin llamadas reales a
modelos.

## Vigilancia y compatibilidad

Los campos nuevos de status son aditivos; los clientes deben admitir su ausencia al
conectarse a un servicio anterior y ocultar los controles nuevos. Los métodos previos
mantienen su forma. `last_file_scan` es la fecha del último intento de revisión de
archivos, no una garantía de cobertura completa. Consultar `coverage` para sus límites.

Alert: {"id":str,"created_at":str ISO8601 UTC,"reason":str,
"signal":Observation,"before":Observation|null,"after":Observation,
"acknowledged":bool,"investigated":bool}.
La señal tiene kind `detection` y atributos `rule` (`file_changed`,
`firewall_weakened`, `listener_exposed`, `inbound_connection`) y `change` (`created`, `modified`, `deleted`).
El estado anterior es null cuando no existe evidencia anterior disponible.
Los estados incrustados preservan sus IDs incluso si venció su observación histórica.
La evidencia de una señal se conserva hasta que la señal vence a los siete días.

Las observaciones `file` usan las fuentes `user_launch_files`, `system_launch_agents`,
`system_launch_daemons` y `shell_files`. Sus atributos contienen `present` y `category`
(`launch_agent`, `launch_daemon`, `shell_startup`). Cuando están presentes incluyen
`file_type` (`regular`, `symlink`, `other`), `owner`, `mode` y `size`. `sha256` solo
existe para archivos regulares legibles de hasta 1 MiB. Los archivos mayores llevan
`hash_available: false` y cobertura parcial; los enlaces no se siguen.
Una lectura fallida produce metadatos `readable: false` sin afirmar presencia ni
ausencia. Conserva la referencia válida anterior; si nunca hubo una, establece una
entrada desconocida para no confundir la primera lectura válida con una creación.
Las señales de archivo pueden incluir `previous_mode`, `mode`, `previous_owner` y
`owner` como evidencia estructurada del cambio. Los clientes traducen los enumerados.

La referencia persistente se inicializa por fuente y archivo; los directorios vacíos
inspeccionados correctamente también establecen referencia. Los archivos inaccesibles
conservan su último estado válido. Una ausencia comprobada produce un estado
`present: false`, nunca una inferencia a partir de un fallo de lectura.
Las escuchas se identifican por ejecutable, dirección, puerto y alcance, sin depender
solo del PID. Las conexiones entrantes se identifican por ejecutable, puerto local e IP
remota: un equipo genera una señal `inbound_connection` por servicio, no una por cada
puerto efímero o reconexión. La visibilidad parcial no permite concluir que una escucha desapareció.

`automation.reason` puede ser `disabled`, `paused`, `provider_unavailable`,
`cloud_disabled`, `investigating`, `no_signals`, `quota_exhausted`, `cooldown` o `ready`.
`remaining` indica intentos automáticos restantes en una ventana móvil de 24 horas.
Cada intento se reserva en SQLite antes de llamar al modelo; los fallidos cuentan.
Se permiten doce intentos por ventana y un intervalo mínimo de 300 segundos.
La falta de señales no genera investigaciones. Las manuales comparten el bloqueo de
concurrencia, pero no consumen cuota automática. Una investigación inconclusa sin
hipótesis deja sus señales pendientes; los demás resultados completan el lote.
Una pausa bloquea nuevos trabajos automáticos, no cancela uno iniciado.

Cada investigación prioriza hasta 100 señales pendientes (las más antiguas primero)
con sus estados anterior y posterior, y añade contexto hasta 500 observaciones únicas.
Cualquier recorte se declara en coverage. Una señal surgida durante la investigación
queda pendiente para la siguiente. Los fallos y la falta de proveedor no eliminan señales.

La nube solo recibe enumerados validados, cambios de presencia y permisos y los
metadatos numéricos ya permitidos. No recibe rutas, nombres privados, contenido ni
huellas SHA-256. El modelo mantiene exclusivamente herramientas de evidencia de solo
lectura; ninguna señal ni resultado autoriza remediación.

## Laboratorio local cooperativo (opcional)

`status.demo` es aditivo; clientes anteriores lo pueden omitir. Contiene
`{enabled: bool, session_id: string|null, directory: string|null,
uploads_blocked: bool, config_state: "not_prepared"|"safe"|"unsafe"|"unavailable",
events: [Observation]}`. `events` conserva las últimas 12 entradas de esta sesión;
el historial de metadatos usa la retención normal de observaciones. Un servicio
reiniciado empieza con el laboratorio desactivado. Los estados seguro/vulnerable
se refieren exclusivamente a su configuración ficticia, nunca al Mac completo.

- `demo.prepare` recibe exclusivamente `{consent: true}` y devuelve status. Invalida
  la sesión anterior y crea un directorio privado nuevo dentro de `<data-dir>/demo/`
  con `.env` de contenido ficticio fijo y `config.json` inicialmente seguro.
- `demo.attach` recibe `{}` y devuelve `{session_id: string, directory: string,
  config_device: string, config_inode: string}`. Los últimos dos campos son números
  decimales como texto para no perder precisión en JavaScript. Identifican el archivo
  config original que Frame puede debilitar; no se acepta una sustitución de ese archivo.
- `demo.report` recibe exclusivamente `{session_id: string, event: string}` con event
  `file_read`, `upload_attempt`, `upload_succeeded` o `upload_blocked`. Rechaza otros
  campos, contenido, rutas, PID, órdenes, sesiones anteriores y más de 100 informes por
  sesión. Comprueba config localmente antes de registrar el informe y devuelve
  `{allowed: bool}`. Solo permite envíos si el laboratorio sigue activo, no se ha
  bloqueado y config tiene `allow_uploads: true` y `redact_secrets: false`.
- `demo.repair` recibe exclusivamente `{session_id: string, consent: true}` y devuelve
  status. Primero deniega envíos posteriores, después conserva config como
  `config.before-repair.json` sin sobrescribir y publica valores fijos seguros
  (`allow_uploads: false`, `redact_secrets: true`). Verifica el resultado. La ventana
  sin config y cualquier fallo deniegan envíos; los archivos se conservan para revisión.
- `demo.stop` recibe `{}` y devuelve status. Desactiva el laboratorio y su permiso
  cooperativo sin borrar los archivos generados.

Las observaciones usan source `demo_lab`, kind `demo_config` o `demo_activity`,
`attributes.simulation: true`, un event enumerado y trust `local_check` o
`self_reported`. Las comprobaciones de config incluyen solo sus booleanos validados
y config_state; no almacenan contenido arbitrario. Los demás eventos locales son
`prepared`, `config_safe`, `config_unsafe`, `config_unavailable`, `repair_attempt`,
`repair_succeeded`, `repair_failed` y `stopped`. Ninguna solicitud acepta un objetivo
de reparación elegido por Frame o un modelo.

El cliente Frame del laboratorio verifica el marcador ficticio y la identidad original
de config antes de cambiarlo. Solo envía bytes constantes a `127.0.0.1:8787/collect`,
sin redirecciones ni llamadas a modelos. Comprueba el permiso antes de cada envío;
una solicitud ya iniciada puede terminar. Un informe de envío no prueba su recepción.
La comprobación de config también ocurre en las instantáneas, aunque no haya informes.
Un archivo ilegible, inestable, enlazado, no propio, mayor de 4 KiB o con JSON fuera
del formato fijo no autoriza envíos.

Estos eventos se muestran en su panel de laboratorio y en Observaciones. La primera
configuración vulnerable y cada primer informe de lectura, intento de envío, envío
completado o reparación fallida crean una alerta por sesión con rule
`demo_config_unsafe`, `demo_file_read`, `demo_upload_attempt`, `demo_upload_succeeded`
o `demo_repair_failed`. Se incluyen en el contador sin revisar y en el orbe, con sus
etiquetas de demo y confianza. Se mantienen fuera de `alerts(pending=True)`, del
contador `alerts.pending` y del contexto de IA; no generan cargos automáticos ni
habilitan acciones contra procesos o archivos reales. El laboratorio es una integración
cooperativa, no auditoría del sistema operativo, bloqueo de salida general ni un cambio
de los límites de `defense.py` o `response.py`.

## Respuesta guiada por IA (opcional)

`status.protection` es aditivo: `{enabled: bool, remaining: int, events: [ResponseEvent]}`.
Clientes antiguos pueden omitirlo; el cliente nativo solo muestra los controles si existe.
La web es informativa y no controla el socket. Las propuestas previas de red no cambian.

- `protection.set` recibe `enabled: bool` y exige `consent: true` al activar.
  Autoriza respuestas automáticas de IA durante la vida de este servicio, sin confirmar
  cada una. No autoriza llamadas de pago ni activa `automation.set`; esos controles
  mantienen su consentimiento independiente. No se permite habilitar como root.
- `protection.restore` recibe `id: string` (ID del evento) y `consent: true`.
  Restaura una cuarentena completada sin sobrescribir el destino ni ejecutar el archivo;
  recupera sus permisos y excluye esa ruta y SHA-256 durante la sesión.
- Ambos devuelven `status`. Desactivar protección invalida resultados en curso.
  Pausar vigilancia también invalida resultados anteriores; una acción ya iniciada puede terminar.

Antes de una investigación con vigilancia y protección activas, el servicio captura hasta
20 objetivos locales elegibles. Solo añade `attributes.response_action` (`terminate_process`
o `quarantine_file`) a la copia de evidencia del investigador. Rutas, hashes e identidades
nativas permanecen locales; la minimización en la nube conserva únicamente la elegibilidad.

Una propuesta nueva usa `action: {type: "terminate_process"|"quarantine_file",
observation_id: string, verdict: "malicious"}`. Se conserva solo si el modelo inspeccionó
la observación, una hipótesis la cita, el tipo coincide con su elegibilidad y el resultado
es `needs_review`. Los alias de nube se traducen a IDs reales antes de responder. No se
aceptan rutas, PID o comandos del modelo. Los clientes deben tratar tipos desconocidos
como propuestas sin botón ejecutable, nunca como `enable_firewall`.

La respuesta ocurre después de guardar la investigación, también en investigaciones
manuales si la protección está habilitada. Antes de actuar, comprueba nuevamente el
archivo y su SHA-256 y, para procesos, la identidad nativa de macOS. La señal SIGKILL
usa PID y versión mediante audit token; no hay fallback a `kill(pid)`. Una señal enviada
no confirma por sí sola la salida ni impide que un supervisor reinicie el proceso.

Solo son elegibles archivos regulares del usuario dentro de su carpeta personal, de
hasta 100 MiB, sin enlaces simbólicos/múltiples ni bits setuid/setgid. Se excluyen el
runtime y los datos de Guardian. La cuarentena se limita a archivos ya vigilados de
`user_launch_files` y `shell_files`; no inspecciona todo el disco. Los procesos deben
pertenecer al usuario, coincidir con el inicio registrado y ejecutar un archivo elegible.
Se excluyen procesos del sistema, el agente y sus antecesores observados. Un script
interpretado no se identifica a partir de su contenido o de argumentos privados.

`ResponseEvent` contiene `id`, `observation_id`, `investigation_id`, `action`, `path`,
`sha256`, `created_at`, `status`, `detail` y metadatos locales de recuperación.
Estados: `pending`, `termination_requested`, `quarantined`, `restoring`, `restored`,
`recovery_required`, `failed`. El historial no se elimina con la retención de siete días.
La respuesta muestra las últimas 100 acciones y todas las no resueltas. Hay un límite de
100 acciones/archivos no resueltos para iniciar cuarentenas y 20 intentos de ejecución
por sesión. Alcanzar el último desactiva protección; alternar la casilla no reinicia la cuota.

La cuarentena usa `<data-dir>/quarantine/<event-id>/payload`, directorios privados y
movimiento exclusivo sin sobrescritura; no copia entre volúmenes. Conserva un diario antes
del movimiento. Una interrupción deja `pending`/`restoring`, o un cambio concurrente puede
dejar `recovery_required`: conserva los datos y requiere recuperación manual desde el diario.
No borres estos archivos ni la base de datos. Quitar permisos de ejecución no aísla el
contenido frente a otro proceso del mismo usuario ni revoca descriptores ya abiertos.

Un veredicto malicioso no es una prueba independiente. La evidencia actual es metadatos;
si solo demuestra cambios o exposición, el modelo debe abstenerse. Los falsos positivos
pueden causar pérdida de trabajo o cambios de configuración. Esta respuesta no bloquea
ataques arbitrarios, ejecución inicial ni conexiones salientes. Los cambios de red mantienen
la aprobación de administrador existente; no se instala un componente privilegiado.

Referencias de implementación nativa: la estructura de identidad se corresponde con
[`proc_info_private.h` de Apple](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h)
y la señal versionada usa el
[wrapper `proc_signal_with_audittoken` de Apple](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c).
Si la API o el tamaño de la estructura no están disponibles, se omite el objetivo;
no se degrada a una señal por PID sin versión.
