# Architecture and boundaries

SwiftUI client -> private Unix socket -> Python service -> SQLite evidence.
The investigator queries a bounded recorded evidence window through read-only tools.
It cannot call subprocesses, read arbitrary files, or execute proposed remediation.

Collectors always run locally. Process collection excludes argv and environment;
startup inspection extracts selected metadata, not script bodies. These records can
still contain personal names and software details and are stored locally.

The Anthropic investigator uses the official Claude Agent SDK and is model-led:
it chooses searches and entity inspections, considers
benign explanations, and produces hypotheses with evidence references. A fixed
tool executor checks those references and enforces call/time/response limits.
Observed text is untrusted data, never permission to execute or expand access.

Model inference is separate from service location. Loopback inference receives local
metadata. Cloud inference requires explicit opt-in and strips private detail. Neither
configuration is enabled by repository creation. No model inference is performed in
tests; mocked tool-call sequences establish protocol behavior, not detection quality.

## Next evidence gate

1. Run the app and collector under an ordinary user account; inspect coverage.
2. Configure a chosen local model and test actual tool calling on synthetic records.
3. Evaluate a held-out benign installation sequence alongside normal activity.
4. Only after that, decide on osquery event collection, broader permissions, and
   specifically approved remediation capabilities.

No fixture installs persistence or starts a background worker in this repository.
Such a live demonstration remains a separate, explicit action.
