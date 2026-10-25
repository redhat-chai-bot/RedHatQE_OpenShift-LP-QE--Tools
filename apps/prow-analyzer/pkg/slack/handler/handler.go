package handler

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/audit"
)

// dedupGrace adds a margin to the effective HTTP request timeout when sizing
// the duplicate-suppression window; it does not bound total analysis time.
const dedupGrace = 5 * time.Minute

// minDedupTTL suppresses short-succession duplicates even with a low MCP timeout.
const minDedupTTL = 10 * time.Minute

// PartialHandler processes Slack events
type PartialHandler interface {
	Handle(callback *slackevents.EventsAPIEvent, logger *slog.Logger) (handled bool, err error)
	Identifier() string
}

type handler struct {
	client            *slack.Client
	analyzer          *analyzer.Analyzer
	monitoredChannels map[string]bool
	monitorAll        bool            // when true, monitor every channel the bot is a member of (explicit opt-in via WithMonitorAll)
	allowedBotIDs     map[string]bool // bot IDs (other than self) whose messages are analyzed
	selfBotID         string          // this bot's own bot ID, always ignored to prevent loops
	semaphore         chan struct{}   // Limit concurrent analyses

	dedupTTL     time.Duration        // elapsed-time suppression window for a (channel|prowURL) pair
	mu           sync.Mutex           // guards recentlySeen
	recentlySeen map[string]time.Time // (channel|prowURL) -> last time analysis was triggered
}

// Option configures optional handler behavior. Existing callers that pass only
// the required arguments keep working unchanged.
type Option func(*handler)

// WithAllowedBotIDs analyzes Prow URLs posted by the given bot IDs (e.g. another
// bot such as chai-bot). The handler still ignores its own messages, so no loop
// is created. Bot IDs are Slack "B..." identifiers, found as bot_id on messages.
func WithAllowedBotIDs(botIDs []string) Option {
	return func(h *handler) {
		for _, id := range botIDs {
			if id != "" {
				h.allowedBotIDs[id] = true
			}
		}
	}
}

// WithSelfBotID records this bot's own bot ID so its own posts are always
// ignored, even if that ID were mistakenly added to the allow-list.
func WithSelfBotID(botID string) Option {
	return func(h *handler) { h.selfBotID = botID }
}

// WithMonitorAll enables monitoring of every channel the bot is a member of,
// rather than only the explicit monitored-channels allow-list. It is an explicit
// opt-in (e.g. PROW_AN__MONITOR__ALL=true) because it broadens data collection: messages
// from every channel the bot can see may be forwarded to ship-help under shared
// service credentials. Without it, and with no channels configured, the handler
// is fail-closed and monitors nothing.
func WithMonitorAll(enabled bool) Option {
	return func(h *handler) { h.monitorAll = enabled }
}

func (h *handler) Handle(callback *slackevents.EventsAPIEvent, logger *slog.Logger) (handled bool, err error) {
	if callback.Type != slackevents.CallbackEvent {
		return false, nil
	}

	event, ok := callback.InnerEvent.Data.(*slackevents.MessageEvent)
	if !ok {
		return false, nil
	}

	// Resolve the message to analyze. Edits (message_changed) carry the real
	// content in the nested Message; deletions carry nothing to act on. The outer
	// event still holds the channel, so preserve it on the resolved message.
	msg := event
	switch event.SubType {
	case "message_deleted":
		return false, nil
	case "message_changed":
		if event.Message != nil {
			msg = event.Message
			if msg.Channel == "" {
				msg.Channel = event.Channel
			}
		}
	}

	// Loop prevention and bot policy: always ignore our own messages, and ignore
	// other bots unless their bot ID is explicitly allow-listed (WithAllowedBotIDs).
	if msg.BotID != "" {
		if msg.BotID == h.selfBotID || !h.allowedBotIDs[msg.BotID] {
			return false, nil
		}
	}

	// Only monitor configured channels. Fail-closed: a channel is monitored only
	// if it is in the allow-list, unless monitor-all was explicitly enabled
	// (WithMonitorAll / PROW_AN__MONITOR__ALL), in which case every joined channel is
	// monitored so inviting the bot is enough.
	if !h.monitorAll && !h.monitoredChannels[event.Channel] {
		return false, nil
	}

	// Check for a Prow URL in the message text or its attachments. Bots such as
	// chai-bot post the URL inside an attachment or link unfurl, not the body.
	prowURL := extractProwURL(msg)
	if prowURL == "" {
		return false, nil
	}

	logger = logger.With("channel", event.Channel, "url", prowURL)

	// Suppress duplicate analyses of the same job in the same channel. Without
	// this, Slack event retries and streaming bot edits would each re-trigger a
	// full (and costly) analysis of the same URL.
	dedupKey := event.Channel + "|" + prowURL
	if h.seenRecently(dedupKey) {
		logger.Info("Skipping duplicate prow analysis request")
		return true, nil
	}

	// Establish a correlation ID and record the interaction trigger (audit event
	// 1/3). The Slack channel + message timestamp uniquely identifies the trigger.
	// Use the resolved message's timestamp so it is stable across edits.
	interactionID := event.Channel + "/" + msg.TimeStamp
	ctx := audit.WithInteractionID(context.Background(), interactionID)
	audit.Received(ctx, "slack", actorOf(msg), event.Channel, prowURL)

	// Acquire semaphore before spawning goroutine to prevent unbounded buildup
	select {
	case h.semaphore <- struct{}{}:
		go h.analyzeAndRespond(ctx, msg, prowURL, logger)
	default:
		// The request was not enqueued, so undo the dedup mark: otherwise the URL
		// would stay "seen" for the full dedup window and a later Slack retry would
		// be silently deduplicated (handled=true) with neither an analysis nor a
		// "queue full" reply. Forgetting the key lets the retry try the queue again.
		h.forget(dedupKey)
		logger.Info("Prow analyzer queue full, dropping request")
		audit.Outcome(ctx, "rejected", "reason", "queue_full")
		// Inform the requester via Slack that the queue is full
		_, _, postErr := h.client.PostMessage(
			msg.Channel,
			slack.MsgOptionText(analyzer.WithDisclaimer("⚠️ Analysis queue is currently full. Please retry in a moment."), false),
			slack.MsgOptionTS(msg.TimeStamp),
		)
		if postErr != nil {
			logger.Error("Failed to post error message to user", "error", postErr)
		}
	}

	return true, nil
}

// actorOf returns a best-effort identifier of who triggered the message for audit
// logging: a human user ID when present, otherwise the bot's username or bot ID.
func actorOf(msg *slackevents.MessageEvent) string {
	switch {
	case msg.User != "":
		return msg.User
	case msg.Username != "":
		return msg.Username
	default:
		return msg.BotID
	}
}

// extractProwURL returns the first Prow URL found in the message text or any of
// its attachments (Text, Fallback, Pretext, Title, or TitleLink). Bots often put
// the URL in an attachment or link unfurl rather than the message body.
func extractProwURL(msg *slackevents.MessageEvent) string {
	if url := analyzer.ExtractProwURL(msg.Text); url != "" {
		return url
	}
	for _, a := range msg.Attachments {
		for _, s := range []string{a.Text, a.Fallback, a.Pretext, a.Title, a.TitleLink} {
			if url := analyzer.ExtractProwURL(s); url != "" {
				return url
			}
		}
	}
	return ""
}

// seenRecently reports whether key was already processed within dedupTTL. If not,
// it records key as seen now. Safe for concurrent use.
func (h *handler) seenRecently(key string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	now := time.Now()
	// Opportunistically drop stale entries so the map does not grow unbounded.
	for k, t := range h.recentlySeen {
		if now.Sub(t) > h.dedupTTL {
			delete(h.recentlySeen, k)
		}
	}
	if t, ok := h.recentlySeen[key]; ok && now.Sub(t) <= h.dedupTTL {
		return true
	}
	h.recentlySeen[key] = now
	return false
}

// forget removes key from the dedup set so a subsequent event for the same job
// is treated as new. Used when a request that was marked seen could not actually
// be enqueued (queue full), so a Slack retry is allowed to try again rather than
// being silently deduplicated. Safe for concurrent use.
func (h *handler) forget(key string) {
	h.mu.Lock()
	delete(h.recentlySeen, key)
	h.mu.Unlock()
}

func (h *handler) Identifier() string {
	return "prow-analyzer"
}

func (h *handler) analyzeAndRespond(ctx context.Context, event *slackevents.MessageEvent, prowURL string, logger *slog.Logger) {
	// Release semaphore slot when done
	defer func() { <-h.semaphore }()

	overallStart := time.Now()
	fmt.Printf("PROW-ANALYZER: Starting analysis for URL: %s\n", prowURL)

	// Prow Analyzer only explains failures — if the job passed there is nothing to
	// analyze, so skip it (and tell the requester). Outcome is best-effort: unknown
	// results (running jobs, PR dashboards, network errors) fall through to analysis.
	if h.analyzer.JobOutcomeFor(ctx, prowURL) == analyzer.OutcomePassed {
		fmt.Printf("PROW-ANALYZER: Skipping analysis; job passed: %s\n", prowURL)
		logger.Info("Prow job passed; skipping failure analysis")
		audit.Outcome(ctx, "skipped", "reason", "job_passing")
		_, _, postErr := h.client.PostMessage(
			event.Channel,
			slack.MsgOptionText(analyzer.WithDisclaimer("✅ This Prow job passed — no failure analysis needed."), false),
			slack.MsgOptionTS(event.TimeStamp),
		)
		if postErr != nil {
			logger.Error("Failed to post skip notice to user", "error", postErr)
		}
		return
	}

	analyzeStart := time.Now()
	result, err := h.analyzer.AnalyzeFailure(ctx, prowURL)
	analyzeDur := time.Since(analyzeStart)
	if err != nil {
		fmt.Printf("PROW-ANALYZER ERROR: Analysis failed after %s: %v\n", analyzeDur.Round(time.Millisecond), err)
		logger.Error("Prow analyzer analysis failed", "error", err, "analyze", analyzeDur)
		// Record an audit category, not the operational diagnostic. Analyzer HTTP/MCP
		// errors already omit backend payloads before reaching this boundary.
		audit.Outcome(ctx, "failed",
			"error", audit.RedactError(err),
			"duration_ms", analyzeDur.Milliseconds(),
		)
		// Reply to user with error message (don't expose internal error details)
		postStart := time.Now()
		_, _, postErr := h.client.PostMessage(
			event.Channel,
			slack.MsgOptionText(analyzer.WithDisclaimer("❌ Analysis failed. Please retry shortly or contact maintainers if this persists."), false),
			slack.MsgOptionTS(event.TimeStamp),
		)
		if postErr != nil {
			logger.Error("Failed to post error message to user", "error", postErr, "slackPost", time.Since(postStart))
		}
		return
	}

	formatStart := time.Now()
	message := analyzer.FormatSlackResponse(result)
	formatDur := time.Since(formatStart)

	postStart := time.Now()
	_, _, err = h.client.PostMessage(
		event.Channel,
		slack.MsgOptionText(message, false),
		slack.MsgOptionTS(event.TimeStamp),
	)
	postDur := time.Since(postStart)

	if err != nil {
		logger.Error("Failed to post prow analyzer response", "error", err, "slackPost", postDur)
		// Audit the outcome (event 3/3): analysis produced but delivery failed.
		// The error is redacted to a category before it reaches the audit trail.
		audit.Outcome(ctx, "delivery_failed",
			"error", audit.RedactError(err),
			"duration_ms", time.Since(overallStart).Milliseconds(),
		)
		return
	}

	// Audit the AI action / outcome (event 3/3): response delivered. Record
	// metadata (length + content hash) rather than the response text itself.
	audit.Outcome(ctx, "success",
		"duration_ms", time.Since(overallStart).Milliseconds(),
		"response_chars", len(result.Analysis),
		"response_sha256", audit.Hash(result.Analysis),
	)

	// Single structured breakdown of where the request's wall-clock time went:
	// request handling (analyze) → MCP subsystem detail → formatting → Slack post.
	logger.Info("Prow analyzer analysis posted successfully",
		"total", time.Since(overallStart).Round(time.Millisecond),
		"analyze", analyzeDur.Round(time.Millisecond),
		"format", formatDur.Round(time.Millisecond),
		"slackPost", postDur.Round(time.Millisecond),
		"mcp.sessionInit", result.Timings.SessionInit.Round(time.Millisecond),
		"mcp.marshal", result.Timings.Marshal.Round(time.Millisecond),
		"mcp.request", result.Timings.MCPRequest.Round(time.Millisecond),
		"mcp.sseRead", result.Timings.SSERead.Round(time.Millisecond),
		"mcp.parse", result.Timings.Parse.Round(time.Millisecond),
	)
}

// New creates a new prow analyzer event handler. Optional behavior (e.g. which
// bots' messages to analyze) is configured via Option values.
func New(client *slack.Client, a *analyzer.Analyzer, monitoredChannels []string, opts ...Option) PartialHandler {
	channelMap := make(map[string]bool)
	for _, ch := range monitoredChannels {
		if ch != "" {
			channelMap[ch] = true
		}
	}

	// Track per-instance HTTP timeout overrides, with a grace margin and floor.
	// Multiple requests, retries and posting can outlast this suppression window.
	dedupTTL := a.Timeout() + dedupGrace
	if dedupTTL < minDedupTTL {
		dedupTTL = minDedupTTL
	}

	h := &handler{
		client:            client,
		analyzer:          a,
		monitoredChannels: channelMap,
		monitorAll:        false, // fail-closed: monitor only the allow-list unless WithMonitorAll opts in
		allowedBotIDs:     make(map[string]bool),
		semaphore:         make(chan struct{}, 5), // Limit to 5 concurrent analyses
		dedupTTL:          dedupTTL,
		recentlySeen:      make(map[string]time.Time),
	}
	for _, opt := range opts {
		opt(h)
	}
	return h
}
