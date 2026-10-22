# Prow Analyzer -- Capabilities & Inventory

> Authoritative inventory of everything the Prow Analyzer agent can access or do.
> Derived from the source code, the Slack app manifest
> (`deploy/slack/manifest.yaml`), and the deployment configuration. This document
> backs the "Capabilities and Inventory" section of the
> [User Guide](user-guide.md).

## Data-access classification: **Read-only (with one write)**

Prow Analyzer is **read-only** with respect to every external system **except one
action**: it posts messages to Slack (`chat:write`). It performs **no** writes to
Jira, GitHub, CI/Prow, or any other system. It does not run code, browse the web,
or execute arbitrary tools. Its only analytical capability is delegating a single
prompt to the ship-help MCP; all richer reasoning and data access happen **inside
ship-help**, not in this agent.

| Action class                        | Detail                                                                                                                                |
|-------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| **Writes (the only side effect)**   | Posts an in-thread message to a Slack channel it is a member of.                                                                      |
| **Reads (direct)**                  | Slack channel message text (to detect Prow URLs).                                                                                     |
| **Reads (indirect, via ship-help)** | Jira, GitHub, build logs, test results, an internal triage system, Slack discussions, internal docs, historical patterns (see below). |
| **Not permitted**                   | Any write to Jira/GitHub/CI; code execution; web browsing; tools other than the single MCP `ask_persona` call.                        |

---

## 1. Tools

The agent calls exactly **one external tool**. It has no plug-in tool registry.

| Tool          | Provider      | Transport                    | Purpose                                                                                                                         |
|---------------|---------------|------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `ask_persona` | ship-help MCP | JSON-RPC 2.0 over HTTP + SSE | Submits a prompt containing the Prow URL and returns the AI-generated analysis. This is the agent's sole analytical capability. |

---

## 2. Skills

The agent has **no autonomous "skills"** in the LLM/agentic sense (no tool-choosing
loop, no planning, no self-directed multi-step reasoning). It is a deterministic
Go program: detect a Prow URL → send one MCP request → format and post the reply.
All model-driven behavior lives in the ship-help persona, not here.

---

## 3. APIs

| API                                                | Direction                | Auth                                                                        | Operations used                                                    | Notes                                                                                                                                                                                                                                                                                                                         |
|----------------------------------------------------|--------------------------|-----------------------------------------------------------------------------|--------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **ship-help MCP** (`PROW_AN__MCP__URL__SHIP_HELP`) | Outbound                 | `Authorization: Bearer <PROW_AN__MCP__TOKEN__SHIP_HELP>` + `Mcp-Session-Id` | `initialize` (protocol `2024-11-05`), `tools/call` → `ask_persona` | JSON-RPC 2.0; response is an SSE stream. Auto-recovers a stale session and retries once. 1,200s (20-min) default client timeout, overridable via the bot's `--mcp-timeout` / `PROW_AN__MCP__TIMEOUT_SEC` or the CLI's unprefixed `MCP_TIMEOUT_SECONDS`. (CLI reads the unprefixed `SHIP_HELP_MCP_URL`/`SHIP_HELP_MCP_TOKEN`.) |
| **Slack Web API**                                  | Outbound                 | `PROW_AN__SLACK__BOT_TOKEN` (`xoxb-…`)                                      | `chat.postMessage` (via `chat:write`)                              | Posts analysis, error, and "queue full" replies in-thread.                                                                                                                                                                                                                                                                    |
| **Slack Socket Mode**                              | Outbound WebSocket (WSS) | `PROW_AN__SLACK__APP_TOKEN` (`xapp-…`)                                      | Receives Events API callbacks; `Ack()`                             | No public ingress; outbound-only.                                                                                                                                                                                                                                                                                             |

**Slack OAuth bot scopes** (from `deploy/slack/manifest.yaml`):

| Scope              | Why                                                                          |
|--------------------|------------------------------------------------------------------------------|
| `channels:history` | Read messages in public channels the bot is a member of (to find Prow URLs). |
| `chat:write`       | Post replies.                                                                |

**Slack event subscriptions:** `message.channels` only. Interactivity is
disabled; token rotation disabled; org deploy disabled.

> **Discrepancy to note:** `README.md` mentions an `app_mentions:read` scope, but
> the committed manifest grants only `channels:history` and `chat:write`. The
> manifest is authoritative for what the bot actually requests.

---

## 4. Functions (public code surface)

The exported functions/constants that define the agent's behavior:

**`pkg/analyzer`**

| Symbol                                       | Kind   | Role                                                                               |
|----------------------------------------------|--------|------------------------------------------------------------------------------------|
| `NewAnalyzer(mcpURL, token, promptTemplate)` | func   | Constructs the MCP client.                                                         |
| `Analyzer.AnalyzeFailure(ctx, jobURL)`       | method | Full analysis: session init, `ask_persona`, SSE parse, one retry on stale session. |
| `ExtractProwURL(text)`                       | func   | Extracts the first recognized Prow URL from text.                                  |
| `ContainsProwURL(text)`                      | func   | Boolean check for a Prow URL.                                                      |
| `FormatSlackResponse(result)`                | func   | Formats the reply with header, AI-generated label, footer.                         |
| `WithDisclaimer(message)`                    | func   | Wraps any message with the disclaimer (top) + review notice (bottom).              |
| `Disclaimer`, `ReviewNotice`, `AILabel`      | const  | Mandatory compliance notices/labels applied to all output.                         |

**`pkg/slack/handler`**

| Symbol                                     | Kind   | Role                                                            |
|--------------------------------------------|--------|-----------------------------------------------------------------|
| `New(client, analyzer, monitoredChannels)` | func   | Builds the event handler; sets channel allowlist / monitor-all. |
| `handler.Handle(callback, logger)`         | method | Filter chain + semaphore-gated async dispatch.                  |
| `handler.Identifier()`                     | method | Returns `"prow-analyzer"`.                                      |

**Internal-only helpers** (not public API): `ensureSession`, `invalidateSession`,
`doAnalysis`, `initializeSession`, `readSSEData`, `isSessionNotFound`,
`attachSessionInit`, `logTimings`, `analyzeAndRespond`.

---

## 5. Data Sources (authorized to view)

### Direct (the agent reads these itself)

| Source                 | Access                      | Scope                                                                                                                                                                                                                                                                                                                                                   |
|------------------------|-----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Slack channel messages | `channels:history`          | Only public channels the bot has been **invited to**. Reads message text to detect Prow URLs.                                                                                                                                                                                                                                                           |
| Prow job URL           | From message text / CLI arg | The URL string is passed to ship-help.                                                                                                                                                                                                                                                                                                                  |
| Runtime configuration  | Env vars / CLI flags        | Bot (`PROW_AN__`-prefixed): `PROW_AN__MCP__URL__SHIP_HELP`, `PROW_AN__MCP__TOKEN__SHIP_HELP`, `PROW_AN__SLACK__BOT_TOKEN`, `PROW_AN__SLACK__APP_TOKEN`, `PROW_AN__MONITORED_CHANNELS`, `PROW_AN__PROMPT__TEMPLATE`. CLI: `SHIP_HELP_MCP_URL`, `SHIP_HELP_MCP_TOKEN` (or `-mcp-url`/`-token`), `-prompt`. Both (unprefixed): `TLS_INSECURE_SKIP_VERIFY`. |

### Indirect (viewed by ship-help on the agent's behalf)

The agent never connects to these directly; it only receives ship-help's
summarized text. Actual access is governed by the ship-help persona and its
service credentials, **not** by the requesting user.

| Data source (via ship-help)               | Used for                   |
|-------------------------------------------|----------------------------|
| Jira issues (active, historical, related) | Root cause, related issues |
| GitHub repositories and PRs               | Code/PR context            |
| Build logs and artifacts                  | Failure detail             |
| Test results and history                  | Failure/flake context      |
| Automated known-issue triage              | Known-issue correlation    |
| Slack team discussions                    | Prior discussion context   |
| Internal documentation                    | Guidance/runbooks          |
| Historical failure patterns               | Recurring-pattern analysis |

---

## 6. Runtime dependencies & network egress

**Libraries** (`go.mod`): `github.com/slack-go/slack v0.14.0`;
`github.com/gorilla/websocket v1.5.0` (indirect); `github.com/stretchr/testify`
(tests). Plus the Go standard library (HTTP, JSON, TLS, regex, concurrency).

**Network egress (outbound only):**
- ship-help MCP endpoint (HTTPS + SSE).
- Slack (WSS for Socket Mode + HTTPS for the Web API).

**No inbound/ingress.** Socket Mode means no public route is exposed.

---

## 7. Authorized vs prohibited actions (summary)

**Autonomous (no human needed):** detect a Prow URL in a monitored channel;
call `ask_persona`; post the analysis/error/queue-full reply in-thread; recover a
stale MCP session and retry once; run up to **5 concurrent** analyses (extras get
a "queue full" reply).

**Requires a human:** any remediation (code, config, Jira, GitHub, retriggering
CI); judging correctness; inviting/removing the bot from channels.

**Prohibited / cannot do:** write to any system other than posting a Slack
message; analyze non-Prow URLs or free-text questions; respond to other bots; act
in channels it hasn't been invited to; browse the web or run arbitrary code.

---

## 8. Access-control note (RBAC)

Access is **not** per-user. The agent uses **shared service credentials** (one
ship-help token, one Slack bot token), so analyses reflect what those service
accounts can see — not the requesting user's permissions. Effective gating is:
**Slack channel membership** (who is in a monitored channel) and **possession of
a valid ship-help token** (for the CLI). See the
[RBAC Enforcement](user-guide.md#rbac-enforcement) section of the User Guide.
