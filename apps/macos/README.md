# Guardian para macOS

Panel nativo de SwiftUI y cliente para la barra de menús. Requiere macOS 15+, Swift 6,
Python 3.11+. Para investigar con Claude se requiere una clave de API de Anthropic
con acceso a Claude Haiku 5.5; la vigilancia local funciona sin clave.

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
con instrucciones. También puedes elegir **Vigilar localmente sin conectar Claude**.
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
administrador de macOS; las demás se marcan como No aplicada. El contenido registrado
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
extremo y no se ejecutaron durante la verificación del código fuente. Ninguna
remediación se ejecuta sin tu aprobación en el aviso de administrador de macOS.

## Revisión manual de vigilancia

En una cuenta de prueba, activa la vigilancia sin Claude y espera a que aparezca la
última revisión de archivos. Modifica únicamente un archivo de prueba dentro de las
rutas seleccionadas, espera la siguiente revisión y comprueba el estado anterior y
posterior en **Señales**. No ejecutes ni cargues ese archivo como LaunchAgent.
Repite con eliminación, enlace simbólico y archivo mayor de 1 MiB; revisa la cobertura.

Comprueba que cerrar la ventana mantiene las revisiones y que una notificación vuelve
a abrir **Señales**. Repite denegando notificaciones y revisa el contador de la barra.
Salir debe detener el agente propio y conservar un agente iniciado externamente.
Las pruebas de Claude usan proveedores simulados; una comprobación real genera cargos
solo después de autorizarla. La automatización admite doce intentos en 24 horas y
separa intentos por cinco minutos; reiniciar no restablece esos límites.
