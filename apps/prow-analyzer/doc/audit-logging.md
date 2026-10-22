# Prow Analyzer -- Audit Logging

How the agent records the **complete lifecycle of an interaction**, and how those
records reach a **centralized, immutable** store.

## What is captured

Every interaction emits three correlated audit events (linked by
`interaction_id`), covering exactly the required lifecycle:

| Requirement                                              | Event                        | Emitted from                                        | Key fields                                                                                                                                         |
|----------------------------------------------------------|------------------------------|-----------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| **Interaction trace** — the user prompt / system trigger | `interaction_received`       | `handler.Handle` (Slack), `cli/main` (CLI)          | `interaction_id`, `source` (`slack`/`cli`), `actor_sha256` (pseudonymized Slack user ID / OS user), `channel`, `trigger` (the Prow URL)            |
| **Tools / data sources queried**                         | `tool_query` (one per query) | `analyzer.initializeSession`, `analyzer.doAnalysis` | `interaction_id`, `target` (`ship-help-mcp`), `operation` (`initialize` / `tools/call`), `tool` (`ask_persona`), `persona` (e.g. `<persona>`)      |
| **AI action / outcome**                                  | `interaction_outcome`        | `handler.analyzeAndRespond`, `cli/main`             | `interaction_id`, `status` (`success`/`failed`/`delivery_failed`/`rejected`), `duration_ms`, `response_chars`, `response_sha256`, `error`/`reason` |

All events are single-line JSON tagged `"log_type":"audit"`,
`"component":"prow-analyzer"`.

### Example trace (one interaction)

```json
{"time":"…","msg":"interaction_received","log_type":"audit","event":"interaction_received","interaction_id":"C123/1712.45","source":"slack","actor_sha256":"3b8c1a…","channel":"C123","trigger":"https://prow.ci.openshift.org/view/gs/…"}
{"time":"…","msg":"tool_query","log_type":"audit","event":"tool_query","interaction_id":"C123/1712.45","target":"ship-help-mcp","operation":"initialize","persona":"<persona>"}
{"time":"…","msg":"tool_query","log_type":"audit","event":"tool_query","interaction_id":"C123/1712.45","target":"ship-help-mcp","operation":"tools/call","tool":"ask_persona","persona":"<persona>"}
{"time":"…","msg":"interaction_outcome","log_type":"audit","event":"interaction_outcome","interaction_id":"C123/1712.45","status":"success","duration_ms":142331,"response_chars":2210,"response_sha256":"9f2c…"}
```

Correlate a full interaction with:
```bash
oc logs -n <ns> -l app=prow-analyzer-bot | grep '"log_type":"audit"' | grep '"interaction_id":"C123/1712.45"'
```

## Design notes

- **Correlation:** `interaction_id` = Slack `channel/message-ts` (bot) or
  `cli:<url>` (CLI). All three phases share it.
- **Privacy / minimization:** the audit trail records response **metadata**
  (`response_chars`, `response_sha256`) — **not** the response text — so it can
  prove *what happened* without persisting potentially sensitive content. The
  `trigger` field stores the Prow URL only. The requester identity is
  **pseudonymized**: `actor_sha256` is a SHA-256 of the Slack user ID / OS user,
  which preserves per-actor correlation and forward-verification (hash a suspected
  actor and search) without persisting the raw identity. (Aligns with the "no
  personal/customer data" policy.)
- **Error redaction (audit + operational):** failure errors are payload-free at
  the **source** — `pkg/analyzer` elides HTTP response bodies and MCP error
  messages to metadata (status code, JSON-RPC error code, byte count) rather than
  embedding backend content. So the errors that reach the **operational** logs are
  already payload-free; the one preserved token is the fixed `Session not found`
  marker the session-recovery retry matches on (re-emitted from a constant, never
  raw body text). On top of that, the **audit** `error` field records only a
  **coarse category** (e.g. `mcp_http_error`, `timeout`, `session_not_found`) via
  `audit.RedactError`, so the immutable trail carries just the category.
- **Coverage:** success, backend failure, Slack delivery failure, and queue-full
  rejection are all recorded as outcomes.
- **Implementation:** `pkg/audit` (dedicated JSON `slog` logger to stdout).

## Centralization & immutability

> **Important separation of responsibility.** The **application** produces a
> complete, structured audit trail to **stdout**. Making that trail **centralized
> and immutable** is a **platform** responsibility — it requires cluster log
> forwarding to a write-once/retention-controlled store. The app cannot guarantee
> immutability on its own (pod stdout is ephemeral and lost on restart).

Recommended pipeline on OpenShift:

1. **OpenShift Logging / Vector** collects pod stdout.
2. **`ClusterLogForwarder`** ships audit records to a central store with
   immutability + retention (e.g. Loki with retention locks, Elasticsearch/S3
   with object-lock/WORM, or a SIEM such as Splunk).

Example `ClusterLogForwarder` (illustrative — adjust output to your platform):

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: prow-analyzer-audit
  namespace: openshift-logging
spec:
  pipelines:
    - name: prow-analyzer-audit
      inputRefs: [application]
      filterRefs: [only-audit]
      outputRefs: [central-immutable-store]
  filters:
    - name: only-audit
      type: drop            # keep only audit events
      drop:
        - test:
            - field: .structured.log_type
              notMatches: "audit"
  outputs:
    - name: central-immutable-store
      type: loki            # or elasticsearch / splunk / cloudwatch
      loki:
        url: https://<central-loki-endpoint>
      # Immutability/retention (WORM, object-lock, retention lock) is configured
      # on the destination store, not here.
```

## Production status (honest confirmation)

- ✅ **Application-level audit trail:** implemented in code (`pkg/audit`, wired
  into the Slack handler, analyzer, and CLI) and unit-tested. It is **active as
  soon as the updated image is deployed**.
- ⚠️ The live deployment https://images.paas.redhat.com/organization/ieng/app/prow-analyzer
- ❓ **Centralized immutable storage:** **not verified.** Whether a
  `ClusterLogForwarder` to an immutable store exists for this cluster must be
  confirmed with the cluster/logging owners. Until then, audit events live only
  in ephemeral pod stdout and are **not** immutable.

To fully satisfy "centralized immutable logging," both the deploy (activate the
app trail) **and** the log-forwarding pipeline (centralize + lock it) must be in
place. This document provides the former; the latter is a platform action to
verify/configure.
