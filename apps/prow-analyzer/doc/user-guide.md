# Prow Analyzer -- User Guide

> ⚠️ **ALWAYS REVIEW AI-GENERATED OUTPUT OR ACTIONS PRIOR TO USE.**
> Prow Analyzer is a Red Hat AI agent. Its analyses, root-cause claims, Jira
> references, and recommendations are AI-generated, may be incomplete or wrong,
> and are **for internal use only**. Verify every output against the source data
> (Prow logs, Jira, GitHub) before you act on it or share it. Normal code review
> and compliance processes still apply.

This guide is for everyone who interacts with the Prow Analyzer bot in Slack or
runs the CLI. For deep implementation detail, see
[`reference.md`](reference.md); for deployment, see
[`deployment.md`](deployment.md).

## Table of Contents

- [Overview of the AI Use Case](#overview-of-the-ai-use-case)
  - [Quick Start](#quick-start)
- [Agent's Persona and Purpose](#agents-persona-and-purpose)
- [Capabilities and Inventory](#capabilities-and-inventory)
  - [Tools and Data Sources](#tools-and-data-sources)
  - [Authorized and Prohibited Actions](#authorized-and-prohibited-actions)
- [Limitations](#limitations)
- [Best Practices](#best-practices)
- [Human Review and Action](#human-review-and-action)
- [Correction Mechanism (Undo)](#correction-mechanism-undo)
- [Data Handling](#data-handling)
- [RBAC Enforcement](#rbac-enforcement)
- [Troubleshooting](#troubleshooting)
- [Feedback](#feedback)
- [Point of Contact](#point-of-contact)

---

## Overview of the AI Use Case

**Prow Analyzer** automates the first-pass investigation of **Prow CI job
failures** for OpenShift Layered Product QE. Instead of manually reading build
logs, hunting for related Jira issues, and checking whether a failure is a known
flake, you give it a Prow job URL and it returns a structured analysis.

It works by sending your request to **Red Hat's ship-help MCP** (an internal AI
helpdesk), which searches across 9+ data sources and returns a natural-language
analysis. Prow Analyzer itself does not run the model -- it is a thin client that
formats the request and presents the response.

**Key features:**

- **Slack bot** -- Paste a Prow URL in a monitored channel and the bot replies
  in-thread. No commands or @-mentions needed.
- **CLI** -- Analyze a single Prow URL from your terminal (`prow-analyzer--cli`).
- **Structured output** -- Each analysis aims to provide: (1) root cause,
  (2) related Jira issues, (3) recurring-pattern analysis, (4) recommended
  actions.
- **Read-only** -- It reads data and posts a message. It does not modify Jira,
  GitHub, or CI.
- **Clearly labeled** -- Every analysis is marked **🤖 AI-generated** at the top
  and bottom of the output, and is preceded by the Red Hat AI agent notice, so it
  is always identifiable as AI-generated content.

**Expected response time:** 2-4 minutes, because ship-help searches many
sources per request.

### Quick Start

#### Slack bot (most users)

1. Make sure the bot is a member of your channel. If not, ask a maintainer to
   run `/invite @Prow Analyzer`, or invite it yourself if you have permission.
2. Paste a supported Prow job URL into the channel as a normal message.
3. Wait 2-4 minutes. The bot replies **in a thread** on your message with the
   analysis.

Supported URL formats (must be one of these domains):

- `https://prow.ci.openshift.org/view/gs/...`
- `https://prow.ci.openshift.org/?pr=...`
- `https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/...`

No configuration is required for Slack users -- the bot is already configured by
the maintainers.

#### CLI (advanced users)

You need a ship-help MCP token (request one in **the ship-help support channel** on Slack).

```bash
cd apps/prow-analyzer
go build ./cmd/prow-analyzer--cli

export SHIP_HELP_MCP_URL="https://<ship-help-mcp-host>/personas/<persona>/mcp"
export SHIP_HELP_MCP_TOKEN="<your-token>"

./prow-analyzer--cli analyze "https://prow.ci.openshift.org/view/gs/<path-to-job>"
```

The CLI prints the mandatory usage notice, then the analysis, then a completion
footer.

---

## Agent's Persona and Purpose

- **Role:** A CI-failure triage assistant for OpenShift Layered Product QE.
- **Goal:** Reduce the time engineers spend on first-pass triage of Prow
  failures by summarizing likely root cause, surfacing related Jira issues,
  flagging recurring patterns, and suggesting next steps.
- **Operational context:** Internal Red Hat use only, inside QE Slack channels
  and developer terminals. Every request and response is scoped to Prow CI
  failure analysis. Outputs are **drafts for a human to verify**, not
  authoritative conclusions and not customer-facing content.
- **Tone:** Concise, technical, oriented toward actionable next steps.

---

## Capabilities and Inventory

> For the full, code-verified inventory (tools, skills, APIs, functions, data
> sources, scopes, and egress), see
> **[Capabilities & Inventory](capabilities-inventory.md)**. The summary below
> covers the essentials.

### Tools and Data Sources

Prow Analyzer has exactly **one** outbound capability of its own: it calls the
ship-help MCP `ask_persona` tool over JSON-RPC/SSE. All richer data access
happens **inside ship-help**, not in this agent.

| Layer                        | Item                                  | Notes                                                                   |
|------------------------------|---------------------------------------|-------------------------------------------------------------------------|
| Agent tool                   | ship-help MCP `ask_persona`           | The only tool this agent calls. Sends a prompt containing the Prow URL. |
| Agent input                  | Prow URL extraction (regex)           | Recognizes the three URL patterns listed above.                         |
| Agent output                 | Slack message (`chat:write`) / stdout | Posts an in-thread reply, or prints to terminal.                        |
| Slack read                   | `channels:history`                    | Reads messages in channels it is a member of, to detect Prow URLs.      |
| Data sources (via ship-help) | Jira issues                           | Active, historical, and related issues.                                 |
| Data sources (via ship-help) | GitHub repositories and PRs           |                                                                         |
| Data sources (via ship-help) | Build logs and artifacts              |                                                                         |
| Data sources (via ship-help) | Test results and history              |                                                                         |
| Data sources (via ship-help) | Automated known-issue triage          |                                                                         |
| Data sources (via ship-help) | Slack team discussions                |                                                                         |
| Data sources (via ship-help) | Internal documentation                |                                                                         |
| Data sources (via ship-help) | Historical failure patterns           |                                                                         |

> The agent does **not** have its own direct connection to Jira, GitHub, or CI.
> It cannot browse the web, run arbitrary tools, or execute code. Its knowledge
> of those systems comes entirely from what ship-help returns.

### Authorized and Prohibited Actions

**Can do autonomously (no human approval needed):**

- Detect a Prow URL in a monitored Slack channel and analyze it.
- Query ship-help and post the analysis as an in-thread Slack reply.
- Post a short error or "queue full" message when it cannot complete a request.
- Recover a stale ship-help session and retry the analysis once.
- Run up to 5 analyses concurrently; additional requests are rejected with a
  "queue full" message (it does not queue indefinitely).

**Requires a human (the agent will not do these):**

- Fixing the failing test, editing code, or opening/closing/commenting on Jira
  or GitHub. **All remediation is manual.**
- Deciding whether the root cause is correct or acting on any recommendation.
- Retriggering CI jobs.
- Being added to or removed from channels (a human must invite/remove the bot).

**Restricted / cannot do (by design):**

- No write access to Jira, GitHub, CI, or any system other than posting a Slack
  message. It is **read-and-report only**.
- Does not analyze non-Prow URLs or arbitrary free-text questions -- it only
  triggers on the recognized Prow URL patterns.
- Does not respond to other bots' messages (loop prevention).
- Does not act in channels it has not been invited to.

---

## Limitations

- **AI hallucination risk.** The underlying model can invent plausible-sounding
  but false details. Treat all specifics as unverified until you check them:
  - **Jira issue IDs** may be wrong, closed, unrelated, or nonexistent. Open
    each cited issue and confirm it is real and relevant.
  - **"Recurring pattern" / frequency claims** (e.g. "appears in 3 other jobs in
    the last 7 days") are estimates and may be inaccurate.
  - **Line numbers, commit SHAs, timestamps, and log quotes** can be
    approximated or fabricated. Confirm against the actual Prow log.
- **Point-in-time answer.** The analysis reflects data available at the moment of
  the request. Logs that expire (Prow artifacts have retention limits) or issues
  that change later are not re-checked.
- **Out of scope:** anything that is not a Prow CI failure -- product usage
  questions, general coding help, non-CI incidents, infra provisioning, etc.
- **URL coverage:** only the three URL patterns above are recognized. Other CI
  systems or shortened/redirected links will be ignored.
- **Latency and throughput:** 2-4 minutes per analysis; max 5 concurrent. During
  bursts you may get a "queue full" reply.
- **Non-determinism:** the same URL can yield differently worded analyses on
  different runs.

---

## Best Practices

**Effective interactions:**

- Paste **one Prow URL per message** so the reply threads cleanly onto it.
- Use a **canonical `prow.ci.openshift.org/view/gs/...` link** (copied straight
  from the Prow UI) rather than a shortened or hand-edited URL.
- Add **one line of human context** in the same message ("failing only on AWS
  interop since yesterday") -- ship-help can use it, and it helps reviewers.
- **Read the whole thread reply**, especially the recommendations, before acting.
- Cross-check every **Jira ID and pattern claim** before quoting it to others.

**Edge cases where it may struggle:**

- **Expired/garbage-collected logs** -- if the Prow artifacts are gone, the
  analysis will be thin or speculative.
- **Infra/flake failures** (node not ready, image pull, quota) -- may be
  misattributed to test code, or vice versa.
- **Brand-new failure signatures** with no history -- weaker pattern analysis.
- **Very large logs / long-running analyses** -- can approach the 1,200s (20-min) timeout
  and fail; retry once before escalating.
- **Multiple URLs in one message** -- only the first recognized URL is analyzed.
- **Bursty channels** -- expect "queue full" during spikes; retry shortly.

---

## Human Review and Action

> ⚠️ **ALWAYS REVIEW AI-GENERATED OUTPUT OR ACTIONS PRIOR TO USE.**

Every analysis is a **draft hypothesis**, not a verified conclusion. Before you
rely on, act on, or forward any output:

1. **Confirm the root cause** against the actual Prow build log and test output.
   Do not accept the stated cause on faith.
2. **Open every cited Jira issue** and verify it exists, is relevant, and is in
   the stated state. Discard any that do not check out.
3. **Sanity-check pattern/frequency claims** using Sippy rather
   than trusting the number in the reply.
4. **Validate recommendations** with your own judgment before applying them --
   especially anything that changes timeouts, retries, or test logic.
5. **Follow existing process.** Any code, config, or Jira change that results
   from an analysis still goes through normal **code review, approvals, and
   compliance** -- the bot's output does not shortcut any of that.
6. **Do not paste outputs to customers or externally.** Outputs are internal-use
   only.

If an output looks confidently wrong, treat that as a signal to double-check
*more*, not less -- and please report it (see [Feedback](#feedback)).

---

## Correction Mechanism (Undo)

Prow Analyzer's only real-world action is **posting a Slack message** (or
printing to your terminal). It makes **no changes** to Jira, GitHub, or CI, so
there is nothing to roll back in those systems. To undo or stop it:

- **Undo a specific reply:** delete the bot's Slack thread reply. Workspace
  admins and channel managers can delete bot messages
  (hover the message → **⋮ More actions → Delete message**). If you cannot delete
  it yourself, ask a maintainer or Slack admin.
- **Stop it from analyzing a channel:** remove the bot from the channel
  (`/remove @Prow Analyzer`, or **View channel details → Integrations →
  remove the app**). Slack stops delivering that channel's messages to the bot
  immediately, so it will no longer respond there.
- **Stop it entirely (maintainers):** scale the deployment to zero --
  `oc scale deployment/prow-analyzer-bot --replicas=0 -n <namespace>` -- or
  delete the pod. See [`deployment.md`](deployment.md).
- **Undo an in-flight request:** you cannot cancel a request mid-analysis; just
  ignore/delete the reply when it arrives.

Because the agent is read-only, the correction surface is limited to messages and
availability -- there is no data mutation to reverse.

---

## Data Handling

> 🔒 **Do NOT enter personal information or customer information into Prow
> Analyzer.** This includes customer names, case numbers, account/subscription
> data, IP addresses, credentials, tokens, or any PII/PData -- in Slack messages
> the bot will read, in the CLI prompt, or in the `-prompt` template.

- Anything in a message that contains a Prow URL (and the CLI prompt) is sent to
  the **ship-help MCP** backend for processing. Keep it to CI/technical content.
- Do not paste secrets (tokens, kubeconfigs, passwords) into monitored channels;
  the bot forwards message context to ship-help.
- Use only sanctioned internal channels; treat all inputs and outputs as
  **internal / confidential**.
- If you believe sensitive data was submitted, delete the message and notify the
  point of contact below.

---

## RBAC Enforcement

**Important:** Prow Analyzer does **not** inherit or enforce your individual user
permissions. It runs with **shared service credentials**:

- A single **ship-help MCP token** is used for every request, regardless of who
  posted the URL. The analysis reflects what *that service token* can see, not
  what *you* can see.
- A single **Slack bot token** posts all replies.

What actually gates access:

- **Slack channel membership.** The bot only sees, and only replies in, channels
  it has been invited to. Anyone who can post in a monitored channel can trigger
  an analysis, and everyone in that channel sees the reply. Control exposure by
  controlling **who is in the channel** and **which channels the bot is invited
  to**.
- **CLI possession of a token.** Anyone holding a valid ship-help token can run
  the CLI with the same backend access.

**How to verify your access level:**

- **Slack:** open the channel → **View channel details → Members / Integrations**
  to confirm you (and the bot) are present. Your ability to see a reply equals
  your channel membership.
- **CLI:** whether your token works determines your access; if `initialize
  session` fails with `HTTP 401/403`, your token is invalid or lacks
  permissions. Request or renew a token in **the ship-help support channel**.
- **Backend data scope:** because access is via a shared service account, ask the
  ship-help team (the ship-help support channel) what that account is authorized to read if you
  need to confirm data boundaries.

> Since RBAC is **not** per-user here, be deliberate about channel membership and
> never post data into a monitored channel that not everyone in it should see.

---

## Troubleshooting

| Symptom                                    | Likely cause                                   | What to do                                                                                                      |
|--------------------------------------------|------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| Bot doesn't reply at all                   | Bot not in the channel, or URL not recognized  | Confirm the bot is a member (`/invite @Prow Analyzer`); confirm the URL is one of the three supported patterns. |
| Bot doesn't reply to your reply            | The message was from a bot, or had no Prow URL | Post the URL as a human message; messages from bots (including the analyzer's own replies) are ignored.         |
| `Analysis failed. Please retry shortly...` | Backend/network/session error                  | Retry once. If it persists, escalate (the real error is in the pod logs).                                       |
| `Analysis queue is currently full.`        | 5 concurrent analyses already running          | Wait a moment and retry.                                                                                        |
| CLI: `init request failed (HTTP 401)`      | Invalid/expired MCP token                      | Get a new token from the ship-help support channel.                                                             |
| CLI: `init request failed (HTTP 403)`      | Token lacks permissions                        | Contact ship-help admins via the ship-help support channel.                                                     |
| CLI: `send init request: <network error>`  | MCP URL unreachable                            | Check VPN/network/DNS and `SHIP_HELP_MCP_URL`.                                                                  |
| `context deadline exceeded`                | Analysis exceeded the 1,200s timeout           | Retry; if persistent, ship-help may be overloaded.                                                              |
| Analysis is thin or vague                  | Logs expired, or novel failure with no history | Check the Prow artifacts still exist; add human context and retry.                                              |

Maintainers: the user-visible message is intentionally generic; the real error
is logged with the `PROW-ANALYZER ERROR` / `PROW-ANALYZER` prefix. See the
[Troubleshooting section of `reference.md`](reference.md#troubleshooting)
for the full error reference and log-diagnosis commands.

---

## Feedback

> *(Feedback channels apply to team/organizational use, not individual personal use.)*

Please report inaccurate analyses, hallucinated Jira issues, unexpected
behavior, or performance problems:

- **Preferred:** open a GitHub issue in the repository
  [`RedHatQE/OpenShift-LP-QE--Tools`](https://github.com/RedHatQE/OpenShift-LP-QE--Tools/issues)
  and label it `prow-analyzer`. Include the Prow URL, the reply you got, and what
  was wrong.
- **Slack:** post in the QE team channel used for tooling (ask a maintainer for
  the current channel if unsure).
- **Backend/model issues** (ship-help itself returning bad data): raise in
  **the ship-help support channel**.

<!-- MAINTAINERS: replace the above with a dedicated feedback form/board link and
     the canonical Slack feedback channel once established. -->

---

## Point of Contact

- **Maintaining team:** `@RedHatQE/openshift-lp-qe-staff` (repository CODEOWNERS)
  -- reach them via a GitHub issue or by @-mentioning the team on a PR/issue.
- **Ship-help MCP backend / tokens:** the ship-help support channel on Slack.
- **Team alias email:** _TODO -- add the team's distribution-list email here._
  <!-- MAINTAINERS: no team alias email exists in the repo; fill in the real
       alias (e.g. openshift-lp-qe@redhat.com) before publishing this guide. -->

If you are unsure who to contact, open a GitHub issue in
[`RedHatQE/OpenShift-LP-QE--Tools`](https://github.com/RedHatQE/OpenShift-LP-QE--Tools/issues)
and the CODEOWNERS team will be notified.
