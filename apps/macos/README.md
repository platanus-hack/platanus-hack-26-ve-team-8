# Guardian para macOS

Panel nativo de SwiftUI y cliente para la barra de menús. Requiere macOS 15+, Swift 6,
Python 3.11+ y una clave de API de Anthropic con acceso a Claude Haiku 5.5.

Desde la raíz del repositorio, prepara el agente una vez:

```sh
bash scripts/setup-agent.sh
```

Lanza el ejecutable de desarrollo:

```sh
cd apps/macos
swift run Guardian
```

`swift run` compila como parte del lanzamiento. La validación durante el desarrollo usa
la comprobación de tipos en lugar de compilar el proyecto:

```sh
swiftc -typecheck -parse-as-library -swift-version 6 \
  -module-cache-path /tmp/guardian-swift-module-cache Sources/Guardian/*.swift
```

Si el entorno bloquea el sandbox anidado de plugins del compilador de Swift, añade
`-disable-sandbox` a la comprobación de tipos. No cambia los permisos de la aplicación.

Para empaquetar el bundle de `scripts/package-macos.sh` en un instalador para arrastrar
a Aplicaciones (requiere `create-dmg`; escribe `.guardian/Arkangel.dmg` y nunca
sobrescribe):

```sh
bash scripts/build-dmg.sh [ruta/a/Arkangel.app] [ruta/a/salida.dmg]
```

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

Si no hay ningún agente accesible, Conectar inicia `.venv/bin/python -m guardian
serve --watch` del repositorio como proceso hijo en primer plano, con el directorio del
código fuente en `PYTHONPATH`. Envía la clave por el socket Unix cuando el agente está
listo. La app nunca instala dependencias. Si falta la configuración, muestra un error
con instrucciones. El monitoreo recolecta evidencia local; las investigaciones solo se
ejecutan cuando se piden explícitamente, sin investigaciones automáticas del modelo al
arrancar.

Al abrir la app, si hay un consentimiento previo y una clave guardada en el Llavero, se
hace un único intento automático de reconexión, iniciando un agente propio en primer
plano si hace falta. Si falla, vuelve a la configuración inicial. Mientras se edita la
configuración se pausan la actualización y la restauración automática.

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
investigaciones. Las escenas activas del panel se actualizan cada 15 segundos. Cerrar o
desactivar el panel detiene la actualización automática; la actualización explícita
desde el menú sigue disponible.

La línea de tiempo pide hasta 500 observaciones y muestra los atributos en texto plano,
incluido el JSON anidado, en Metadatos registrados. Los hallazgos muestran hipótesis,
contraevidencia, IDs de observaciones referenciadas, pasos de herramientas,
limitaciones y acciones propuestas marcadas como No aplicada. El contenido registrado
nunca se ejecuta como instrucciones. El estado desconectado es explícito; la evidencia
cargada antes puede seguir visible. La falta de cobertura o de hallazgos nunca implica
que este Mac sea seguro.

La interfaz está en español. Los valores del protocolo (estados, fuentes, tipos y
herramientas) llegan en inglés y se traducen solo al mostrarlos.

## Límites operativos

Solo ejecutable de desarrollo: el empaquetado del bundle de la app, la firma, la
notarización, la distribución y el inicio al iniciar sesión están pendientes. El Llavero
puede pedir la aprobación del usuario de macOS para el ejecutable de desarrollo sin
firmar. La app suprime stdout y stderr del proceso hijo; usa la CLI en primer plano
documentada por separado para diagnósticos detallados del servicio. El lanzamiento de la
interfaz, la validación con una clave real, la interacción con el Llavero y la
inferencia de pago del modelo requieren una comprobación interactiva de extremo a
extremo y no se ejecutaron durante la verificación del código fuente. No se ejecuta
ninguna remediación.
