# Arquitectura y límites

Cliente SwiftUI -> socket Unix privado -> servicio en Python -> evidencia en SQLite.
El investigador consulta una ventana acotada de evidencia registrada mediante
herramientas de solo lectura. No puede llamar a subprocesos, leer archivos arbitrarios
ni ejecutar la remediación propuesta.

Los recolectores siempre se ejecutan localmente. La recolección de procesos excluye
argv y el entorno; la inspección de arranque extrae metadatos seleccionados, no el
cuerpo de los scripts. Estos registros aún pueden contener nombres personales y
detalles de software, y se guardan localmente.

El investigador de Anthropic usa el Claude Agent SDK oficial y está guiado por el
modelo: elige búsquedas e inspecciones de entidades, considera explicaciones benignas
y produce hipótesis con referencias a la evidencia. Un ejecutor de herramientas fijo
comprueba esas referencias y aplica límites de llamadas, tiempo y tamaño de respuesta.
El texto observado son datos no confiables, nunca permiso para ejecutar o ampliar el
acceso.

La inferencia del modelo es independiente de dónde se ejecuta el servicio. La
inferencia por loopback recibe metadatos locales. La inferencia en la nube requiere
una aceptación explícita y elimina los detalles privados. Ninguna de las dos se activa
al crear el repositorio. Las pruebas no realizan inferencia con modelos; las secuencias
simuladas de llamadas a herramientas establecen el comportamiento del protocolo, no la
calidad de detección.

## Siguiente umbral de evidencia

1. Ejecutar la app y el recolector con una cuenta de usuario normal; revisar la cobertura.
2. Configurar un modelo local elegido y probar llamadas reales a herramientas con registros sintéticos.
3. Evaluar una secuencia de instalación benigna reservada junto con actividad normal.
4. Solo después, decidir sobre la recolección de eventos de osquery, permisos más
   amplios y capacidades de remediación aprobadas expresamente.

Ningún fixture instala persistencia ni inicia un proceso en segundo plano en este
repositorio. Una demostración en vivo de ese tipo sigue siendo una acción separada y
explícita.
