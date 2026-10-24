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
  "blocked_ports":[int]}
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
