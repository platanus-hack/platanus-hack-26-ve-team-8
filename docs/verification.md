# Verificación — 2026-10-24

## Superado

- 38 casos de unittest de Python: análisis y permisos del recolector, exclusión de
  campos secretos, identidad del ciclo de vida de procesos, bucle de herramientas del
  modelo, paginación por marca de tiempo, minimización para la nube, rechazo de citas
  inventadas, proveedor no disponible, deduplicación del almacenamiento, API acotada,
  solicitud y respuesta reales por un socket Unix temporal con registros sintéticos,
  validación de la clave de API en la configuración inicial y callbacks de herramientas
  y comprobaciones de permisos de Claude Agent SDK.
- Se instaló `claude-agent-sdk==0.2.174` en el `.venv` arm64 nativo del repositorio.
  Su constructor de opciones real y la fábrica de MCP superan una prueba de
  compatibilidad con el cliente simulado; no se envía ninguna solicitud al modelo.
- Se hizo una prueba rápida del comando del servicio gestionado por la app con
  almacenamiento temporal y el monitoreo apagado. Se informa la disponibilidad del SDK;
  SIGTERM limpia el socket.
- El endpoint real de Models de Anthropic devolvió el rechazo esperado para una clave
  no válida a propósito, lo que demuestra la conectividad TLS con la confianza nativa de
  macOS. No se usó ninguna clave real.
- Comprobación de tipos del código fuente con Swift 6 (sin compilar el proyecto).
- Se compiló y empaquetó por separado un `.app` de desarrollo para la actualización
  ejecutable que pidió el usuario, firmado ad hoc y reabierto. No es una distribución
  notarizada.
- Una instantánea de solo lectura del equipo: procesos, escuchas TCP y LaunchAgents del
  usuario generaron registros. Solo se imprimieron recuentos agregados y la cobertura;
  ninguna instantánea del equipo se guardó ni se envió a un modelo.
- `ps` en sandbox fue denegado y se informó correctamente como cobertura reducida. Una
  instantánea sin sandbox aprobada por separado devolvió metadatos de procesos. Es
  evidencia de la CLI, no prueba de los permisos en el contexto de la app.

## Aún sin establecer

- Llamadas reales a herramientas con un modelo local y calidad de detección. Todas las
  pruebas de proveedores están simuladas.
- Configuración inicial correcta con una clave real e ida y vuelta con el Llavero,
  interacción en tiempo de ejecución entre el cliente nativo y el servicio, y
  distribución notarizada. La canalización nativa de automatización de la interfaz
  falló, así que el agente no verificó visualmente la pantalla de configuración reabierta.
- Integración de eventos de osquery: el ejecutable no está instalado en el equipo de prueba.
- Mediciones continuas de CPU y batería, pruebas prolongadas del ciclo de vida y tasas de
  detección de ataques.
- Demostraciones en vivo de instalación y persistencia o con Wi-Fi entre dos dispositivos.

Las pruebas no registraron ni dejaron en ejecución ningún servicio en segundo plano. El
SDK solicitado se instaló solo en el entorno del repositorio. No se cambiaron permisos
del sistema, no se escanearon equipos remotos ni se accedió a datos de producción. La
interfaz de Guardian queda abierta para la configuración.
