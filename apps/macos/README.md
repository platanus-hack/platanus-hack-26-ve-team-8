# Guardian para macOS

Panel nativo de SwiftUI y cliente para la barra de menús. Requiere macOS 15+, Swift 6,
Python 3.11+ solo en desarrollo y empaquetado. La app instalada incluye Python y el
agente; sus usuarios no ejecutan scripts ni instalan dependencias. Para investigar con Claude se requiere una clave de API de Anthropic
con acceso a Claude Haiku 5.5; la vigilancia local funciona sin clave.

## Desarrollo desde el código fuente

Desde la raíz del repositorio, prepara el agente una vez (solo desarrolladores):

```sh
bash scripts/setup-agent.sh
```

Lanza el ejecutable de desarrollo:

```sh
cd apps/macos
swift run Guardian
```

Al iniciarse, la app debe aparecer en el Dock y mostrar el panel de Arkangel, también
cuando se ejecuta con `swift run` sin un bundle `.app`.

`swift run` compila como parte del lanzamiento. La validación durante el desarrollo usa
la comprobación de tipos en lugar de compilar el proyecto:

```sh
swiftc -typecheck -parse-as-library -swift-version 6 \
  -module-cache-path /tmp/guardian-swift-module-cache Sources/Guardian/*.swift
```

Si el entorno bloquea el sandbox anidado de plugins del compilador de Swift, añade
`-disable-sandbox` a la comprobación de tipos. No cambia los permisos de la aplicación.

## Crear la app y el instalador

El empaquetado requiere un Python portátil de
[python-build-standalone](https://github.com/astral-sh/python-build-standalone/releases),
archivo `install_only` de Python 3.11+ para macOS y la arquitectura del Mac donde se
compila (`aarch64-apple-darwin` para Apple Silicon o `x86_64-apple-darwin` para Intel).
Descarga una versión concreta, verifica su SHA-256 publicado y extrae el archivo.
No uses un `.venv`, Python de Homebrew ni el Python del sistema como runtime portátil.

Desde la raíz del repositorio:

```sh
GUARDIAN_PYTHON_RUNTIME=/ruta/al/python-extraido bash scripts/package-macos.sh
open .guardian/Arkangel.app
bash scripts/build-dmg.sh
```

Para publicarlo en la web, sube el DMG como release; el botón de descarga apunta a
`releases/latest/download/Arkangel.dmg`, así que conserva ese nombre de archivo:

```sh
gh release create v0.3.0 .guardian/Arkangel.dmg --title "Arkangel 0.3.0"
```

## Organización del espacio de trabajo

La app abre un centro de mando sin barra lateral ni pestañas. La cabecera muestra
el estado del agente; el área principal reúne exposición observada, un orbe de
evidencia y señales pendientes. El número destacado cuenta escuchas accesibles sin
bloqueo registrado: no es un porcentaje de seguridad ni demuestra un ataque.

La barra inferior permite preguntar al investigador y muestra su estado real. El
menú de la cabecera abre observaciones, señales y automatización, informes,
seguimiento completo, estado y configuración. Los paneles laterales conservan las
funciones anteriores, y sus detalles y configuración se abren en modales. Escape o
el botón Cerrar devuelve al centro de mando. La disposición pasa de tres columnas
a dos y luego a una según el ancho, con desplazamiento cuando es necesario.

El orbe representa evidencia registrada, no conexiones en tiempo real. Hacer clic
en un nodo abre sus metadatos; el registro ofrece acceso equivalente con teclado.
Las primeras señales cargadas establecen una referencia visual. Las nuevas señales
muestran un aviso dentro de la app con acciones para revisar o descartar el aviso;
descartarlo no marca la señal como revisada. Las notificaciones genéricas de macOS
siguen requiriendo autorización y un bundle compatible.

El estilo usa negro, amarillo lima y colores específicos para señales y estados.
El núcleo es simbólico; la cámara usa exposición fija y se limita el renderizado a
30 FPS. Reducir movimiento pausa las animaciones. Los porcentajes de blindaje,
tráfico entrante, ataques en curso, verificación de firmas y progresos previstos
que aparezcan en referencias de diseño no se presentan como datos de esta app.

Las acciones de defensa de red conservan la aprobación individual de administrador de
macOS: no hay ejecución de un lote con una sola aprobación. Los detalles de red y
las propuestas de los informes permiten las mismas acciones fijas del servicio.

Para revisar manualmente el diseño, comprueba ambas apariencias a 860 × 620 y
1120 × 760, la navegación con teclado, la vigilancia sin proveedor, los errores de
conexión y la apertura y cierre de la configuración desde la ventana y el menú.
Revisa también el estado sin datos, la evidencia anterior tras una desconexión y
la escena con Reducir movimiento activado. No hace falta una llamada a un modelo
para comprobar estos estados.

El empaquetador compila Swift en release, copia Python y el icono, instala el agente
con Claude Agent SDK y truststore dentro de la copia y firma el bundle localmente.
Las descargas de dependencias ocurren en la máquina de quien construye la app.
El SDK incluye su ejecutable de Claude; no se requiere una instalación global.
La comprobación de imports no inicia vigilancia ni hace llamadas a modelos.
Si `.guardian/Arkangel.app` ya existe, muévela antes de generar otra versión.
El DMG requiere `create-dmg` en la máquina de empaquetado y no sobrescribe una salida existente.

Los usuarios arrastran **Arkangel.app** a **Aplicaciones**, la abren y configuran
su clave desde la interfaz. No necesitan el repositorio ni Python instalado.
El bundle usa su propio runtime incluso si existe `GUARDIAN_REPO_ROOT`.
La firma local no sustituye la firma Developer ID ni la notarización para distribución pública.

Comprobaciones manuales del empaquetado:

```sh
python3 -m unittest discover -s scripts/tests
codesign --verify --deep --strict .guardian/Arkangel.app
```

Prueba también la app en un Mac limpio de la misma arquitectura, sin Python ni checkout:
muévela a una ruta con espacios, comprueba el icono del Dock, abre el panel y activa
la vigilancia local sin Claude. Conectar Claude debe requerir el consentimiento de
la interfaz; no es parte de las comprobaciones automáticas del paquete.

## Primera conexión

Introduce la clave en el campo seguro y da tu consentimiento explícito para que los
metadatos minimizados de la telemetría lleguen a Anthropic y para la inferencia de pago
del modelo. Conectar valida el acceso al modelo con una solicitud al proveedor que no
es de inferencia. Solo cuando la validación tiene éxito, la app guarda la clave en el
Llavero de macOS. Nunca pone la clave en UserDefaults, en argumentos del proceso, en
registros ni en el entorno de un proceso hijo. Las claves guardadas nunca se muestran.
El consentimiento se guarda aparte como una preferencia no secreta. Configurar
proveedor, en el menú, vuelve a abrir este formulario para cambiar la clave; un campo
vacío reutiliza la clave guardada.

Si no hay ningún agente accesible, Conectar inicia el Python incluido en la app
con `-I -m guardian serve --watch` como proceso hijo en primer plano. En desarrollo
usa `.venv/bin/python` y el código fuente del repositorio en `PYTHONPATH`. Envía la clave por el socket Unix cuando el agente está
listo. La app nunca instala dependencias al abrirse. Si el runtime incluido está dañado
o ausente, pide reinstalar la app. También puedes elegir **Vigilar localmente sin conectar Claude**.
La automatización requiere la autorización separada de **Señales**; conectar el
proveedor no la activa. La autorización se conserva al reiniciar.

Al abrir la app, si hay un consentimiento previo y una clave guardada en el Llavero, se
hace un único intento automático de reconexión, iniciando un agente propio en primer
plano si hace falta. Si falla, vuelve a la configuración inicial. Mientras se edita la
configuración se evita la restauración de credenciales, pero se sigue consultando
el estado y enviando avisos.

Un agente reiniciado se vuelve a configurar desde el Llavero solo cuando informa que
requiere configuración inicial y existe un consentimiento previo. Las actualizaciones
normales no vuelven a validar las credenciales. Al salir se detiene el agente que inició
esta app. Un agente iniciado de forma independiente sigue en ejecución. Cerrar solo el
panel deja en ejecución la app de la barra de menús y su agente. No se registra ningún
elemento de inicio ni servicio persistente.

## Transporte local y evidencia

Socket predeterminado: `/tmp/guardian-<uid>/agent.sock`. Cámbialo con `GUARDIAN_SOCKET`.
`GUARDIAN_REPO_ROOT` cambia la ubicación del código fuente de desarrollo; defínelo si el
ejecutable se movió o su repositorio original ya no existe.

El protocolo v1 usa una solicitud NDJSON por conexión, IDs de respuesta coincidentes,
E/S fuera del hilo principal y un límite de respuesta de 8 MB. Los plazos son de 10
segundos normalmente, 30 segundos para configurar el proveedor y 120 segundos para las
investigaciones. La aplicación consulta estado y señales cada cinco segundos,
incluso con la ventana cerrada. El menú muestra el número de señales sin revisar.
Al activar la vigilancia se solicita permiso para notificaciones genéricas; pulsarlas
abre **Señales**. Si el permiso se deniega, las señales siguen disponibles en la app.
El ejecutable suelto de `swift run`, sin identificador de bundle, usa el indicador
de la barra de menús; los avisos de macOS requieren el bundle de la aplicación.

La línea de tiempo pide hasta 500 observaciones y muestra los atributos en texto plano,
incluido el JSON anidado, en Metadatos registrados. Los hallazgos muestran hipótesis,
contraevidencia, IDs de observaciones referenciadas, pasos de herramientas,
limitaciones y acciones propuestas. Una propuesta con una acción validada de bloquear
puerto o activar el firewall ofrece un botón de aprobación que pide tu contraseña de
administrador de macOS; las propuestas de respuesta de IA remiten al historial real de
acciones y las demás se marcan como No aplicada. El contenido registrado
nunca se ejecuta como instrucciones. El estado desconectado es explícito; la evidencia
cargada antes puede seguir visible. La falta de cobertura o de hallazgos nunca implica
que este Mac sea seguro.

La interfaz está en español. Los valores del protocolo (estados, fuentes, tipos y
herramientas) llegan en inglés y se traducen solo al mostrarlos.

## Límites operativos

El bundle autónomo incluye una firma ad hoc para pruebas locales. La firma Developer ID,
la notarización, la distribución pública y el inicio al iniciar sesión están pendientes. El Llavero
puede pedir la aprobación del usuario de macOS para el ejecutable de desarrollo sin
firmar. La app suprime stdout y stderr del proceso hijo; usa la CLI en primer plano
documentada por separado para diagnósticos detallados del servicio. El lanzamiento de la
interfaz, la validación con una clave real, la interacción con el Llavero y la
inferencia de pago del modelo requieren una comprobación interactiva de extremo a
extremo y no se ejecutaron durante la verificación del código fuente. Las acciones de red
requieren aprobación en el aviso de administrador de macOS; la respuesta de IA requiere
la autorización por sesión descrita a continuación.

## Revisión manual de vigilancia

En una cuenta de prueba, activa la vigilancia sin Claude y espera a que aparezca la
última revisión de archivos. Modifica únicamente un archivo de prueba dentro de las
rutas seleccionadas, espera la siguiente revisión y comprueba el estado anterior y
posterior en **Señales**. No ejecutes ni cargues ese archivo como LaunchAgent.
Repite con eliminación, enlace simbólico y archivo mayor de 1 MiB; revisa la cobertura.

Comprueba que cerrar la ventana mantiene las revisiones y que una notificación vuelve
a abrir **Señales**. Repite denegando notificaciones y revisa el contador de la barra.
Con otra app en primer plano, pulsa **Abrir Arkangel** y comprueba que el panel aparece
delante. Repite después de cerrar el panel y después de minimizarlo. Comprueba también
**Configurar proveedor…** y **Revisar señales**: deben mostrar su contenido en el mismo
panel, sin crear ventanas adicionales, incluso si el agente está desconectado.
Salir debe detener el agente propio y conservar un agente iniciado externamente.
Las pruebas de Claude usan proveedores simulados; una comprobación real genera cargos
solo después de autorizarla. La automatización admite doce intentos en 24 horas y
separa intentos por cinco minutos; reiniciar no restablece esos límites.

## Protección guiada por IA

En **Señales**, activa **Protección guiada por IA** para autorizar respuestas durante
esta sesión del agente. No hay listas de reglas que mantener. La investigación automática
y sus costes se autorizan aparte. Con vigilancia activa, tanto investigaciones automáticas
como manuales pueden generar una respuesta si el veredicto es malicioso y cita un objetivo
elegible. Los simples cambios de archivos o nuevas escuchas no demuestran malicia.

La app muestra el historial real de acciones y permite restaurar cuarentenas sin sobrescribir
archivos. SIGKILL puede perder trabajo sin guardar; la IA puede equivocarse. Solo se actúa
sobre procesos propios y archivos vigilados elegibles dentro de la carpeta personal, después
de revalidar identidad y hash. La protección empieza desactivada al reiniciar el agente y se
limita a 20 intentos por sesión. Los bloqueos de red siguen pidiendo autorización de macOS;
no se instala un servicio privilegiado ni se promete bloquear todos los ataques.

## Diagnóstico de investigaciones no concluyentes

Cada Mac necesita configurar su propia clave de API. La app la guarda en el Llavero
con acceso limitado a ese dispositivo; copiar la app no copia la clave. Al restaurar
la conexión, la app vuelve a verificar y enviar la clave guardada al agente, aunque
este ya tenga otra configuración en memoria. Esta verificación consulta metadatos;
no realiza inferencia de pago ni garantiza saldo suficiente para investigar.

En el menú de Arkangel, selecciona **Abrir registros de diagnóstico…**. El archivo
`~/Library/Logs/Arkangel/agent.log` registra la configuración del proveedor y los
resultados de investigación. Rota a 512 KB y conserva dos copias anteriores. No
incluye claves, preguntas, evidencia, transcripciones, cuerpos de error ni stderr
del SDK. Los eventos del Llavero y del inicio/cierre del agente están en **Consola**
de macOS, filtrando por el subsistema `local.guardian.app` y la categoría
`diagnostics` (activa los mensajes informativos antes de reproducir el problema).

Reproduce el fallo y consulta el resumen completo de la investigación. Los códigos
`authentication_failed`, `billing_error`, `rate_limit`, `model_not_found`, `timeout`,
`cli_unavailable` y `sdk_missing` distinguen problemas de credenciales, facturación,
límites, acceso al modelo, tiempo de espera e instalación. `runtime_error` conserva
la privacidad cuando el SDK no entrega un código estructurado conocido. Una
investigación completada también puede ser no concluyente por falta de evidencia.
Comparte el código, la hora del fallo, la versión de la app y el registro local;
nunca compartas tu clave de API.
