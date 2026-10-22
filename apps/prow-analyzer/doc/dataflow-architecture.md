# Prow Analyzer -- Data Flow & Architecture Diagram

> System components, data flows, and the code/data repositories involved in the
> Prow Analyzer AI system. Diagrams use Mermaid (renders on GitHub). For deeper
> component detail see [reference.md](reference.md); for the full
> capability list see [capabilities-inventory.md](capabilities-inventory.md).

## 1. Component & Data-Flow Diagram

```mermaid
flowchart TB
    subgraph User["👤 User (an engineer)"]
        U1["Posts a Prow CI URL in Slack"]
        U2["(alt) Runs prow-analyzer--cli"]
    end

    subgraph Slack["Slack Workspace (SaaS)"]
        SW["Monitored channels"]
    end

    subgraph OCP["OpenShift cluster — ns: <your-namespace>"]
        subgraph BOT["Deployment: prow-analyzer-bot (single replica, non-root)"]
            H["Socket-mode client + handler<br/>• filter chain (URL/bot/channel)<br/>• semaphore: max 5 concurrent"]
            A["analyzer (MCP client)<br/>• session init/recover<br/>• HAP guardrails*<br/>• compliance notices"]
        end
        SEC["Secret / env vars<br/>PROW_AN__MCP__TOKEN__SHIP_HELP<br/>PROW_AN__SLACK__BOT_TOKEN / PROW_AN__SLACK__APP_TOKEN"]
    end

    subgraph SH["ship-help MCP (AI helpdesk) — persona: <persona>"]
        MCP["ask_persona tool<br/>(LLM + retrieval)"]
    end

    subgraph DS["Data sources (read by ship-help, not by the bot)"]
        direction LR
        J["Jira"]
        G["GitHub repos/PRs"]
        L["Build logs & artifacts"]
        T["Test results/history"]
        F["known-issue triage"]
        SD["Slack discussions"]
        DOC["Internal docs"]
        HP["Historical patterns"]
    end

    U1 -->|"message.channels event (WSS)"| SW
    SW -->|"Socket Mode event"| H
    H -->|"prow URL + prompt"| A
    U2 -->|"analyze &lt;url&gt;"| A
    A -->|"1. initialize / 2. tools/call ask_persona<br/>Bearer token, JSON-RPC over HTTPS"| MCP
    MCP -.->|"reads"| DS
    MCP -->|"SSE stream: analysis text"| A
    A -->|"HAP filter + AI-generated label + notices"| H
    H -->|"chat.postMessage (in-thread)"| SW
    SW -->|"threaded reply"| U1
    A -->|"stdout"| U2
    SEC -.->|"injected env"| BOT

    classDef ext fill:#f4f4f4,stroke:#888;
    class Slack,SH,DS ext;
```

\* HAP guardrails (system-prompt preamble + output content filter) are **proposed
/ in progress** — see the status note in §5.

## 2. Request Sequence (happy path)

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Slack
    participant Bot as prow-analyzer-bot
    participant MCP as ship-help MCP (<persona>)
    participant Data as Data sources

    User->>Slack: Post message with Prow URL
    Slack-->>Bot: message.channels event (Socket Mode/WSS)
    Bot->>Bot: Ack immediately; filter (URL? not-bot? channel?); acquire semaphore
    Bot->>MCP: initialize (Bearer token) → Mcp-Session-Id
    Bot->>MCP: tools/call ask_persona { prompt + job URL }
    MCP->>Data: Retrieve across Jira/GitHub/logs/etc.
    Data-->>MCP: Context
    MCP-->>Bot: SSE stream → analysis text
    Bot->>Bot: HAP output filter + AI-generated label + disclaimer/review notice
    Bot->>Slack: chat.postMessage (in-thread reply)
    Slack-->>User: Threaded analysis
    Note over Bot,MCP: On "Session not found": invalidate + re-init + retry once
```

## 3. Trust / Network Boundaries

```mermaid
flowchart LR
    subgraph Internal["internal network"]
        subgraph Cluster["OpenShift (<your-namespace>)"]
            Bot["prow-analyzer-bot<br/>(outbound-only; no ingress)"]
        end
        SHb["ship-help MCP"]
    end
    SaaS["Slack (SaaS)"]

    Bot -- "WSS + HTTPS (outbound)" --> SaaS
    Bot -- "HTTPS/SSE (outbound, Bearer)" --> SHb

    note1["No public route/ingress to the bot<br/>(Socket Mode = outbound WebSocket)"]
    Bot -.- note1
```

## 4. Code & Data Repositories / Stores

| Kind                     | Name / location                                                                                                        | Role                                                                                                                                                                                              | Sensitive?                   |
|--------------------------|------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------|
| **Source code repo**     | `github.com/RedHatQE/OpenShift-LP-QE--Tools` (module path)                                                             | All agent code under `apps/prow-analyzer/`                                                                                                                                                        | No                           |
| **Container image repo** | `images.paas.redhat.com/ieng/app/prow-analyzer` (deployed tag: `<tag>`)                                                | Built runtime image (both bot + CLI binaries)                                                                                                                                                     | No (but do not bake secrets) |
| **Deployment manifests** | `apps/prow-analyzer/deploy/openshift/`, `deploy/slack/`                                                                | K8s resources + Slack app manifest                                                                                                                                                                | No                           |
| **Runtime config store** | ConfigMap `prow-analyzer-config` in ns `<your-namespace>`, surfaced to the container as env vars via `configMapKeyRef` | `PROW_AN__MCP__URL__SHIP_HELP` (`mcp-url`), `PROW_AN__MONITORED_CHANNELS` (`monitored-channels`), `PROW_AN__PROMPT__TEMPLATE` (`prompt-template`); `PROW_AN__MONITOR__ALL` is a literal env value | No                           |
| **Secrets store**        | K8s Secret / env in ns `<your-namespace>`                                                                              | `PROW_AN__MCP__TOKEN__SHIP_HELP`, `PROW_AN__SLACK__BOT_TOKEN`, `PROW_AN__SLACK__APP_TOKEN`                                                                                                        | **Yes**                      |
| **Ephemeral state**      | In-memory only (MCP session ID, semaphore)                                                                             | No database; nothing persisted by the bot                                                                                                                                                         | No                           |
| **Logs**                 | Pod stdout (`oc logs`)                                                                                                 | Timing + error + (proposed) HAP-redaction counts                                                                                                                                                  | Low; avoid logging payloads  |
| **Backend data stores**  | Inside **ship-help** (Jira, GitHub, logs, an internal triage system, etc.)                                             | Read by ship-help, **not** by the bot                                                                                                                                                             | Governed by ship-help        |

**Key data-handling facts**
- The bot is **stateless**: it holds only an in-memory MCP session ID and a
  concurrency semaphore. It has **no database** and persists **no** analysis
  content.
- The bot has **no ingress**; all connections are outbound (Slack WSS + ship-help
  HTTPS/SSE).
- The bot never reads the backend data sources directly — it only receives
  ship-help's summarized text.

## 5. Status & accuracy notes

- **Persona:** the ship-help persona used at runtime is selected via the
  `PROW_AN__MCP__URL__SHIP_HELP` (`/personas/<persona>/mcp`) and may differ from the
  `<persona>` default in the committed manifest — set it for your environment.
- **Config source:** the committed manifest ships a `prow-analyzer-config`
  ConfigMap and surfaces its keys to the container as env vars via
  `configMapKeyRef` (tokens come from the `prow-analyzer-secrets` Secret via
  `secretKeyRef`; that Secret is created out-of-band, not shipped in the manifest,
  so `oc apply` can't overwrite real tokens with placeholders). `PROW_AN__MONITOR__ALL` is
  set as a literal env value on the Deployment.
- **HAP guardrails** shown with an asterisk are **not yet in the deployed
  image** — they were in progress at the time of writing. Treat that node as
  "planned" until a rebuilt image is deployed.
- **Backend internals** (ship-help's model, retrieval, and its own data-store
  access controls) are **out of scope of this repo** and cannot be verified here;
  confirm with the ship-help team (the ship-help support channel).
