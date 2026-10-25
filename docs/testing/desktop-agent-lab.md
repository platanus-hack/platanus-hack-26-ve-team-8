# Frame detection and repair lab

This is a cooperative, local demonstration. Guardian independently checks a generated
config on disk; Frame reports its dummy-file reads and upload attempts over Guardian's
existing Unix socket. Those reports are labeled as declarations, not OS audit events.
This does not detect or contain an unmodified app that bypasses the integration.

## Run from source

Use the repository's existing `.venv`, macOS 15+, Swift 6, and Node 22+. The headless
Frame lab and collector use only Node's built-in modules; Electron is needed only for
Frame's window. No Claude key, paid inference, or Screen Recording permission is needed.

Quit old instances of Arkangel and restart any separately launched Guardian service so
the new Python module is loaded. A previously packaged app contains its own older code.
From the repository root, launch the development app:

```sh
cd apps/macos
swift run Guardian
```

`swift run` compiles and launches the app. A packaged `.app` or DMG is unnecessary for
this lab. The existing development `.venv` must be prepared separately as documented
in the root README; launching does not install dependencies.

In Arkangel, choose **Vigilar localmente sin conectar Claude**. Open **Actividad →
Alertas → Laboratorio local con Frame**, click **Preparar laboratorio nuevo**, and
confirm. Guardian creates a new session directory under its data directory with just:

- `.env`: the fixed dummy marker `GUARDIAN_DEMO_TOKEN=NO_ES_UN_SECRETO`.
- `config.json`: `{"allow_uploads": false, "redact_secrets": true}`.

From the repository root, start the receiver in a second terminal:

```sh
npm --prefix desktop-agent run collect
```

It listens only at `127.0.0.1:8787`. Leave `PORT` unset for this lab. View delivered
markers at `http://127.0.0.1:8787/`; reload to see new deliveries. It stores them in
`desktop-agent/collector/loot/`.

In a third terminal, start Frame's headless demo:

```sh
npm --prefix desktop-agent run demo
```

Alternatively, click **Iniciar asistente con Guardian** in Frame's development window.
This is also the default CLI flow. It ignores the saved endpoint, scan root, model,
and API key. The older flow is available explicitly with `--legacy` or the button
**Ejecutar flujo anterior sin integración con Guardian** in Settings; it does not
provide this instrumentation. An old Guardian service produces a restart message
before Frame reads or changes any fixture.

If using `GUARDIAN_SOCKET`, set the same socket path for Arkangel and the Frame demo.

## What to verify

Frame reads only the generated dummy `.env`, verifies its exact content, and weakens
the generated config to `{"allow_uploads": true, "redact_secrets": false}`. It can
only change the original config inode that Guardian identified, not an arbitrary path
from the model or settings. It sends the constant marker to the literal loopback URL
with redirects disabled. It repeats up to 30 times, waiting two seconds between
completed deliveries, to leave time to demonstrate repair.

Guardian checks the config during monitoring scans and before processing each report.
Its status refreshes in the app every five seconds. A manual snapshot also checks it.
No model request is needed. A new banner on **Inicio** links back to the lab.

| Stage | Expected evidence |
| --- | --- |
| Prepared, before Frame starts | Config marked safe for the demo; no deliveries. |
| Frame starts | Config marked vulnerable; new stored alerts appear on Inicio, the orb, and the main unreviewed count. Entries distinguish a local config check from Frame's reported read and upload attempt. |
| Before repair | Receiver displays delivered dummy markers; Frame reports completed uploads. |
| Click **Reparar y detener envíos**, then confirm | Guardian blocks future cooperative attempts first, preserves the old config, writes the fixed safe config, and checks it again. |
| Next Frame attempt | Permission denied, Frame reports stopped uploads, receiver count stops increasing after any already-started request. |
| Verification on disk | `config.json` contains the original safe values; `config.before-repair.json` retains the prior config. |

Expand **Evidencia de la demo** to see the last 12 entries and their observation IDs.
The full metadata history appears in Observaciones until its normal seven-day retention
expires. Each distinct config vulnerability, reported read, upload attempt, and completed
upload adds one unreviewed alert per session. A first complete run adds four alerts;
repeated uploads do not inflate the count. Repair failure can add one more. Existing
alerts are preserved. Repair keeps the evidence; mark demo alerts reviewed to remove
them from the unreviewed count.

Click **Revisar laboratorio** on a demo alert to open its repair controls. Demo alerts
are excluded from the pending AI investigation queue and AI context; they cannot
trigger paid investigation or authorize termination/quarantine of real targets. The
**Por investigar** count therefore does not increase for these local demo alerts.

The receiver count is separate evidence that a delivery happened. A Frame report alone
does not prove delivery. Repair does not undo previous deliveries or cancel a request
that already passed its gate. The lab does not modify the firewall or install persistence.

To demonstrate independent config inspection, pause Frame and change only the two
booleans in that session's config, then take a snapshot in Arkangel. A changed config
is detected even without a Frame report. Inaccessible, malformed, linked, oversized, or
unexpected files deny uploads; they do not become evidence that a repair succeeded.

## Repeat and recovery

Click **Detener laboratorio** or stop the Frame CLI with Ctrl-C. Stop the receiver
with Ctrl-C in its own terminal. Quit Arkangel to stop only the Guardian service it owns.
An externally launched service must be stopped separately. A service restart starts
with the lab disabled. Preparing a new session invalidates old session IDs.

Keep session directories for review. A failed repair keeps uploads blocked and retains
the old config or a `config.secure.json` recovery artifact; a missing config also denies
uploads. Do not overwrite or execute recovery files. Prepare a new lab to repeat the
demo; no automatic restoration or deletion of an old directory occurs.

## Manual validation commands

These are instructions to run, not completed verification. No build, typecheck, lint,
test, model call, or live demo was run while implementing this change. A read-only
request to the live service confirmed that the instance showing 52 alerts predated
the lab API; source edits alone do not reload that process.

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m unittest discover -s services/agent/tests -v
node --test desktop-agent/agent/guardian-demo.test.js
swiftc -typecheck -parse-as-library -swift-version 6 \
  -module-cache-path /tmp/guardian-swift-module-cache apps/macos/Sources/Guardian/*.swift
```

The Python checks use temporary files, mocked investigation results, and a portable
stand-in for exclusive repair moves. Existing response tests cover macOS's exclusive
rename. The Node checks use a temporary fake Unix service and mock HTTP; they check
that changed dummy data, denied/unavailable gates, and replaced configs never lead
to a POST. Passing them does not establish OS-wide detection or enforcement. The
interactive steps above validate the real client/service/receiver path separately.

## Beyond the cooperative lab

Independently attributing sensitive file access and enforcing policy against arbitrary
apps needs additional OS telemetry and enforcement. Apple's
[Endpoint Security](https://developer.apple.com/documentation/EndpointSecurity)
provides system-event monitoring with its endpoint-security entitlement; its
[network content filters](https://developer.apple.com/documentation/networkextension/nefilterprovider)
inspect and decide whether to allow network content. Evaluating those privileged
integrations is a separate implementation, deployment, and consent task. This change
does not install them or represent polling as equivalent coverage.
