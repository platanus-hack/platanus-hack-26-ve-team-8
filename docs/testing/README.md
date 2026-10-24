# Testing Arkangel

Arkangel is currently a **read-only defensive investigator**. It observes local
processes, TCP listeners, and user LaunchAgent metadata, then lets a model investigate
recorded evidence. It cannot block connections, kill processes, quarantine files,
or stop data theft. Proposed actions are not applied. If the acceptance requirement
is “stop my colleague's agents from stealing data,” this version does not meet it.

Use this guide to measure what works and expose missing protection. A quiet dashboard
or `no_finding` result never establishes that the machine is safe. Existing historical
verification is in [verification.md](../verification.md); it is not a result for your run.

## 1. Run the offline checks manually

Prerequisites: macOS 15+, Swift 6, Python 3.11+, and the repository `.venv` prepared
using the [setup instructions](../../README.md#first-time-setup). Setup installs
dependencies; run it separately when intended. From the repository root:

```sh
PYTHONPATH=services/agent/src .venv/bin/python -m unittest discover -s services/agent/tests -v

swiftc -typecheck -parse-as-library -swift-version 6 \
  -module-cache-path /tmp/guardian-swift-module-cache apps/macos/Sources/Guardian/*.swift
```

These check collector parsing, storage, the socket contract, provider failure and
privacy handling, citation validation, restricted model tools, and client compilation
semantics. Model responses are mocked; passing does not establish attack detection
or prevention. No project build is required. See the [macOS README](../../apps/macos/README.md)
for environment-specific type-checking guidance and launching the developer app.

## 2. Establish a local baseline

Use a disposable macOS test account or machine with no real credentials or private
documents. Arkangel observes the host, not just the demonstration port. Keep any
attacker agents confined to the agreed test environment and use dummy data only.

Open Arkangel and complete provider setup if you want AI investigations. Anthropic
requires explicit cloud/cost consent; its minimized evidence omits executable names,
listener addresses/ports, and your free-text question, limiting port-specific analysis.
An already-running local model is an alternative described in the root README.
Neither model mode adds enforcement capabilities.

With monitoring enabled, record the provider, coverage, last scan time, and existing
listeners in the timeline. Coverage can legitimately be partial. Investigate the
baseline and save the result locally for comparison. App-started monitoring does
**not** automatically investigate: request an investigation after each scenario.
The separately configured CLI `--auto-investigate` mode checks changed evidence at
most once per minute and performs periodic reviews; it is not an instant response.

For a collector-only check without opening the app or calling a model, use a separate
temporary database (this does not update an already-running app's database):

```sh
ARKANGEL_TEST_DATA=$(mktemp -d /tmp/arkangel-test.XXXXXX)
PYTHONPATH=services/agent/src .venv/bin/python -m guardian scan --data-dir "$ARKANGEL_TEST_DATA"
```

The scan prints status/coverage and stores observations locally. Repeat it with the
same directory while the listener below runs, then inspect just the listener records:

```sh
sqlite3 "$ARKANGEL_TEST_DATA/guardian.sqlite3" \
  "SELECT payload FROM observations WHERE json_extract(payload, '$.kind') = 'tcp_listener';"
```

Do not use CLI `status` to check a live service: CLI commands create a separate service
object rather than querying its socket. Use the app for live monitoring state.

## 3. Repeatable fake-data exercise on this Mac

In a second terminal, from the repository root, start a temporary server serving
only a newly created directory. Do not serve the repository or your home directory:

```sh
ARKANGEL_DEMO_DIR=$(mktemp -d /tmp/arkangel-demo.XXXXXX)
printf '%s\n' 'ARKANGEL-DEMO-ONLY-NOT-A-SECRET' > "$ARKANGEL_DEMO_DIR/canary.txt"
.venv/bin/python -m http.server 8765 --bind 127.0.0.1 --directory "$ARKANGEL_DEMO_DIR"
```

If port 8765 is occupied, choose an unused test port and update the commands. Leave
the server running until a completed scan observes it. Monitoring waits five seconds
between collection cycles; collection itself takes additional time. The active UI
refreshes every 15 seconds, so use its explicit refresh and check timestamps.

In another terminal, retrieve the intentionally public dummy file:

```sh
curl --fail --max-time 5 http://127.0.0.1:8765/canary.txt
```

Expected results:

| Check | Expected in this version |
| --- | --- |
| Listener collection | A `tcp_listener` observation with the server PID and local address ending in `:8765`; inspect recorded metadata. |
| File retrieval | The fake marker is returned, and the server logs a successful GET. This demonstrates that Arkangel does not prevent retrieval. |
| Request visibility | No expectation of an HTTP-request, file-read, or exfiltration event: those are not collected. |
| AI investigation | Review citations, competing explanations, and limitations. A Python listener alone is not proof of an attack. |
| Remediation | Any suggested action remains a proposal, labeled **Not applied** in the app. |

If the listener is missing, check coverage, the server's continued operation, and
scan time before judging the model. Investigations and the timeline each expose at
most 500 observations; a busy host can push relevant evidence outside that window.

Stop the server with Ctrl-C in its own terminal. Repeat the curl command and confirm
the server is no longer reachable. This is **manual containment**, not an Arkangel
block. Historical observations remain; their presence does not prove a listener is
still active, and disappearance does not prove cleanup.

## 4. Exercise with your colleague's agents

Agree beforehand on the exact test machine, permitted ports, dummy files/accounts,
start/end time, request-rate limit, and an immediate stop signal. Keep a human ready
to stop the test server and attacker agents. Agents must not target production,
real credentials, other machines, or unapproved ports. Do not treat Arkangel as
the isolation boundary for the exercise.

The loopback example above is reachable only on the same Mac. For a colleague on
another machine, use a separately agreed isolated lab network and bind the demo
server to that Mac's specific lab IP instead of `127.0.0.1`. Have the colleague use
that same IP in the URL. Do not expose it through a public address, router port
forward, or a wildcard binding on your everyday network.

Run one scenario at a time, including a benign control:

| Scenario | Evidence to collect | How to judge it |
| --- | --- | --- |
| Normal authorized request | Server access log and listener observation | Do not label all network activity malicious. |
| Agent attempts to retrieve the dummy canary from an agreed port | Attacker transcript, server log, returned marker, timestamps | A returned marker means retrieval succeeded, even if Arkangel produces a finding. |
| A new long-lived test listener appears | Port/PID, observation ID, investigation and timestamps | Separate successful collection from whether the model identified a concern. |
| Brief activity between snapshots | Independently recorded start/end times | A miss demonstrates a coverage gap; it is not evidence that nothing happened. |
| Provider unavailable during a requested investigation | UI/result and later scan timestamps | Report unavailable/inconclusive honestly; collection should continue. |

Use only agreed dummy-data access scenarios; this guide does not require real
malware, persistence installation, permission changes, or uncontrolled exploitation.
The collector does not record inbound request bodies, outbound connection history,
or file accesses. An attacker can retrieve data through an existing listener without
creating a new observation. Remote attacker processes do not appear in local process
snapshots. These are expected blind spots, not proof of a successful defense.

For each attempt, record: scenario, UTC start/end, target port/PID, expected outcome,
server/attacker ground truth, observation IDs, investigation result, time to first
observation/finding, whether the dummy data was retrieved, and who stopped the action.
Keep logs local and redact host metadata before sharing. Repeat benign and adversarial
runs; report misses and false alarms as well as successes.

## 5. Acceptance and cleanup

- **Collection passes** when the deliberately long-lived listener is recorded with
  the correct PID/address and coverage limitations are visible.
- **Investigation quality is measured separately** against the scenario's ground
  truth. Findings must cite inspected evidence, acknowledge missing visibility, and
  avoid claiming an attack or safety without support. Inconclusive is honest but
  does not satisfy a detection requirement.
- **Prevention is not implemented.** A finding, proposal, failed attacker attempt,
  or human stopping the server is not proof Arkangel blocked anything. Future
  prevention acceptance needs an implemented enforcement path and independent
  evidence that it blocks dummy-data access while legitimate traffic still works.
- **Recovery passes** when you stop the demo server and attacker agents, verify the
  test listener is closed, and check your legitimate services still behave normally.
  Quit Arkangel to stop its app-owned service; stop a manually launched foreground
  service separately with Ctrl-C. Closing the dashboard alone does not quit the app.

Remove only the temporary directories you created after retaining the results you
need. Test databases contain host metadata. Do not remove your normal Guardian
database or another running service's socket as part of cleanup.

This procedure documents a test plan, not completed validation or a protection guarantee.
