# Guardian for macOS

Native SwiftUI dashboard and menu-bar client. Requires macOS 15+, Swift 6,
Python 3.11+, and an Anthropic API key with Claude Haiku 5.5 access.

From the repository root, prepare the agent once:

```sh
bash scripts/setup-agent.sh
```

Launch the developer executable:

```sh
cd apps/macos
swift run Guardian
```

`swift run` compiles as part of launching. Development validation uses type
checking instead of a project build:

```sh
swiftc -typecheck -parse-as-library -swift-version 6 \
  -module-cache-path /tmp/guardian-swift-module-cache Sources/Guardian/*.swift
```

If the environment blocks Swift’s nested compiler-plugin sandbox, add
`-disable-sandbox` to type checking. It does not change application permissions.

To wrap the bundle from `scripts/package-macos.sh` in a drag-to-Applications
installer (requires `create-dmg`; writes `.guardian/Arkangel.dmg`, never overwrites):

```sh
bash scripts/build-dmg.sh [path/to/Arkangel.app] [path/to/output.dmg]
```

## First connection

Enter the key in the secure field and explicitly consent to minimized telemetry
metadata reaching Anthropic and paid model inference. Connect validates model
access using a non-inference provider request. Only after validation succeeds does
the app save the key in macOS Keychain. It never puts the key in UserDefaults,
process arguments, logs, or a child environment. Saved keys are never displayed.
Consent is stored separately as a nonsecret preference. Provider setup in the menu
reopens this form to change the key; a blank field can reuse the saved key.

If no agent is reachable, Connect starts the repository `.venv/bin/python -m guardian
serve --watch` as a foreground child process, with the source directory in
`PYTHONPATH`. It sends the key via the Unix socket after the agent becomes ready.
The app never installs dependencies. Missing setup produces an actionable error.
Monitoring collects local evidence; investigations run only when explicitly
requested, with no automatic model investigations on startup.

On first opening, prior consent and a saved Keychain key trigger one automatic
reconnection attempt, starting an owned foreground agent if necessary. Failure
returns to onboarding. Setup editing pauses refresh and automatic restoration.

A restarted agent is reconfigured from Keychain only when it reports onboarding
required and prior consent exists. Normal refreshes do not revalidate credentials.
Quitting stops an agent this app started. An independently started agent stays
running. Merely closing the dashboard leaves the menu-bar app and its owned agent
running. No login item or persistent service is registered.

## Local transport and evidence

Default socket: `/tmp/guardian-<uid>/agent.sock`. Override with `GUARDIAN_SOCKET`.
`GUARDIAN_REPO_ROOT` overrides the developer source checkout location; set it if
the executable has moved or its original checkout no longer exists.

Protocol v1 uses one NDJSON request per connection, matching response IDs,
off-main-thread IO, and an 8 MB response limit. Deadlines are 10 seconds normally,
30 seconds for provider configuration, and 120 seconds for investigations.
Active dashboard scenes refresh every 15 seconds. Closing or deactivating the
dashboard stops automatic refresh; explicit menu refresh remains available.

The timeline requests up to 500 observations and exposes plain-text attributes,
including nested JSON, under Recorded metadata. Findings show hypotheses,
counterevidence, referenced observation IDs, tool steps, limitations, and proposed
actions labeled Not applied. Recorded content is never executed as instructions.
Disconnected state is explicit; previously loaded evidence may remain visible.
Missing coverage or no finding never implies this Mac is safe.

## Operational limits

Developer executable only: app bundle packaging, signing, notarization,
distribution, and launch-at-login are pending. Keychain can require macOS user
approval for the unsigned developer executable. The app suppresses child stdout
and stderr; use the documented foreground CLI separately for detailed service
diagnostics. UI launch, real-key validation, Keychain interaction, and paid model
inference require an interactive end-to-end check and were not run during source
verification. No remediation is executed.
