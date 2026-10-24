# Guardian local protocol v1

Transport: newline-delimited JSON over a Unix domain socket. One request and one
response per connection; no TCP port. Default socket: /tmp/guardian-<uid>/agent.sock
(override with GUARDIAN_SOCKET on both sides), directory mode 0700. Request: {"id":"uuid", "method":"status", "params":{}}.
Response: {"id":"uuid", "result": ...} or {"id":"uuid", "error":{"message":"..."}}.

Methods:
- status -> {"monitoring":bool,"provider":str,"coverage":[{"source":str,"status":str,"detail":str}],"observation_count":int,"last_scan":str|null,"onboarding_required":bool,"sdk_available":bool}
- provider.configure -> status (params api_key string, allow_cloud true). User-initiated
  onboarding checks SDK availability then validates key/model via Anthropic Models GET.
  No inference call. Success selects Anthropic / claude-haiku-5-5 for the service
  process only; native client persists the key in Keychain. No key in response/logs/DB.
- observations -> {"items":[Observation]} (params limit default 100 max 500)
- investigations -> {"items":[Investigation]}
- scan -> status (explicit read-only local snapshot)
- investigate -> Investigation (params question optional; uses recorded evidence)
- monitoring.set -> status (params enabled bool; foreground service lifecycle only)

Observation: {"id":str,"timestamp":ISO8601 UTC str,"kind":str,
"source":str,"entity":str,"summary":str,"attributes":object}.
Investigation: {"id":str,"created_at":str,"status":str,"title":str,
"summary":str,"hypotheses":[{"statement":str,"status":str,
"evidence_ids":[str],"counterevidence":str}],"steps":[{"tool":str,
"summary":str}],"proposed_actions":[{"title":str,"description":str}],
"limitations":[str]}.
Status examples: inconclusive, needs_review, no_finding. No confidence number implies safety.
No remediation execution endpoint exists. UI labels actions as proposals, not applied fixes.

Example payloads: fixtures.json. services/agent/tests/test_contract.py checks Python
output against it; keep it in sync with the Swift models in AgentClient.swift.

## Python module interfaces

telemetry.py: collect_snapshot() -> tuple[list[dict], list[dict]] (observations, coverage).
Each observation has all fields above; UUID ids, UTC time. No persistent state in collector.
Only local read-only inspection; fixed commands; no environment/command-line secrets.

investigator.py: investigate(observations: list[dict], question: str = "",
coverage: list[dict] | None = None) -> dict (Investigation).
Provider selection from GUARDIAN_MODEL_ENDPOINT / GUARDIAN_MODEL / GUARDIAN_MODEL_KEY.
GUARDIAN_PROVIDER selects anthropic or openai. Default is anthropic with
claude-haiku-5-5 and ANTHROPIC_API_KEY; an existing GUARDIAN_MODEL_ENDPOINT selects
openai when provider is unset. Missing credentials/configuration means explicit
unavailable/inconclusive (never pretend model inference).
Anthropic uses the official Claude Agent SDK with custom read-only evidence MCP
tools, no built-in tools or project settings, and bounded turns/time. OpenAI-compatible
local providers retain the configured chat-completions endpoint and local tool loop.
Cloud endpoint requires GUARDIAN_ALLOW_CLOUD=1; even then use minimized metadata.
Tool loop operates on supplied recorded observations.
Tests can inject/mock HTTP responses; no real model calls.

