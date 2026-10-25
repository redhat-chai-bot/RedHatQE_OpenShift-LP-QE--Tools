# Deployment Guide

## Prerequisites

1. **Ship-help MCP Token**
   - Get from the ship-help support channel in Slack
   - Or reuse existing token from ship-help-bot

2. **Slack App** (for bot only)
   - Create at https://api.slack.com/apps
   - Enable Socket Mode
   - Required scopes: `channels:history`, `chat:write`, `app_mentions:read`
   - Get Bot Token (xoxb-...) and App Token (xapp-...)

3. **OpenShift Access** (for production deployment)
   - Access to app.ci cluster or your team's cluster
   - Permissions to create namespace/deployment

## Option 1: Local Testing (Laptop)

```bash
# Set environment variables
export PROW_AN__MCP__URL__SHIP_HELP="https://<ship-help-mcp-host>/personas/<persona>/mcp"
export PROW_AN__MCP__TOKEN__SHIP_HELP="$(cat /path/to/token.txt | tr -d '\n')"
export PROW_AN__SLACK__BOT_TOKEN="xoxb-..."
export PROW_AN__SLACK__APP_TOKEN="xapp-..."
export PROW_AN__MONITORED_CHANNELS="C12345678"  # Your channel ID

# Build (requires Go 1.22+)
go build ./cmd/prow-analyzer--bot

# Run
./prow-analyzer--bot
```

**Test it:**
Post a Prow URL in your monitored channel and watch for bot response.

## Option 2: OpenShift Deployment

### Step 1: Build and Push Image

Run every command in these steps from the repository root; all paths are relative to it.

The Makefile builds `$(IMAGE_NAME)` (defined as
`$(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_REPO):$(IMAGE_TAG)`),
which defaults to `images.paas.redhat.com/ieng/app/prow-analyzer:latest`. Log in to
the **same registry** you build for, and note the exact reference you push — Step 3
requires putting it in the manifest.

```bash
# Log in to the target registry (default: images.paas.redhat.com)
podman login images.paas.redhat.com

# Build and push with the Makefile defaults
#   -> images.paas.redhat.com/ieng/app/prow-analyzer:latest
make -C image/container/prow-analyzer build
make -C image/container/prow-analyzer push

# Or override any of IMAGE_REGISTRY / IMAGE_NAMESPACE / IMAGE_REPO / IMAGE_TAG, e.g.:
#   -> images.paas.redhat.com/<your-namespace>/prow-analyzer:v1.0.0
make -C image/container/prow-analyzer push IMAGE_NAMESPACE=<your-namespace> IMAGE_TAG=v1.0.0
```

### Step 2: Create Secrets

This is the **only** place the Secret is created. The applied manifest in Step 4
deliberately omits `prow-analyzer-secrets` so `oc apply` cannot overwrite these
real tokens with placeholders — so run this step before Step 4.

```bash
# Create namespace
oc create namespace prow-analyzer

# Create secrets (replace with actual values)
oc create secret generic prow-analyzer-secrets \
  --from-literal=ship-help-token="YOUR_TOKEN_HERE" \
  --from-literal=slack-bot-token="xoxb-..." \
  --from-literal=slack-app-token="xapp-..." \
  -n prow-analyzer
```

### Step 3: Update Configuration

`apps/prow-analyzer/deploy/openshift/deployment.yaml` ships with placeholders that **must** be replaced
before `oc apply`. Leaving them will either stop the pod from starting (placeholder
image → `ImagePullBackOff`/`CrashLoopBackOff`) or stop it from reaching ship-help
(placeholder MCP URL). Replace all three:

```yaml
# Deployment (spec.template.spec.containers[0].image):
# point at the exact image you pushed in Step 1
    image: images.paas.redhat.com/ieng/app/prow-analyzer:latest

# ConfigMap: your ship-help MCP endpoint
  mcp-url: "https://<ship-help-mcp-host>/personas/<persona>/mcp"

# ConfigMap: your actual channel IDs
  monitored-channels: "C12345678,C87654321"
```

### Step 4: Deploy

The manifest defines the Namespace, ConfigMap, and Deployment — but **not** the
Secret. `prow-analyzer-secrets` is created once in Step 2 with your real tokens and
is intentionally kept out of this manifest, so re-applying it never clobbers those
tokens with placeholders. Ensure Step 2 has run first.

```bash
oc apply -f apps/prow-analyzer/deploy/openshift/deployment.yaml
```

### Step 5: Verify

```bash
# Check pod status
oc get pods -n prow-analyzer

# Check logs
oc logs -f deployment/prow-analyzer-bot -n prow-analyzer
```

## Option 3: Deploy to app.ci Cluster

Same as Option 2, but:
- Use namespace on app.ci cluster
- Image might already be accessible if using ci-operator
- May need approval from cluster admins

## Getting Channel IDs

**Method 1: Slack URL**

```text
https://app.slack.com/client/T09NY5SBT/C12345678
                                      ^^^^^^^^^
                                      Channel ID
```

**Method 2: Right-click channel → View channel details → bottom of popup**

## Troubleshooting

### Bot not responding

1. Check logs: `oc logs -f deployment/prow-analyzer-bot`
2. Verify channel ID is correct
3. Ensure bot is invited to channel
4. Check tokens are valid

### MCP authentication errors

- Token may have trailing newline: `tr -d '\n'`
- Token may have expired
- Wrong MCP URL

### Build failures

- Requires Go 1.22+
- Run `go mod tidy` first
- Check network access for dependencies

## Monitoring

```bash
# Watch logs
oc logs -f deployment/prow-analyzer-bot -n prow-analyzer

# Check resource usage
oc top pod -n prow-analyzer

# Restart if needed
oc rollout restart deployment/prow-analyzer-bot -n prow-analyzer
```
