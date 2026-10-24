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
- defense.apply -> status (params action "block_port"|"unblock_port"|"enable_firewall",
  port int 1-65535 para las acciones de puerto). Muestra el aviso de administrador de
  macOS y espera al usuario; si cancela, devuelve un error y no cambia nada. No existen
  acciones para permitir o abrir acceso.
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
"action"?:{"type":"block_port","port":int}|{"type":"enable_firewall"}}],
"limitations":[str]}.
Ejemplos de status: inconclusive, needs_review, no_finding. Ningún número de confianza
implica seguridad. La action de una propuesta solo se conserva si es válida; block_port
debe nombrar un puerto observado escuchando en una dirección que no sea loopback. Nada
se aplica hasta que el usuario llama a defense.apply y lo aprueba. Los atributos de
tcp_listener añaden bind_scope ("any"|"loopback"|"interface") y port; una observación
firewall tiene firewall_enabled y stealth_mode.

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
`firewall_weakened`, `listener_exposed`) y `change` (`created`, `modified`, `deleted`).
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
solo del PID. La visibilidad parcial no permite concluir que una escucha desapareció.

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
