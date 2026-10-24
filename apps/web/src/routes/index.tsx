import { useEffect, useRef, useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'

const REPO = 'https://github.com/chrisdadev13/arkangel'
const DOWNLOAD = `${REPO}/releases/latest`

export const Route = createFileRoute('/')({ component: Home })

const steps = [
  {
    title: 'Observe locally',
    body: 'A local service snapshots processes, TCP listeners and user LaunchAgents into a private SQLite history with seven-day retention.',
  },
  {
    title: 'Investigate with Claude',
    body: 'An agent built on the Claude Agent SDK chooses its own read-only evidence queries, weighs benign explanations, and forms hypotheses.',
  },
  {
    title: 'Review the evidence',
    body: 'Every finding cites the observations it relies on, lists counterevidence and limitations, and proposes actions that are never applied for you.',
  },
]

const features = [
  {
    title: 'Native macOS app',
    body: 'SwiftUI dashboard and menu-bar client talking to the agent over a private Unix socket.',
  },
  {
    title: 'Privacy by default',
    body: 'Cloud inference is opt-in. Paths, code, secrets and free text are stripped; only minimized metadata leaves the Mac.',
  },
  {
    title: 'No shell, no surprises',
    body: 'The model gets bounded read-only tools. No subprocesses, no arbitrary file reads, no automatic remediation.',
  },
  {
    title: 'Keys in Keychain',
    body: 'Your Anthropic key is verified, then stored in macOS Keychain. Never in logs, settings, or prompts.',
  },
  {
    title: 'Untrusted telemetry',
    body: 'Observed content is treated as evidence, never as instructions — built to resist prompt injection.',
  },
  {
    title: 'Local model option',
    body: 'Prefer to stay offline? Point it at any OpenAI-compatible local endpoint with tool calling.',
  },
]

function Home() {
  return (
    <main>
      <header className="hero">
        <img src="/icon.png" alt="" width={96} height={96} />
        <h1>Arkangel</h1>
        <p className="lead">
          An AI investigator for your Mac. It watches what runs locally, asks Claude to reason over the evidence,
          and tells you what deserves a closer look — and why.
        </p>
        <div className="cta">
          <a className="button primary" href={DOWNLOAD}>
            Download for macOS
          </a>
          <a className="button" href={REPO}>
            View on GitHub
          </a>
        </div>
        <p className="note">macOS 15+ · Developer preview</p>
      </header>

      <section>
        <h2>Anatomy of an investigation</h2>
        <Figure />
      </section>

      <section>
        <h2>How it works</h2>
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
        <h2>Built defensive-first</h2>
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
        <h2>For the judges</h2>
        <p>Run it from source in three steps:</p>
        <pre>
          <code>{`git clone ${REPO} && cd arkangel
bash scripts/setup-agent.sh
cd apps/macos && swift run Guardian`}</code>
        </pre>
        <p>
          Then paste an Anthropic API key in <strong>Connect your investigator</strong> and ask “What deserves
          investigation?”. This is an early prototype, not a validated antivirus: no finding never means your Mac is
          safe.
        </p>
      </section>

      <footer>
        <a href={REPO}>GitHub</a> · Built for the hackathon with Claude
      </footer>
    </main>
  )
}

// The same figure the macOS app embeds, built by packages/figure/build.mjs. It reports its height.
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
    // The figure may report before this listener exists; ask again.
    ref.current?.contentWindow?.postMessage('anatomy:measure', '*')
    return () => window.removeEventListener('message', onMessage)
  }, [])
  return (
    <iframe
      ref={ref}
      className="figure"
      src="/anatomy.html#web"
      onLoad={(event) => event.currentTarget.contentWindow?.postMessage('anatomy:measure', '*')}
      title="Interactive isometric figure: Arkangel's investigation bench"
      style={{ height }}
    />
  )
}
