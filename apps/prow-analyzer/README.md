# Prow Analyzer

Automated Prow CI failure analysis using Red Hat's ship-help MCP (AI helpdesk).

> ⚠️ **Prow Analyzer is a Red Hat AI agent. Always review AI-generated output
> prior to use — outputs are for internal use only.** New users should start with
> the **[User Guide](doc/user-guide.md)**.


## Documentation

- **[User Guide](doc/user-guide.md)** — start here: purpose, quick start,
  limitations, best practices, review/undo, data handling, RBAC, troubleshooting,
  and contacts.
- [Capabilities & Inventory](doc/capabilities-inventory.md) — code-verified list
  of every tool, API, function, and data source the agent can access.
- [Data Flow & Architecture Diagram](doc/dataflow-architecture.md) — components,
  data flows, trust boundaries, and code/data repositories (Mermaid).
- [Developer & Operator Reference](doc/reference.md) — components, MCP protocol
  flow, configuration, and deployment internals.
- [Deployment quick start](doc/deployment.md).


## Features

- **CLI tool**: Analyze any Prow job URL from the command line
- **Slack bot**: Auto-analyzes Prow URLs posted in monitored Slack channels
- **Comprehensive analysis**: Uses ship-help MCP with access to:
  - Jira issues (active, historical, related)
  - GitHub repositories and PRs
  - Build logs and artifacts
  - Test results and history
  - Automated known-issue triage
  - Slack team discussions
  - Internal documentation
  - Historical failure patterns


## Quick Start

### CLI Usage

```bash
cd apps/prow-analyzer
go build ./cmd/prow-analyzer--cli
export SHIP_HELP_MCP_URL="https://<your-mcp-endpoint>"
export SHIP_HELP_MCP_TOKEN="<your-token>"
./prow-analyzer--cli analyze <prow-url>
```
**Note:** Analysis takes 2-4 minutes as ship-help searches across 9+ data sources (Jira, GitHub, an internal triage system, build logs, etc.).

Example:
```bash
export SHIP_HELP_MCP_URL="https://<ship-help-mcp-host>/personas/<persona>/mcp"
export SHIP_HELP_MCP_TOKEN="eyJhbGc..."
./prow-analyzer--cli analyze https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816
```


### Slack Bot

```bash
# Bot-specific settings use the PROW_AN__ prefix; TLS configuration is shared.
export PROW_AN__MCP__URL__SHIP_HELP="https://<ship-help-mcp-host>/personas/<persona>/mcp"
export PROW_AN__MCP__TOKEN__SHIP_HELP="<your-token>"
export PROW_AN__SLACK__BOT_TOKEN="xoxb-..."
export PROW_AN__SLACK__APP_TOKEN="xapp-..."
export PROW_AN__MONITORED_CHANNELS="C12345678,C87654321"

# Build and run
go build ./cmd/prow-analyzer--bot
./prow-analyzer--bot
```

The bot monitors configured Slack channels and automatically analyzes any Prow URLs posted, replying in a thread with:
- Root cause analysis
- Related Jira issues
- Recurring pattern detection
- Recommended actions



## Installation

### Local Development

```bash
git clone https://github.com/RedHatQE/OpenShift-LP-QE--Tools.git
cd OpenShift-LP-QE--Tools/apps/prow-analyzer
go mod download

# Build CLI
go build ./cmd/prow-analyzer--cli

# Configure environment (required)
export SHIP_HELP_MCP_URL="https://<ship-help-mcp-host>/personas/<persona>/mcp"
export SHIP_HELP_MCP_TOKEN="your-token-here"

# Run CLI
./prow-analyzer--cli analyze "https://prow.ci.openshift.org/view/gs/..."

# Build Bot (optional)
go build ./cmd/prow-analyzer--bot
```


### OpenShift Deployment

See the **[Deployment quick start](doc/deployment.md)** for the full procedure
(build and push the image, create the namespace and Secret, edit the manifest
placeholders, and `oc apply`). The deployment manifest lives at
`deploy/openshift/deployment.yaml`.



## Configuration

### Environment Variables

**Required (CLI):**
- `SHIP_HELP_MCP_URL` - Ship-help MCP endpoint
- `SHIP_HELP_MCP_TOKEN` - Authentication token for ship-help MCP

**Slack bot (all read under the `PROW_AN__` prefix):**
- `PROW_AN__MCP__URL__SHIP_HELP` - Ship-help MCP endpoint
- `PROW_AN__MCP__TOKEN__SHIP_HELP` - Authentication token for ship-help MCP
- `PROW_AN__SLACK__BOT_TOKEN` - Slack bot token (xoxb-...)
- `PROW_AN__SLACK__APP_TOKEN` - Slack app token for socket mode (xapp-...)
- `PROW_AN__MONITORED_CHANNELS` - Comma-separated list of channel IDs

See [doc/reference.md](doc/reference.md#environment-variables) for the full list,
including the bot's optional vars (`PROW_AN__ALLOWED_BOT_IDS`,
`PROW_AN__MONITOR__ALL`, `PROW_AN__PROMPT__TEMPLATE`, `PROW_AN__SLACK__DEBUG`,
`PROW_AN__MCP__SHIP_HELP__DEBUG`, `PROW_AN__MCP__TIMEOUT_SEC`) and `TLS_INSECURE_SKIP_VERIFY`
(read unprefixed by both the bot and the CLI).


### Getting Tokens

**Ship-help MCP Token:**
- Contact the ship-help support channel in Slack or
- Use existing token from ship-help-bot access

**Slack Tokens:**
- Create a Slack app at https://api.slack.com/apps
- Enable Socket Mode and Events API
- Required bot scopes: `channels:history`, `chat:write`, `app_mentions:read`
- Install to workspace and get tokens from OAuth & Permissions



## Architecture

### Components

1. **pkg/analyzer** - Core MCP client
   - Session initialization and management
   - MCP protocol handling (JSON-RPC over SSE)
   - Prow URL extraction and validation
   - Response formatting
2. **cmd/prow-analyzer--cli** - CLI tool
   - Single job analysis
   - Standalone operation
   - Human-readable output
3. **cmd/prow-analyzer--bot** - Slack bot
   - Real-time channel monitoring
   - Automatic URL detection
   - Threaded responses
   - Socket mode for reliable event delivery
4. **pkg/slack/handler** - Event processing
   - Message filtering
   - Channel authorization
   - Async analysis execution


### MCP Protocol Flow

```text
1. Initialize session → Get session ID
2. Call ask_persona with Prow URL
3. Parse SSE response stream
4. Extract analysis from JSON-RPC result
```



## Example Output

```text
:mag: Prow Analyzer Analysis

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

Analysis completed in 78.6s • Powered by ship-help MCP
```


## Development

Based on the working implementation from:
- openshift/ci-tools PR #5251 (analyzer code)
- openshift/release PR #80559 (configuration)


## License

Apache 2.0
