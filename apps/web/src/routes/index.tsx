import { useEffect, useRef, useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'

const REPO = 'https://github.com/chrisdadev13/arkangel'
const DOWNLOAD = `${REPO}/releases/latest`

export const Route = createFileRoute('/')({ component: Home })

const steps = [
  {
    title: 'Observa localmente',
    body: 'El servicio registra procesos, escuchas TCP, firewall y cambios en archivos seleccionados de persistencia y configuración. Conserva siete días de evidencia local.',
  },
  {
    title: 'Investiga con Claude',
    body: 'Claude Agent SDK consulta evidencia de solo lectura y considera explicaciones benignas. Con autorización separada, investiga señales automáticamente: una vez cada cinco minutos y doce intentos en 24 horas.',
  },
  {
    title: 'Revisa la evidencia',
    body: 'Las señales conservan evidencia anterior y posterior. Los hallazgos citan observaciones, incluyen contraevidencia y limitaciones y proponen acciones que requieren aprobación.',
  },
]

const features = [
  {
    title: 'App nativa de macOS',
    body: 'Panel SwiftUI y barra de menús conectados mediante un socket Unix privado. Cerrar la ventana mantiene la vigilancia; salir detiene el agente propio.',
  },
  {
    title: 'Privacidad por defecto',
    body: 'El procesamiento en la nube requiere consentimiento. Solo salen metadatos minimizados; el contenido de los archivos vigilados no se guarda ni se envía.',
  },
  {
    title: 'Herramientas acotadas',
    body: 'El modelo solo recibe herramientas de evidencia de solo lectura. Sin shell arbitraria, lecturas libres del disco ni remediación automática.',
  },
  {
    title: 'Claves en el Llavero',
    body: 'La clave de Anthropic se verifica y se guarda en el Llavero de macOS. Nunca aparece en registros, ajustes ni prompts.',
  },
  {
    title: 'Telemetría no confiable',
    body: 'Los datos observados se tratan como evidencia, nunca como instrucciones. Una señal requiere revisión y no confirma un compromiso.',
  },
  {
    title: 'Opción de modelo local',
    body: 'La detección local funciona sin conexión ni clave. También puedes configurar un endpoint local compatible con OpenAI y llamadas a herramientas.',
  },
]

function Home() {
  return (
    <main>
      <header className="hero">
        <img src="/icon.png" alt="" width={96} height={96} />
        <h1>Arkangel</h1>
        <p className="lead">
          Un investigador con IA para tu Mac. Detecta cambios locales, pide a Claude que analice la evidencia
          y te avisa de qué merece una revisión y por qué.
        </p>
        <div className="cta">
          <a className="button primary" href={DOWNLOAD}>
            Descargar para macOS
          </a>
          <a className="button" href={REPO}>
            Ver en GitHub
          </a>
        </div>
        <p className="note">macOS 15+ · Versión preliminar para desarrollo</p>
      </header>

      <section>
        <h2>Anatomía de una investigación</h2>
        <Figure />
      </section>

      <section>
        <h2>Cómo funciona</h2>
        <ol className="steps">
          {steps.map((s, i) => (
            <li key={s.title}>
              <span className="num">{i + 1}</span>
              <h3>{s.title}</h3>
              <p>{s.body}</p>
            </li>
          ))}
        </ol>
      </section>

      <section>
        <h2>Diseñado para investigar y defender</h2>
        <div className="grid">
          {features.map((f) => (
            <article key={f.title}>
              <h3>{f.title}</h3>
              <p>{f.body}</p>
            </article>
          ))}
        </div>
      </section>

      <section>
        <h2>Para el jurado</h2>
        <p>Ejecuta el código fuente en tres pasos:</p>
        <pre>
          <code>{`git clone ${REPO} && cd arkangel
bash scripts/setup-agent.sh
cd apps/macos && swift run Guardian`}</code>
        </pre>
        <p>
          Activa la vigilancia local o añade una clave de Anthropic en <strong>Conecta tu investigador</strong>.
          En Señales puedes autorizar investigaciones automáticas y avisos de macOS. Es un prototipo temprano,
          no un antivirus validado: la ausencia de hallazgos no garantiza seguridad.
        </p>
      </section>

      <footer>
        <a href={REPO}>GitHub</a> · Creado para el hackathon con Claude
      </footer>
    </main>
  )
}

// Figura compartida con macOS, generada por packages/figure/build.mjs; comunica su altura.
function Figure() {
  const ref = useRef<HTMLIFrameElement>(null)
  const [height, setHeight] = useState(620)
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (event.source === ref.current?.contentWindow && typeof event.data?.anatomyHeight === 'number') {
        setHeight(event.data.anatomyHeight)
      }
    }
    window.addEventListener('message', onMessage)
    // La figura puede comunicar su altura antes de registrar el receptor; se vuelve a solicitar.
    ref.current?.contentWindow?.postMessage('anatomy:measure', '*')
    return () => window.removeEventListener('message', onMessage)
  }, [])
  return (
    <iframe
      ref={ref}
      className="figure"
      src="/anatomy.html#web"
      onLoad={(event) => event.currentTarget.contentWindow?.postMessage('anatomy:measure', '*')}
      title="Figura isométrica interactiva: la mesa de investigación de Arkangel"
      style={{ height }}
    />
  )
}
