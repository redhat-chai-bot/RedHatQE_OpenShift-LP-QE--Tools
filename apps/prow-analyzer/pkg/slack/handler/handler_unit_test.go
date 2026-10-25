//go:build unit

package handler

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

// In-memory test doubles avoid external services.

// doerFunc adapts a function to analyzer.HTTPDoer so tests can drive the
// analyzer's HTTP responses without a network.
type doerFunc func(*http.Request) (*http.Response, error)

func (f doerFunc) Do(r *http.Request) (*http.Response, error) { return f(r) }

// mockSlackDoer is an in-memory Slack HTTP transport. It records chat.postMessage
// text and, when ok is false, makes PostMessage return an error so the caller's
// post-error branch is exercised — all without opening a socket.
type mockSlackDoer struct {
	mu    sync.Mutex
	texts []string
	ok    bool
}

func (m *mockSlackDoer) Do(req *http.Request) (*http.Response, error) {
	if strings.Contains(req.URL.Path, "chat.postMessage") {
		_ = req.ParseForm()
		m.mu.Lock()
		m.texts = append(m.texts, req.PostForm.Get("text"))
		m.mu.Unlock()
		if !m.ok {
			return jsonResp(`{"ok":false,"error":"posting_error"}`), nil
		}
	}
	return jsonResp(`{"ok":true,"ts":"123"}`), nil
}

func (m *mockSlackDoer) captured() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]string(nil), m.texts...)
}

func jsonResp(body string) *http.Response {
	return &http.Response{
		StatusCode: 200,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     make(http.Header),
	}
}

// newMockSlack returns a *slack.Client backed by an in-memory transport.
func newMockSlack(ok bool) (*slack.Client, *mockSlackDoer) {
	d := &mockSlackDoer{ok: ok}
	return slack.New("test-token", slack.OptionHTTPClient(d)), d
}

// passingJobAnalyzer builds an analyzer whose Prow finished.json fetch reports a
// passing job, so the "skip analysis" path can be exercised.
func passingJobAnalyzer() *analyzer.Analyzer {
	stub := doerFunc(func(*http.Request) (*http.Response, error) {
		return jsonResp(`{"passed":true}`), nil
	})
	return analyzer.NewAnalyzer("", "", "", analyzer.WithHTTPClient(stub))
}

// failingJobAnalyzer builds an analyzer whose HTTP client always errors, so the
// finished.json probe is OutcomeUnknown (analysis proceeds) and AnalyzeFailure
// then errors — exercising the analysis-failure path.
func failingJobAnalyzer() *analyzer.Analyzer {
	stub := doerFunc(func(*http.Request) (*http.Response, error) {
		return nil, context.DeadlineExceeded
	})
	return analyzer.NewAnalyzer("", "", "", analyzer.WithHTTPClient(stub))
}

// successAnalyzer builds an analyzer whose MCP round-trip succeeds in memory
// (initialize returns a session id; tools/call returns SSE analysis text).
func successAnalyzer() *analyzer.Analyzer {
	stub := doerFunc(func(req *http.Request) (*http.Response, error) {
		var m struct {
			Method string `json:"method"`
		}
		if req.Body != nil {
			json.NewDecoder(req.Body).Decode(&m)
		}
		if m.Method == "initialize" {
			r := jsonResp(`{"jsonrpc":"2.0","id":0}`)
			r.Header.Set("Mcp-Session-Id", "s1")
			return r, nil
		}
		return jsonResp(`data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Analysis"}]}}` + "\n"), nil
	})
	return analyzer.NewAnalyzer("", "", "", analyzer.WithHTTPClient(stub))
}

func msgCallback(m *slackevents.MessageEvent) *slackevents.EventsAPIEvent {
	return &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: m,
		},
	}
}

// --- New / options / accessors ---

func TestNew(t *testing.T) {
	client := &slack.Client{}
	a := analyzer.NewAnalyzer("url", "token", "template")
	h := New(client, a, []string{"C123", "C456"})

	hh, ok := h.(*handler)
	if !ok {
		t.Fatal("Expected handler type")
	}
	if hh.client != client {
		t.Error("Client not set correctly")
	}
	if hh.analyzer != a {
		t.Error("Analyzer not set correctly")
	}
	if len(hh.monitoredChannels) != 2 {
		t.Errorf("Expected 2 monitored channels, got %d", len(hh.monitoredChannels))
	}
	if !hh.monitoredChannels["C123"] || !hh.monitoredChannels["C456"] {
		t.Error("Channels not added to map correctly")
	}
}

func TestNew_EmptyChannelsFailClosed(t *testing.T) {
	// Fail-closed: no channels and no explicit opt-in ⇒ monitor nothing.
	hh := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{}).(*handler)
	if hh.monitorAll {
		t.Error("Expected monitorAll to be false (fail-closed) when no channels are configured")
	}
	if len(hh.monitoredChannels) != 0 {
		t.Errorf("Expected empty channel map, got %d entries", len(hh.monitoredChannels))
	}
}

func TestNew_BlankChannelEntriesIgnored(t *testing.T) {
	hh := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{""}).(*handler)
	if hh.monitorAll {
		t.Error("Expected monitorAll to be false (fail-closed) when only blank channel entries are provided")
	}
	if len(hh.monitoredChannels) != 0 {
		t.Errorf("Expected empty channel map, got %d entries", len(hh.monitoredChannels))
	}
}

func TestWithMonitorAll(t *testing.T) {
	hh := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{}, WithMonitorAll(true)).(*handler)
	if !hh.monitorAll {
		t.Error("Expected monitorAll to be true when WithMonitorAll(true) is set")
	}
	// Explicitly disabling keeps the fail-closed default.
	hh = New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{}, WithMonitorAll(false)).(*handler)
	if hh.monitorAll {
		t.Error("Expected monitorAll to remain false when WithMonitorAll(false) is set")
	}
}

func TestHandle_MonitorAllAllowsUnlistedChannel(t *testing.T) {
	// With monitor-all opted in and no allow-list, a message in any channel is
	// handled (dispatched for analysis).
	client, _ := newMockSlack(true)
	h := New(client, successAnalyzer(), []string{}, WithMonitorAll(true))
	cb := msgCallback(&slackevents.MessageEvent{
		Channel:   "C-unlisted",
		TimeStamp: "123.456",
		Text:      "https://prow.ci.openshift.org/?pr=42",
	})
	handled, err := h.Handle(cb, slog.Default())
	if !handled || err != nil {
		t.Errorf("Expected the request to be handled, got handled=%v err=%v", handled, err)
	}
}

func TestNew_DedupTTLFromTimeout(t *testing.T) {
	t.Setenv("MCP_TIMEOUT_SECONDS", "1800")
	hh := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"}).(*handler)
	if want := 1800*time.Second + dedupGrace; hh.dedupTTL != want {
		t.Errorf("dedupTTL = %v, want %v", hh.dedupTTL, want)
	}
}

func TestNew_DedupTTLFollowsWithTimeoutOverride(t *testing.T) {
	// The suppression window follows WithTimeout rather than the shared env
	// default; this asserts its sizing formula, not total analysis duration.
	t.Setenv("MCP_TIMEOUT_SECONDS", "") // bare env would otherwise be DefaultMCPTimeout
	override := 3600 * time.Second
	a := analyzer.NewAnalyzer("", "", "", analyzer.WithTimeout(override))
	hh := New(&slack.Client{}, a, []string{"C123"}).(*handler)
	if want := override + dedupGrace; hh.dedupTTL != want {
		t.Errorf("dedupTTL = %v, want %v (must follow WithTimeout override, not MCP_TIMEOUT_SECONDS)", hh.dedupTTL, want)
	}
}

func TestNew_DedupTTLFloor(t *testing.T) {
	t.Setenv("MCP_TIMEOUT_SECONDS", "1")
	hh := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"}).(*handler)
	if hh.dedupTTL != minDedupTTL {
		t.Errorf("dedupTTL = %v, want floor %v", hh.dedupTTL, minDedupTTL)
	}
}

func TestIdentifier(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{})
	if h.Identifier() != "prow-analyzer" {
		t.Errorf("Expected identifier 'prow-analyzer', got %q", h.Identifier())
	}
}

func TestActorOf(t *testing.T) {
	tests := []struct {
		name string
		msg  *slackevents.MessageEvent
		want string
	}{
		{name: "human user", msg: &slackevents.MessageEvent{User: "U1"}, want: "U1"},
		{name: "bot username", msg: &slackevents.MessageEvent{Username: "chai-bot"}, want: "chai-bot"},
		{name: "bot id only", msg: &slackevents.MessageEvent{BotID: "B1"}, want: "B1"},
		{name: "user preferred over username", msg: &slackevents.MessageEvent{User: "U1", Username: "name"}, want: "U1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := actorOf(tt.msg); got != tt.want {
				t.Errorf("actorOf() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestExtractProwURL(t *testing.T) {
	t.Run("from text", func(t *testing.T) {
		msg := &slackevents.MessageEvent{Text: "see https://prow.ci.openshift.org/view/gs/test/job/1"}
		if got := extractProwURL(msg); got != "https://prow.ci.openshift.org/view/gs/test/job/1" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("from attachment", func(t *testing.T) {
		msg := &slackevents.MessageEvent{
			Text:        "Job failed :x:",
			Attachments: []slack.Attachment{{Text: "See https://prow.ci.openshift.org/view/gs/test/job/2 for details"}},
		}
		if got := extractProwURL(msg); got != "https://prow.ci.openshift.org/view/gs/test/job/2" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("none", func(t *testing.T) {
		msg := &slackevents.MessageEvent{Text: "no url here", Attachments: []slack.Attachment{{Text: "still none"}}}
		if got := extractProwURL(msg); got != "" {
			t.Errorf("expected empty, got %q", got)
		}
	})
}

func TestSeenRecently(t *testing.T) {
	h := &handler{dedupTTL: 10 * time.Minute, recentlySeen: make(map[string]time.Time)}

	if h.seenRecently("k1") {
		t.Error("First observation of a key must not be reported as seen")
	}
	if !h.seenRecently("k1") {
		t.Error("Second observation within TTL must be reported as seen")
	}
	// A stale entry must expire and be dropped.
	h.recentlySeen["k2"] = time.Now().Add(-2 * h.dedupTTL)
	if h.seenRecently("k2") {
		t.Error("An entry older than dedupTTL must not be reported as seen")
	}
}

func TestForget(t *testing.T) {
	h := &handler{recentlySeen: map[string]time.Time{"k": time.Now()}}
	h.forget("k")
	if _, ok := h.recentlySeen["k"]; ok {
		t.Error("Expected forget to remove the key")
	}
}

// --- Handle: early-return branches (no goroutine spawned) ---

func TestHandle_NotCallbackEvent(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	handled, err := h.Handle(&slackevents.EventsAPIEvent{Type: slackevents.URLVerification}, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_NotMessageEvent(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	cb := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.AppMention),
			Data: &slackevents.AppMentionEvent{},
		},
	}
	handled, err := h.Handle(cb, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_DeletedMessageIgnored(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	cb := msgCallback(&slackevents.MessageEvent{
		SubType:   "message_deleted",
		Channel:   "C123",
		TimeStamp: "123.456",
		Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
	})
	handled, err := h.Handle(cb, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_EditedMessageResolvedNoURL(t *testing.T) {
	// A message_changed event resolves the nested Message and inherits the outer
	// channel; with no Prow URL it must return unhandled — covering the resolve path
	// without spawning any analysis.
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	cb := msgCallback(&slackevents.MessageEvent{
		SubType: "message_changed",
		Channel: "C123",
		Message: &slackevents.MessageEvent{TimeStamp: "123.456", Text: "no prow url"},
	})
	handled, err := h.Handle(cb, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_NonAllowedBotMessageIgnored(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-chai"}))
	cb := msgCallback(&slackevents.MessageEvent{
		BotID:     "B-other",
		Channel:   "C123",
		TimeStamp: "123.456",
		Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
	})
	handled, err := h.Handle(cb, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_SelfBotMessageIgnored(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-self"}), WithSelfBotID("B-self"))
	cb := msgCallback(&slackevents.MessageEvent{
		BotID:     "B-self",
		Channel:   "C123",
		TimeStamp: "123.456",
		Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
	})
	handled, err := h.Handle(cb, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_UnmonitoredChannel(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	cb := msgCallback(&slackevents.MessageEvent{
		Channel: "C999",
		Text:    "https://prow.ci.openshift.org/view/gs/test/job/1",
	})
	handled, err := h.Handle(cb, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_NoProwURL(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	cb := msgCallback(&slackevents.MessageEvent{
		Channel: "C123",
		Text:    "Just a regular message without a Prow URL",
	})
	handled, err := h.Handle(cb, slog.Default())
	if handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_DuplicateSuppressed(t *testing.T) {
	// Pre-seed the dedup set so the request is recognized as a duplicate and
	// acknowledged (handled) without spawning a second analysis.
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"}).(*handler)
	url := "https://prow.ci.openshift.org/view/gs/test/job/1"
	h.recentlySeen["C123|"+url] = time.Now()

	cb := msgCallback(&slackevents.MessageEvent{Channel: "C123", TimeStamp: "1", Text: url})
	handled, err := h.Handle(cb, slog.Default())
	if !handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
}

func TestHandle_QueueFull(t *testing.T) {
	// Every concurrency slot taken: the request is acknowledged but dropped, the
	// user is told the queue is full, and the dedup mark is forgotten. A failing
	// Slack post also exercises the post-error branch.
	client, doer := newMockSlack(false)
	h := New(client, analyzer.NewAnalyzer("", "", ""), []string{"C123"}).(*handler)
	for i := 0; i < cap(h.semaphore); i++ {
		h.semaphore <- struct{}{}
	}

	url := "https://prow.ci.openshift.org/view/gs/test/job/1"
	cb := msgCallback(&slackevents.MessageEvent{Channel: "C123", TimeStamp: "123.456", Text: url})

	handled, err := h.Handle(cb, slog.Default())
	if !handled || err != nil {
		t.Errorf("handled=%v err=%v", handled, err)
	}
	texts := doer.captured()
	if len(texts) != 1 || !strings.Contains(texts[0], "queue is currently full") {
		t.Errorf("Expected a queue-full notice, got %v", texts)
	}
	h.mu.Lock()
	_, stillSeen := h.recentlySeen["C123|"+url]
	h.mu.Unlock()
	if stillSeen {
		t.Error("Expected the queue-full request to be forgotten from the dedup set")
	}
}

// Exercise async dispatch with in-memory transports; response branches are
// tested directly below.
func TestHandle_SpawnsAnalysis(t *testing.T) {
	client, _ := newMockSlack(true)
	h := New(client, successAnalyzer(), []string{"C123"})

	// A "?pr=" URL matches the extractor but has no derivable finished.json, so the
	// dispatched analysis needs no separate outcome probe.
	cb := msgCallback(&slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123.456",
		Text:      "https://prow.ci.openshift.org/?pr=12345",
	})
	handled, err := h.Handle(cb, slog.Default())
	if !handled || err != nil {
		t.Errorf("Expected the request to be handled, got handled=%v err=%v", handled, err)
	}
}

// --- analyzeAndRespond: every outcome/post branch, called directly ---

func newHandler(t *testing.T, a *analyzer.Analyzer, ok bool) (*handler, *mockSlackDoer) {
	t.Helper()
	client, doer := newMockSlack(ok)
	h := &handler{
		client:            client,
		analyzer:          a,
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 5),
	}
	h.semaphore <- struct{}{} // mimic Handle acquiring a slot before dispatch
	return h, doer
}

func TestAnalyzeAndRespond_PassingJobSkipped(t *testing.T) {
	h, doer := newHandler(t, passingJobAnalyzer(), true)
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "1"}
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/gs/bucket/job/1", slog.Default())

	texts := doer.captured()
	if len(texts) != 1 || !strings.Contains(texts[0], "no failure analysis needed") {
		t.Errorf("Expected a job-passed skip notice, got %v", texts)
	}
	if !strings.Contains(texts[0], analyzer.Disclaimer) {
		t.Errorf("Expected the skip notice to include the AI disclaimer, got %q", texts[0])
	}
}

func TestAnalyzeAndRespond_PassingJobPostError(t *testing.T) {
	h, _ := newHandler(t, passingJobAnalyzer(), false)
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "1"}
	// Must not panic even though the skip-notice post fails.
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/gs/bucket/job/1", slog.Default())
}

func TestAnalyzeAndRespond_AnalysisFailed(t *testing.T) {
	h, doer := newHandler(t, failingJobAnalyzer(), true)
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "1"}
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/gs/bucket/job/1", slog.Default())

	texts := doer.captured()
	if len(texts) != 1 || !strings.Contains(texts[0], "Analysis failed") {
		t.Errorf("Expected an analysis-failed notice, got %v", texts)
	}
}

func TestAnalyzeAndRespond_AnalysisFailedPostError(t *testing.T) {
	h, _ := newHandler(t, failingJobAnalyzer(), false)
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "1"}
	// Must not panic even though both the analysis and the Slack post fail.
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/gs/bucket/job/1", slog.Default())
}

func TestAnalyzeAndRespond_Success(t *testing.T) {
	h, doer := newHandler(t, successAnalyzer(), true)
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "1"}
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/?pr=1", slog.Default())

	texts := doer.captured()
	if len(texts) != 1 || !strings.Contains(texts[0], "Prow Analyzer Analysis") {
		t.Errorf("Expected an analysis result to be posted, got %v", texts)
	}
}

func TestAnalyzeAndRespond_SuccessPostError(t *testing.T) {
	h, _ := newHandler(t, successAnalyzer(), false)
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "1"}
	// Must not panic even though delivering the analysis fails (delivery_failed).
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/?pr=1", slog.Default())
}

// Interface compliance check.
var _ PartialHandler = (*handler)(nil)
