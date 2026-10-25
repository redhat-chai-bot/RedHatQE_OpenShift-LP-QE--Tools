# Prow Analyzer -- Developer & Operator Reference

> **Scope of this document.** This is the combined *developer and operator
> reference*: architecture (system design, components, MCP protocol flow, design
> decisions), plus the configuration reference, usage, build/deploy steps, and
> troubleshooting internals. It is written for developers and operators.
>
> Looking for how to *use* the tool (quick start, limitations, best practices,
> review/undo, data handling, RBAC, contacts)? See the
> **[User Guide](user-guide.md)** instead.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [System Diagram](#system-diagram)
  - [Components](#components)
  - [MCP Protocol Flow](#mcp-protocol-flow)
  - [Design Decisions](#design-decisions)
- [Configuration](#configuration)
  - [Environment Variables](#environment-variables)
  - [CLI Flags](#cli-flags)
  - [Bot Flags](#bot-flags)
  - [Prompt Template](#prompt-template)
  - [Recognized Prow URL Patterns](#recognized-prow-url-patterns)
- [Usage](#usage)
  - [CLI](#cli)
  - [Slack Bot](#slack-bot)
- [Deployment](#deployment)
  - [Prerequisites](#prerequisites)
  - [Slack App Setup](#slack-app-setup)
  - [Option 1: Run Locally](#option-1-run-locally)
  - [Option 2: OpenShift Deployment](#option-2-openshift-deployment)
  - [Updating a Running Deployment](#updating-a-running-deployment)
- [Development](#development)
  - [Project Structure](#project-structure)
  - [Building](#building)
  - [Testing](#testing)
  - [Dependencies](#dependencies)
  - [Container Image](#container-image)
- [Troubleshooting](#troubleshooting)
  - [Diagnosing Failures](#diagnosing-failures)
  - [Error Reference](#error-reference)
  - [Bot Not Responding](#bot-not-responding)
  - [Exec Format Error](#exec-format-error)
  - [Queue Full](#queue-full)

---

## Overview

Prow Analyzer automates the analysis of Prow CI job failures by querying Red Hat's ship-help MCP (AI helpdesk). Ship-help has access to Jira issues, GitHub repositories, build logs, test results, known-issue triage data, Slack discussions, internal documentation, and historical failure patterns.

The project ships two binaries:

- **`prow-analyzer--cli`** -- Analyze a single Prow job URL from the command line.
- **`prow-analyzer--bot`** -- A Slack bot that monitors channels and auto-analyzes Prow URLs posted by users, replying in-thread with root cause analysis, related Jira issues, recurring pattern detection, and recommended actions.

Analysis typically takes 2-4 minutes as ship-help searches across 9+ data sources.

---

## Architecture

### System Diagram

```
                       +----------------------+
                       |   Slack Workspace    |
                       |  (Socket Mode WSS)   |
                       +-----------+----------+
                                   |
                            message events
                                   |
                                   v
+----------------------------------+----------------------------------+
|                                                                     |
|                         prow-analyzer--bot                          |
|                                                                     |
|  cmd/prow-analyzer--bot/main.go                                     |
|  +-- Parses flags / env vars                                        |
|  +-- Creates Slack socket-mode client                               |
|  +-- Routes EventsAPI callbacks to handler                          |
|                                                                     |
|  pkg/slack/handler/                                                 |
|  +-- Filters: callback type, message type, bot msgs, channel ACL    |
|  +-- Extracts Prow URL from message text                            |
|  +-- Semaphore-gated async dispatch (max 5 concurrent)              |
|  +-- Posts analysis result (or error) as thread reply               |
|                                                                     |
|  pkg/analyzer/                                                      |
|  +-- MCP session lifecycle (initialize, cache, invalidate, recover) |
|  +-- JSON-RPC over SSE request/response                             |
|  +-- Prow URL regex extraction                                      |
|  +-- Slack response formatting                                      |
+----------------------------------+----------------------------------+
                                   |
                            JSON-RPC / SSE
                                   |
                                   v
                       +----------------------+
                       |    ship-help MCP     |
                       |    (AI helpdesk)     |
                       +----------------------+
                                   |
               +---------+---------+---------+-----------+
               |         |         |         |           |
             Jira     GitHub     Build    Known-       Slack
            issues      PRs      logs     issues    discussions
```

### Components

**CLI entrypoint** (`cmd/prow-analyzer--cli/main.go`)

Standalone command-line tool for one-off analysis. Parses flags, creates an Analyzer instance, calls `AnalyzeFailure`, and prints the result to stdout. Exits with code 1 on error. Requires exactly two positional arguments: the command `analyze` and a Prow URL.

**Bot entrypoint** (`cmd/prow-analyzer--bot/main.go`)

Long-running Slack bot. Creates a Slack client in Socket Mode (outbound WebSocket), creates an Analyzer and Handler, then enters the event loop. Events are acknowledged immediately via `socketClient.Ack()` and analysis runs asynchronously. Debug logging is enabled for both the Slack client and socket-mode client.

**Analyzer package** (`pkg/analyzer/analyzer.go`)

The core MCP client. Key responsibilities:

- **Session management** -- Initializes an MCP session on first use, caches the session ID, and automatically recovers from stale sessions. The `ensureSession` method acquires `initMtx` and initializes only if `initialized` is false. The `invalidateSession` method resets this flag. Both methods are goroutine-safe.

- **Request/response** -- Builds JSON-RPC 2.0 requests, sends them as HTTP POST with SSE accept header, and reads the response from an SSE stream. The `readSSEData` function scans line by line, skipping empty lines and SSE comment/ping lines (lines starting with `:`), and returns the first `data:` payload.

- **Session recovery** -- `AnalyzeFailure` calls `doAnalysis`. If the error contains "Session not found", it calls `invalidateSession`, re-initializes via `ensureSession`, and retries `doAnalysis` exactly once. This handles the case where the MCP server expires a session after a timeout.

- **URL extraction** -- `ExtractProwURL` uses a compiled regex to match Prow URLs from `prow.ci.openshift.org` and `deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com`. It handles Slack link formatting (`<url|label>`), Markdown links, trailing punctuation, and whitespace-terminated URLs.

- **Response formatting** -- `FormatSlackResponse` wraps the analysis text in Slack mrkdwn with a header and duration footer. Guards against nil results.

- **HTTP client** -- Uses `http.Client` with a 1,200-second (20-minute) default timeout, overridable via `MCP_TIMEOUT_SECONDS` (CLI) or the bot's `--mcp-timeout` flag / `PROW_AN__MCP__TIMEOUT_SEC`. Optionally skips TLS verification when `TLS_INSECURE_SKIP_VERIFY=true`. The client is injected via the `HTTPDoer` interface to enable testing.

- **Dependency injection** -- `jsonMarshal` and `newRequest` functions are injected fields, allowing tests to exercise error paths that are otherwise unreachable (e.g., `json.Marshal` failure, `http.NewRequestWithContext` failure).

**Slack handler package** (`pkg/slack/handler/handler.go`)

Implements the `PartialHandler` interface with `Handle` and `Identifier` methods. The `Handle` method applies a filter chain before dispatching:

1. Event must be `CallbackEvent` type (not URL verification, etc.)
2. Inner event must be `MessageEvent` (not app mention, reaction, etc.)
3. Message must not be from a bot (`event.BotID == ""`) to prevent loops
4. Channel must be in the `monitoredChannels` map
5. Message text must contain a recognized Prow URL

If all filters pass, the handler attempts to acquire a semaphore slot (buffered channel of size 5). If acquired, `analyzeAndRespond` runs in a goroutine. If the semaphore is full, a "queue full" message is posted to the user immediately.

`analyzeAndRespond` releases the semaphore slot on return via `defer`, calls `analyzer.AnalyzeFailure`, and posts the result (or a generic error message) as a thread reply using `slack.MsgOptionTS`.

**Container image** (`image/container/prow-analyzer/`)

Multi-stage Dockerfile:
- Builder: `registry.access.redhat.com/ubi9/go-toolset:1.22` -- vendors dependencies and compiles both binaries.
- Runtime: `registry.access.redhat.com/ubi9/ubi:latest` -- copies binaries to `/usr/bin/`, runs as UID 1000.

Both stages use publicly pullable Red Hat base images (`registry.access.redhat.com`, no auth) because the image is built by GitHub Actions, which has no `registry.ci.openshift.org` credentials.

The Makefile supports `build`, `push`, and `clean` targets with configurable `IMAGE_REGISTRY`, `IMAGE_NAMESPACE`, `IMAGE_REPO`, and `IMAGE_TAG` (the full reference `IMAGE_NAME` is composed from these). The `BUILDFLAGS` variable passes flags to `podman build` (e.g., `--platform linux/amd64`).

**OpenShift deployment** (`deploy/openshift/deployment.yaml`)

Defines three resources in a single file:
- `Namespace` (default: `prow-analyzer`)
- `ConfigMap` (`prow-analyzer-config`) -- MCP URL, monitored channels, prompt template
- `Deployment` (`prow-analyzer-bot`) -- single replica, non-root security context, liveness probe via `pgrep`, resource limits (128-512Mi memory, 100-500m CPU)

The `prow-analyzer-secrets` Secret (ship-help token, Slack bot token, Slack app token) is **not** in this manifest — create it out-of-band (Step 2 below) so `oc apply` never overwrites real tokens with placeholders.

**Slack app manifest** (`deploy/slack/manifest.yaml`)

Defines the Slack app configuration for import at https://api.slack.com/apps. Bot scopes: `channels:history`, `chat:write`. Socket Mode enabled. Subscribes to `message.channels` events.

### MCP Protocol Flow

**Step 1: Initialize session**

```
POST <mcp-url>
Content-Type: application/json
Authorization: Bearer <token>

{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "prow-analyzer", "version": "1.0" }
  }
}

Response: 200 OK
Header: Mcp-Session-Id: <session-id>
Body: {"jsonrpc":"2.0","id":0}
```

**Step 2: Call ask_persona**

```
POST <mcp-url>
Content-Type: application/json
Authorization: Bearer <token>
Mcp-Session-Id: <session-id>
Accept: application/json, text/event-stream

{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "ask_persona",
    "arguments": { "question": "<prompt with job URL>" }
  }
}

Response: 200 OK (text/event-stream)
: ping - 2026-08-10
: ping - 2026-08-10
data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"<analysis>"}]}}
```

**Step 3: Session recovery (automatic)**

If step 2 returns `HTTP 404` with `{"error":{"message":"Session not found"}}`, the analyzer:
1. Invalidates the cached session (`initialized = false`)
2. Re-runs step 1 to get a new session ID
3. Retries step 2 exactly once with the new session

### Design Decisions

**Socket Mode over webhooks.** The bot uses Slack's WebSocket-based Socket Mode instead of HTTP webhooks. This eliminates the need for a public ingress endpoint or route -- the bot runs behind the firewall with outbound-only connections. The tradeoff is a persistent WebSocket connection, but this is well-suited for a single-replica deployment.

**Semaphore-gated concurrency.** A buffered channel of size 5 limits concurrent MCP requests. This prevents overwhelming ship-help when many Prow URLs are posted simultaneously. Excess requests are immediately rejected with a user-visible "queue full" message rather than queued indefinitely, so users know to retry.

**Async analysis.** Each analysis runs in a goroutine spawned by the handler. The Slack event is acknowledged immediately so the 3-second Socket Mode ack deadline is never hit. The goroutine posts the result (or error) as a thread reply when complete.

**Session recovery.** MCP sessions can expire on the server side, particularly after the 1,200-second (20-minute) HTTP client timeout kills a long-running SSE stream. Without recovery, the bot would return "Session not found" errors indefinitely until restarted. The retry-once approach handles this transparently.

**Bot message filtering.** All messages with a non-empty `BotID` are ignored. This prevents infinite loops where the bot's own thread replies (which contain Prow URLs in the analysis) trigger new analyses.

**Single prompt template.** The `{job_url}` placeholder in the configurable prompt template is replaced with the actual URL. This allows operators to tune what ship-help returns without code changes.

---

## Configuration

### Environment Variables

The **bot** reads most of its env vars under the `PROW_AN__` prefix. The **CLI**
is unchanged and keeps the unprefixed names for the variables it shares with the
bot (`SHIP_HELP_MCP_URL`, `SHIP_HELP_MCP_TOKEN`, `MCP_DEBUG`, `MCP_TIMEOUT_SECONDS`),
so those appear twice below — once per binary. Only `TLS_INSECURE_SKIP_VERIFY` is
read unprefixed by both.

| Variable                         | Required | Used By  | Description                                                                                             |
|----------------------------------|----------|----------|---------------------------------------------------------------------------------------------------------|
| `PROW_AN__MCP__URL__SHIP_HELP`   | Yes      | Bot      | Ship-help MCP endpoint URL                                                                              |
| `PROW_AN__MCP__TOKEN__SHIP_HELP` | Yes      | Bot      | Bearer token for MCP authentication                                                                     |
| `PROW_AN__SLACK__BOT_TOKEN`      | Bot only | Bot      | Slack bot token (`xoxb-...`)                                                                            |
| `PROW_AN__SLACK__APP_TOKEN`      | Bot only | Bot      | Slack app-level token for Socket Mode (`xapp-...`)                                                      |
| `PROW_AN__MONITORED_CHANNELS`    | Bot only | Bot      | Comma-separated Slack channel IDs to monitor                                                            |
| `PROW_AN__ALLOWED_BOT_IDS`       | No       | Bot      | Comma-separated bot IDs (`B...`) whose Prow URLs are analyzed; the bot always ignores its own           |
| `PROW_AN__MONITOR__ALL`          | No       | Bot      | `"true"` monitors every joined channel instead of only `PROW_AN__MONITORED_CHANNELS` (default `false`)  |
| `PROW_AN__PROMPT__TEMPLATE`      | No       | Bot      | Analysis prompt template with a `{job_url}` placeholder (default: built-in detailed prompt)             |
| `PROW_AN__SLACK__DEBUG`          | No       | Bot      | `"true"` enables verbose Slack SDK / Socket Mode debug logging (default `false`)                        |
| `PROW_AN__MCP__SHIP_HELP__DEBUG` | No       | Bot      | `"true"` enables verbose MCP SSE logging (metadata only, never payload content) (default `false`)       |
| `PROW_AN__MCP__TIMEOUT_SEC`      | No       | Bot      | MCP HTTP client timeout in seconds; caps the whole request incl. SSE read (default `1200`)              |
| `SHIP_HELP_MCP_URL`              | Yes      | CLI      | Ship-help MCP endpoint URL (the bot reads `PROW_AN__MCP__URL__SHIP_HELP` instead)                       |
| `SHIP_HELP_MCP_TOKEN`            | Yes      | CLI      | Bearer token for MCP authentication (the bot reads `PROW_AN__MCP__TOKEN__SHIP_HELP` instead)            |
| `MCP_DEBUG`                      | No       | CLI      | Verbose MCP SSE logging for the CLI (the bot reads `PROW_AN__MCP__SHIP_HELP__DEBUG` instead)            |
| `MCP_TIMEOUT_SECONDS`            | No       | CLI      | MCP HTTP client timeout for the CLI (the bot reads `PROW_AN__MCP__TIMEOUT_SEC` instead); default `1200` |
| `TLS_INSECURE_SKIP_VERIFY`       | No       | CLI, Bot | Set to `"true"` to skip TLS certificate verification                                                    |

For the **bot**, every variable above has a corresponding flag that overrides it
(see [Bot Flags](#bot-flags)). The **CLI** exposes flags only for `--mcp-url`,
`--token`, and `--prompt`; the other variables it honors — the unprefixed
`MCP_DEBUG`, `MCP_TIMEOUT_SECONDS`, and `TLS_INSECURE_SKIP_VERIFY` — are env-only there.
`PROW_AN__PROMPT__TEMPLATE` is read only by the bot; the CLI's prompt comes from `--prompt`.

### CLI Flags

```
prow-analyzer--cli [flags] analyze <prow-url>

  -mcp-url    Ship-help MCP URL (default: $SHIP_HELP_MCP_URL)
  -token      Ship-help MCP token (default: $SHIP_HELP_MCP_TOKEN)
  -prompt     Analysis prompt template (default: "Analyze this Prow CI failure: {job_url}")
```

Exactly two positional arguments are required: the command (`analyze`) and the Prow job URL.

The CLI has no flags for `MCP_DEBUG`, `MCP_TIMEOUT_SECONDS`, or
`TLS_INSECURE_SKIP_VERIFY`; set those via environment variables when needed.

### Bot Flags

```
prow-analyzer--bot [flags]

  -slack-token   Slack bot token (default: $PROW_AN__SLACK__BOT_TOKEN)
  -app-token     Slack app token for socket mode (default: $PROW_AN__SLACK__APP_TOKEN)
  -mcp-url       Ship-help MCP URL (default: $PROW_AN__MCP__URL__SHIP_HELP)
  -mcp-token     Ship-help MCP token (default: $PROW_AN__MCP__TOKEN__SHIP_HELP)
  -channels      Comma-separated channel IDs (default: $PROW_AN__MONITORED_CHANNELS)
  -allowed-bots  Comma-separated bot IDs (B...) whose Prow URLs are analyzed
                 (default: $PROW_AN__ALLOWED_BOT_IDS)
  -prompt        Analysis prompt template with a {job_url} placeholder
                 (default: $PROW_AN__PROMPT__TEMPLATE, else a built-in detailed
                 template requesting root cause, Jira issues, recurring patterns,
                 and recommended actions)
  -monitor-all   Monitor every channel the bot is a member of instead of only
                 -channels (default: $PROW_AN__MONITOR__ALL, else false). Fail-closed:
                 without this and with no -channels, no channel is monitored
  -slack-debug   Verbose Slack SDK / Socket Mode debug logging
                 (default: $PROW_AN__SLACK__DEBUG, else false)
  -mcp-debug     Verbose MCP SSE logging (metadata only: per-line and byte counts,
                 never payload content)
                 (default: $PROW_AN__MCP__SHIP_HELP__DEBUG, else false)
  -mcp-timeout   MCP/Prow HTTP request timeout in seconds; must exceed the longest
                 analysis (default: $PROW_AN__MCP__TIMEOUT_SEC, else 1200)
  -tls-insecure  Skip TLS certificate verification for MCP/Prow requests
                 (default: $TLS_INSECURE_SKIP_VERIFY, else false)
```

### Prompt Template

The prompt is a string with a `{job_url}` placeholder that is replaced with the actual Prow URL before being sent to ship-help. The default bot prompt requests:

1. Root cause
2. Related Jira issues
3. Recurring pattern analysis
4. Recommended actions

Customize via the `-prompt` command-line flag, or — for the bot — the
`PROW_AN__PROMPT__TEMPLATE` environment variable.

> **Note:** The bot resolves its prompt as `-prompt` flag → `PROW_AN__PROMPT__TEMPLATE`
> env var → built-in default, so the `prompt-template` ConfigMap key wired to
> `PROW_AN__PROMPT__TEMPLATE` in `deploy/openshift/deployment.yaml` takes effect on the
> deployed bot. The CLI's prompt comes only from its `-prompt` flag (it does not
> read `PROW_AN__PROMPT__TEMPLATE`).

### Recognized Prow URL Patterns

The regex matches URLs from these domains:

- `https://prow.ci.openshift.org/view/gs/...`
- `https://prow.ci.openshift.org/?pr=...`
- `https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/...`

Extraction correctly handles:

- Plain text URLs
- Slack-formatted links (`<url|label>`)
- Markdown links (`[label](url)`)
- Trailing punctuation (periods, parentheses, angle brackets)

---

## Usage

### CLI

```bash
export SHIP_HELP_MCP_URL="https://<ship-help-mcp-host>/personas/<persona>/mcp"
export SHIP_HELP_MCP_TOKEN="eyJhbGc..."

./prow-analyzer--cli analyze https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816
```

Example output:

```
Analyzing Prow failure...
URL: https://prow.ci.openshift.org/view/gs/...

**Root Cause:**
Test failure in openshift-tests due to timeout waiting for operator rollout.

**Related Jira Issues:**
- OCPBUGS-12345: Operator timeout in e2e tests (Open)
- OCPBUGS-11111: Similar timeout resolved by increasing wait time (Closed)

**Recurring Patterns:**
This failure pattern appears in 3 other jobs in the last 7 days, all in
the same test suite.

**Recommendations:**
1. Check cluster operator status at test start
2. Increase timeout from 5m to 10m
3. Review OCPBUGS-12345 for ongoing investigation

---
Analysis completed in 78.6s
```

### Slack Bot

Once running, the bot automatically responds to any message containing a Prow URL in a monitored channel. No commands or mentions are needed -- just paste a Prow URL.

The bot replies in a thread with:

```
Prow Analyzer Analysis

<analysis text from ship-help>

Analysis completed in 78.6s - Powered by ship-help MCP
```

If analysis fails, the user sees:

```
Analysis failed. Please retry shortly or contact maintainers if this persists.
```

If the analysis queue is full (5 concurrent analyses running), the user sees:

```
Analysis queue is currently full. Please retry in a moment.
```

---

## Deployment

### Prerequisites

- Go 1.22+ (for building from source)
- podman (for container builds)
- Push access to the target registry (default: `images.paas.redhat.com`)
- `oc` CLI (for OpenShift deployment)
- Ship-help MCP token (from the ship-help support channel on Slack)
- Slack app with Socket Mode enabled

### Slack App Setup

1. Go to https://api.slack.com/apps and click **Create New App > From a manifest**.
2. Paste the contents of `deploy/slack/manifest.yaml`.
3. Enable **Socket Mode** under Settings > Socket Mode. Generate an App-Level Token with `connections:write` scope. This is your `xapp-...` token.
4. Under Settings > Install App, install to your workspace. Copy the Bot User OAuth Token. This is your `xoxb-...` token.
5. Invite the bot to each channel you want it to monitor (`/invite @Prow Analyzer`).

**Finding channel IDs:**

- From a Slack URL: `https://app.slack.com/client/T09NY5SBT/C12345678` -- the last path segment is the channel ID.
- Or right-click the channel name > View channel details > the ID is at the bottom of the popup.

### Option 1: Run Locally

```bash
export PROW_AN__MCP__URL__SHIP_HELP="https://<ship-help-mcp-host>/personas/<persona>/mcp"
export PROW_AN__MCP__TOKEN__SHIP_HELP="$(cat /path/to/token.txt | tr -d '\n')"
export PROW_AN__SLACK__BOT_TOKEN="xoxb-..."
export PROW_AN__SLACK__APP_TOKEN="xapp-..."
export PROW_AN__MONITORED_CHANNELS="C12345678"

cd apps/prow-analyzer
make build--bot
./prow-analyzer--bot
```

Test by posting a Prow URL in the monitored channel.

### Option 2: OpenShift Deployment

**Step 1: Build and push the container image.**

Run every command in these steps from the repository root; all paths are relative to it.

```bash
# Log in to the target registry (default: images.paas.redhat.com)
podman login images.paas.redhat.com

# --platform linux/amd64 is required when building on Mac ARM
make -C image/container/prow-analyzer push BUILDFLAGS="--platform linux/amd64"

# Or with a specific tag
make -C image/container/prow-analyzer push BUILDFLAGS="--platform linux/amd64" IMAGE_TAG=v1.1.0
```

The image pushes to `$(IMAGE_NAME)` (defined as `$(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_REPO):$(IMAGE_TAG)`), which defaults to `images.paas.redhat.com/ieng/app/prow-analyzer:latest`. Override `IMAGE_REGISTRY`, `IMAGE_NAMESPACE`, `IMAGE_REPO`, or `IMAGE_TAG` on the `make` command line as needed, and note the exact reference — Step 3 puts it in the manifest.

**Step 2: Create secrets in the target namespace.**

This is the only place the Secret is created; the manifest applied in Step 4 omits
it, so run this first. Create the namespace before the Secret — on a fresh setup it
does not exist yet (the manifest only creates it in Step 4, which runs later).

```bash
oc create namespace <your-namespace>

oc create secret generic prow-analyzer-secrets \
  --from-literal=ship-help-token="YOUR_TOKEN_HERE" \
  --from-literal=slack-bot-token="xoxb-..." \
  --from-literal=slack-app-token="xapp-..." \
  -n <your-namespace>
```

**Step 3: Update the deployment manifest.**

Edit `apps/prow-analyzer/deploy/openshift/deployment.yaml`. The manifest ships with placeholders that
**must** be replaced before `oc apply`, or the pod will not start (placeholder image
→ `ImagePullBackOff`/`CrashLoopBackOff`) or will not reach ship-help (placeholder MCP
URL):

- Set `namespace` on all resources to your target namespace.
- Set the container `image` field to the exact reference you pushed in Step 1 (default: `images.paas.redhat.com/ieng/app/prow-analyzer:latest`).
- Set `mcp-url` in the ConfigMap to your ship-help MCP endpoint.
- Set `monitored-channels` in the ConfigMap to your actual channel IDs.

**Step 4: Deploy.**

The manifest creates the Namespace, ConfigMap, and Deployment — not the Secret,
which was created in Step 2 and is kept out of the manifest so re-applying never
clobbers your tokens.

```bash
oc apply -f apps/prow-analyzer/deploy/openshift/deployment.yaml
```

**Step 5: Verify.**

```bash
# Check pod status
oc get pods -n <your-namespace> -l app=prow-analyzer-bot

# Tail logs
oc logs -f -n <your-namespace> -l app=prow-analyzer-bot

# Test by posting a Prow URL in a monitored channel
```

### Updating a Running Deployment

Run these commands from the repository root.

```bash
# Rebuild and push
make -C image/container/prow-analyzer push BUILDFLAGS="--platform linux/amd64"

# Restart to pull the new image (when using :latest tag)
oc rollout restart deployment/prow-analyzer-bot -n <your-namespace>

# Or update to a new tag
oc set image deployment/prow-analyzer-bot -n <your-namespace> \
  bot=images.paas.redhat.com/ieng/app/prow-analyzer:<new-tag>
```

---

## Development

### Project Structure

```
apps/prow-analyzer/
  cmd/
    prow-analyzer--bot/
      main.go                          Bot entrypoint (Slack socket mode)
      main_test.go                     Environment helper tests
      main_unit_test.go                Direct entrypoint, configuration and event tests
    prow-analyzer--cli/
      main.go                          CLI entrypoint (single URL analysis)
      main_unit_test.go                Direct entrypoint and output/audit contract tests
  pkg/
    analyzer/
      analyzer.go                      Core MCP client and analysis logic
      analyzer_unit_test.go            Unit tests (unit build tag)
      analyzer_integration_test.go     HTTP/SSE tests (integration build tag)
      mocks_test.go                    Shared analyzer test helpers
    audit/
      audit.go                         Audit schema and error categorization
      audit_unit_test.go               Audit contract tests (unit build tag)
    slack/
      handler/
        handler.go                     Slack event handler
        handler_unit_test.go           Unit tests and in-memory mock helpers
        handler_integration_test.go    Async handler tests (integration build tag)
  deploy/
    openshift/deployment.yaml          OpenShift deployment manifest
    slack/manifest.yaml                Slack app manifest
  doc/
    reference.md                       This file (developer & operator reference)
    deployment.md                      Deployment quick-start guide
  Makefile                             Local build targets
  go.mod                               Go module definition

image/container/prow-analyzer/
  Dockerfile                           Multi-stage build with public Red Hat bases
  Makefile                             Container build/push targets
```

### Development environment

> **Linux is required for the `make` targets.** The Makefile recipes
> and suite scripts use strict Bash conventions — notably `shopt -s inherit_errexit`,
> which needs **GNU Bash 4.4+**. macOS ships Bash 3.2, so `make build`,
> `make test`, and `make test--unit` will **not** run natively on macOS.
>
> macOS (and other non-Linux) developers should build and test inside a **Linux
> VM or container** (for example `podman run --rm -it -v "$PWD":/src -w /src
> registry.access.redhat.com/ubi9/go-toolset:1.22 bash`). As a fallback for
> ad-hoc checks, `go` commands can be run directly without the Makefile (e.g.
> `go test -tags unit ./pkg/... ./cmd/...`), but direct Go commands bypass the coverage gate
> and test guards in the suite scripts. CI calls these scripts through Make on Linux.

### Building

```bash
cd apps/prow-analyzer

# Build both binaries
make build

# Build individually
make build--cli
make build--bot

# Clean build artifacts
make clean
```

### Testing

Make delegates to `scripts/test--unit.sh` and `scripts/test--integration.sh`.
Each wrapper owns its configuration and calls the standalone
`scripts/check--test-selection.sh <tag> [packages] [minCount]` guard. Each suite
defines its tag once and passes the same package selection to its guard and test
command. `make check-tags` calls each suite with `--check-only`;
it lists selected tests without running the suites. The guard counts selected
test/benchmark/fuzz/example names; it does not prove every test file has a tag.

```bash
# Run unit tests with coverage, then integration tests with the race detector
make test

# Run package and command unit tests together in the 100% coverage gate
make test--unit

# Use a specific Go executable and package selection for both suites.
# Include every package and command to retain the full default coverage scope.
make test GO=/path/to/go PKGS='./pkg/... ./cmd/...'

# Run specific tests — the suites are tagged, so a build tag is required or the
# run selects zero tests. Unit suite is tagged `unit`:
go test -tags unit -v -run TestAnalyzeFailure ./pkg/analyzer/
go test -tags unit -v -run TestHandle ./pkg/slack/handler/

# Integration suite is tagged `integration`; run it under -race (as `make
# test--integration` does):
go test -tags integration -race -v -run TestAnalyzeFailure ./pkg/analyzer/
go test -tags integration -race -v -run TestHandle ./pkg/slack/handler/
```

Test coverage areas:

- **Commands:** Direct CLI and bot entrypoint tests mock external construction,
  network/socket calls, output and audit writers. Bot event dispatch is tested
  directly; entrypoint fixtures complete their injected event loop before
  restoring dependencies. Flag/environment contracts and environment helpers
  run inside the same package-and-command unit coverage gate.

- **Analyzer (21 tests):** MCP session initialization and reuse, stale session recovery (404 retry), HTTP error handling (401, 403, 404, 500), SSE stream parsing (pings, data lines, empty streams, invalid JSON), context cancellation, dependency injection error paths (marshal, request builder, reader, client.Do), initialization failure retryability, Prow URL extraction (plain, Slack-formatted, trailing punctuation, deck-internal), response formatting (valid and nil results).

- **Handler (10 tests):** Constructor, identifier, event type filtering (non-callback, non-message), bot message rejection, unmonitored channel rejection, no-Prow-URL rejection, successful dispatch, end-to-end with mock MCP server, Slack post error handling, interface compliance.

### Dependencies

| Dependency                     | Version | Purpose                                     |
|--------------------------------|---------|---------------------------------------------|
| `github.com/slack-go/slack`    | v0.14.0 | Slack API client and Socket Mode            |
| `github.com/gorilla/websocket` | v1.5.0  | WebSocket support (transitive via slack-go) |
| Go standard library            | 1.22+   | HTTP, JSON, SSE, TLS, regex, concurrency    |

### Container Image

The Dockerfile uses a multi-stage build:

1. **Builder stage** (`registry.access.redhat.com/ubi9/go-toolset:1.22`) -- copies source, vendors dependencies (`go mod vendor`), and compiles both binaries with `CGO_ENABLED=0`.
2. **Runtime stage** (`registry.access.redhat.com/ubi9/ubi:latest`) -- copies binaries to `/usr/bin/`, sets user to `1000:1000`, sets entrypoint to `prow-analyzer--bot`.

Both stages use publicly pullable `registry.access.redhat.com` base images (no authentication), since the image is built by GitHub Actions, which has no credentials for `registry.ci.openshift.org`.

Both binaries are included in the image. The CLI can be invoked inside the container as `/usr/bin/prow-analyzer--cli`.

Build context is `apps/prow-analyzer/` (the Makefile maps `../../../apps/prow-analyzer` relative to the Dockerfile location).

---

## Troubleshooting

### Diagnosing Failures

The Slack user sees a generic error message. The actual error is logged to stdout:

```bash
oc logs -n <namespace> -l app=prow-analyzer-bot | grep "PROW-ANALYZER ERROR"
```

Additional debug lines (SSE pings, data line sizes, analysis start markers) are also logged with the `PROW-ANALYZER` prefix:

```bash
oc logs -n <namespace> -l app=prow-analyzer-bot | grep "PROW-ANALYZER"
```

### Error Reference

| Log message                                                  | Cause                                            | Fix                                                                                   |
|--------------------------------------------------------------|--------------------------------------------------|---------------------------------------------------------------------------------------|
| `initialize session: init request failed (HTTP 401)`         | Invalid or expired MCP token                     | Get a new token from the ship-help support channel                                    |
| `initialize session: init request failed (HTTP 403)`         | Token lacks permissions                          | Contact ship-help admins                                                              |
| `initialize session: send init request: <network error>`     | MCP URL unreachable                              | Check network/DNS, verify `SHIP_HELP_MCP_URL`                                         |
| `initialize session: no session ID in response`              | MCP server didn't return `Mcp-Session-Id` header | Server-side issue -- contact ship-help team                                           |
| `HTTP 404: ... Session not found`                            | Stale session after timeout                      | Auto-recovered by session retry (if this persists, the recovery logic isn't deployed) |
| `read SSE stream: reading stream: context deadline exceeded` | Analysis exceeded the 1,200s HTTP client timeout | Retry; if persistent, ship-help MCP may be overloaded                                 |
| `send request: <network error>`                              | Network error during analysis request            | Check connectivity to MCP endpoint                                                    |
| `marshal request: ...`                                       | Internal error serializing JSON                  | Should not occur in normal operation -- file a bug                                    |
| `no content in response`                                     | MCP returned empty result                        | Retry; may indicate a ship-help processing error                                      |
| `MCP error <code>: <message>`                                | Ship-help returned a JSON-RPC error              | Check the error message; may need to adjust the prompt                                |
| `parse response: ...`                                        | MCP returned invalid JSON in SSE stream          | Server-side issue -- contact ship-help team                                           |

### Bot Not Responding

1. **Pod running?** `oc get pods -n <namespace> -l app=prow-analyzer-bot`
2. **Correct channel ID?** Verify the channel ID is listed in `PROW_AN__MONITORED_CHANNELS`. Channel IDs look like `C1234ABCD`, not channel names.
3. **Bot invited to channel?** Slack doesn't deliver events for channels the bot hasn't joined. Run `/invite @Prow Analyzer` in the channel.
4. **URL recognized?** Only `prow.ci.openshift.org` and `deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com` URLs are detected.
5. **Message from a human?** Bot messages (including the bot's own replies) are ignored to prevent loops.
6. **Tokens valid?** Check logs for authentication errors. Tokens can expire or be revoked.

### Exec Format Error

```
exec container process `/usr/bin/prow-analyzer--bot`: Exec format error
```

The image was built for ARM (e.g., on a Mac with Apple Silicon) but the cluster runs x86_64. Rebuild with (from the repository root):

```bash
make -C image/container/prow-analyzer push BUILDFLAGS="--platform linux/amd64"
```

Then delete the old pod so the deployment creates a new one with the correct image.

### Queue Full

```
Analysis queue is currently full. Please retry in a moment.
```

All 5 concurrent analysis slots are occupied. Wait for in-progress analyses to complete and retry. If this happens frequently, the semaphore size can be increased by changing the buffer size in `New` (`pkg/slack/handler/handler.go:127`):

```go
semaphore: make(chan struct{}, 5),  // increase this value
```
