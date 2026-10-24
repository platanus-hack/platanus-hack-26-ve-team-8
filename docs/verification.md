# Verification — 2026-10-24

## Passed

- 38 Python unittest cases: collector parsing/permissions, secret-field exclusion,
  process lifetime identity, model tool loop, timestamp pagination, cloud minimization,
  invented citation rejection, unavailable provider, storage deduplication, bounded API,
  actual temporary Unix socket request/response with synthetic records, API-key
  onboarding validation, and Claude Agent SDK tool callbacks/permission checks.
- Installed `claude-agent-sdk==0.2.174` in the repository's native arm64 `.venv`.
  Its real options constructor and MCP factory pass a compatibility test with the
  client mocked; no model request is sent.
- App-managed service command smoke-tested with temporary storage and monitoring off.
  SDK availability is reported; SIGTERM cleans up the socket.
- Real Anthropic Models endpoint returned the expected rejection for a deliberately
  invalid key, proving TLS connectivity with native macOS trust. No real key used.
- Swift 6 source type checking (no project build).
- A development `.app` was compiled and packaged separately for the user's requested
  runnable update, ad-hoc signed, and reopened. This is not notarized distribution.
- One read-only host snapshot: processes, TCP listeners, and user LaunchAgents
  produced records. Only aggregate counts and coverage were printed; no host snapshot
  was saved or sent to a model.
- Sandboxed `ps` was denied and correctly reported as reduced coverage. A separately
  approved non-sandboxed snapshot returned process metadata. This is CLI evidence,
  not proof of app-context permissions.

## Not yet established

- Actual local-model tool calling and detection quality. All provider tests are mocked.
- Successful real-key onboarding and Keychain round trip, native client-to-service
  runtime interaction, and notarized distribution. UI automation's native pipe failed,
  so the reopened onboarding screen was not visually verified by the agent.
- osquery event integration: executable not installed on the test host.
- Continuous CPU/battery measurements, lifecycle soak testing, attack detection rates.
- Live install/persistence or two-device Wi-Fi demonstrations.

No background service was registered or left running by the tests. The requested SDK
was installed only in the repository environment. No system permissions changed,
remote hosts scanned, or production data accessed. Guardian's UI is left open for setup.
