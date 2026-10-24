# Arkangel

A macOS defensive investigator: local observations, an AI that chooses evidence
queries, and a native interface for reviewing findings. This is an early prototype,
not a validated antivirus or complete endpoint monitor.

## Monorepo

- `apps/macos`: native SwiftUI menu-bar app and Unix socket client.
- `services/agent`: Python local service, SQLite history, collectors, and model-led investigation.
- `packages/contracts`: shared local API contract.
- `docs`: architecture and operational boundaries.

## First-time setup

Python 3.11+ and the official Claude Agent SDK are required for Anthropic investigations.
Install the pinned SDK and local package into a repository-only virtual environment:

```sh
bash scripts/setup-agent.sh
```

If your default Python runs under Rosetta, choose a native Python 3.11+ for the
initial environment: `GUARDIAN_PYTHON=/path/to/native/python3 bash scripts/setup-agent.sh`.
An existing `.venv` is preserved.

Open the native app, enter your Anthropic API key in **Connect your investigator**,
and review the cloud-processing/API-cost checkbox. Connect starts a local service if
needed, verifies key access to Haiku 5.5, and saves the key in **macOS Keychain**.
Verification is a model-metadata request, not paid inference. It does not prove that
the account has enough credits for an investigation. Rejected keys and connection
failures leave setup open with a retryable message.

No API key is stored in UserDefaults, SQLite, source code, or process arguments.
Keys passed to the service remain in its process environment for SDK authentication.
Use **Provider setup…** in the menu to replace the key. The current developer app
requires this checkout and its `.venv`; it is not a standalone distributable package.

## Run the local service manually

From the repository root, as an alternative to the app-managed service:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m guardian serve --watch
```

This runs in the foreground until Ctrl-C. It does not install a launch agent or
change system permissions. The app connects to `/tmp/guardian-<uid>/agent.sock`.
SQLite history is stored under `~/Library/Application Support/Guardian` with
seven-day retention. Override storage using `--data-dir /path/to/private-directory`.
Stopping monitoring pauses snapshots; stopping the foreground process ends the service.

To take one read-only local snapshot:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m guardian scan
```

## Connect a model

Anthropic is the default provider, using **Claude Haiku 5.5** (`claude-haiku-5-5`).
Set `ANTHROPIC_API_KEY` privately in the service's environment (not in chat or source
code). Then start the service from that same terminal:

```sh
export GUARDIAN_PROVIDER=anthropic
export GUARDIAN_ALLOW_CLOUD=1
PYTHONPATH=services/agent/src .venv/bin/python -m guardian serve --watch --auto-investigate
```

`GUARDIAN_ALLOW_CLOUD=1` permits paid requests to Anthropic containing minimized
metadata: opaque identifiers, observation categories, timestamps, and numeric process
relationships. Raw private paths, code, secrets, and the free-text question are withheld.
The API key is used only in the authentication header, not stored in SQLite or sent
in model prompts. Override the model with `GUARDIAN_MODEL` if needed.

The service uses the **Claude Agent SDK**, including its bundled Claude runtime.
The SDK owns the Anthropic agent loop; Guardian supplies read-only evidence tools,
privacy filtering, and citation validation. Built-in shell/file tools and project
settings are disabled. Investigations use isolated temporary runtime configuration
and disable session persistence. No existing Claude subscription login is used.
Its status displays the provider/model and whether cloud access is disabled. Restart
the service after changing its environment when using this manual configuration.

### Local model alternative

Use an already-running local OpenAI-compatible model endpoint that supports tool
calling. Guardian does not install a model runner or choose/download a model.

```sh
export GUARDIAN_PROVIDER=openai
export GUARDIAN_MODEL_ENDPOINT=http://127.0.0.1:1234/v1/chat/completions
export GUARDIAN_MODEL=your-local-model-id
PYTHONPATH=services/agent/src .venv/bin/python -m guardian serve --watch --auto-investigate
```

The URL must include `/v1/chat/completions`. Optional `GUARDIAN_MODEL_KEY` is read
from the environment; never put a real key in the repository. Automatic investigation
reviews changed evidence at most once per minute, and performs an exploratory review
at least every fifteen minutes while monitoring is enabled. Model calls do not block
the snapshot collector. Manual investigation is available in the app or CLI:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m guardian investigate --question 'What deserves investigation?'
```

Without a configured API key or local model, investigations report inconclusive/unavailable. There is
no simulated AI fallback. Remote HTTPS endpoints require `GUARDIAN_ALLOW_CLOUD=1`;
their evidence is aggressively minimized, reducing investigative usefulness.
No hosted model calls are made by tests.

## Native app

See [macOS instructions](apps/macos/README.md). The app never installs dependencies
or registers login items. Connect may launch an app-owned foreground service, which
stops when the app quits. An externally launched service is not stopped by the app.

## Verification

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m unittest discover -s services/agent/tests -v
```

Tests use synthetic records and mocked model/OS responses, plus a temporary Unix
socket. Do not run project builds as verification. Use Swift type checking as
documented in the macOS app instructions.

## Current limits

- Snapshot process and TCP listener observation, plus metadata from user LaunchAgents.
- No outbound connection history, filesystem access tracing, remote scans, full-disk
  inspection, or guaranteed short-lived process capture.
- osquery availability is detected only; its integration and Endpoint Security
  permission evaluation remain future work.
- Stored observations describe things seen or changed, not a complete execution log.
  Absence from a later snapshot does not prove termination or cleanup.
- Model output is evidence-linked but still fallible. No claimed protection against
  unknown attacks or AI-driven attackers.
- Actions are proposals only. No stop-process, delete-file, firewall, or persistence
  modification capability is exposed.

No HolmesGPT/Vigil code is vendored. Anthropic investigations use the official
Claude Agent SDK; local OpenAI-compatible models retain the small custom loop.
