package handler

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

// mockSlackClient implements a mock Slack client for testing
type mockSlackClient struct {
	postedMessages []mockPostedMessage
}

type mockPostedMessage struct {
	channel string
	options []slack.MsgOption
}

func (m *mockSlackClient) PostMessage(channel string, options ...slack.MsgOption) (string, string, error) {
	m.postedMessages = append(m.postedMessages, mockPostedMessage{
		channel: channel,
		options: options,
	})
	return "ts123", "ch123", nil
}

// mockAnalyzer implements a mock analyzer for testing
type mockAnalyzer struct {
	shouldFail bool
	delay      time.Duration
}

func (m *mockAnalyzer) AnalyzeFailure(ctx context.Context, jobURL string) (*analyzer.AnalysisResult, error) {
	if m.delay > 0 {
		time.Sleep(m.delay)
	}
	if m.shouldFail {
		return nil, context.DeadlineExceeded
	}
	return &analyzer.AnalysisResult{
		JobURL:   jobURL,
		Analysis: "Test analysis result",
		Duration: 78 * time.Second,
	}, nil
}

func TestNew(t *testing.T) {
	client := &slack.Client{}
	analyzer := analyzer.NewAnalyzer("url", "token", "template")
	channels := []string{"C123", "C456"}

	h := New(client, analyzer, channels)

	if h == nil {
		t.Fatal("Expected non-nil handler")
	}

	handler, ok := h.(*handler)
	if !ok {
		t.Fatal("Expected handler type")
	}

	if handler.client != client {
		t.Error("Client not set correctly")
	}
	if handler.analyzer != analyzer {
		t.Error("Analyzer not set correctly")
	}
	if len(handler.monitoredChannels) != 2 {
		t.Errorf("Expected 2 monitored channels, got %d", len(handler.monitoredChannels))
	}
	if !handler.monitoredChannels["C123"] || !handler.monitoredChannels["C456"] {
		t.Error("Channels not added to map correctly")
	}
}

func TestNew_EmptyChannelsMonitorsAll(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{})

	handler, ok := h.(*handler)
	if !ok {
		t.Fatal("Expected handler type")
	}
	if !handler.monitorAll {
		t.Error("Expected monitorAll to be true when no channels are configured")
	}
	if len(handler.monitoredChannels) != 0 {
		t.Errorf("Expected empty channel map, got %d entries", len(handler.monitoredChannels))
	}
}

func TestNew_BlankChannelEntriesIgnored(t *testing.T) {
	// A stray empty entry (e.g. from a trailing comma) must not be treated as an
	// explicit allowlist, otherwise monitorAll would be disabled unexpectedly.
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{""})

	handler, ok := h.(*handler)
	if !ok {
		t.Fatal("Expected handler type")
	}
	if !handler.monitorAll {
		t.Error("Expected monitorAll to be true when only blank channel entries are provided")
	}
}

func TestHandle_MonitorAllChannels(t *testing.T) {
	// With no configured channels, a Prow URL in ANY channel should be handled.
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))
	h := New(slackClient, analyzer.NewAnalyzer("", "", ""), []string{})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel:   "C-never-configured",
				TimeStamp: "123.456",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if !handled {
		t.Error("Expected event in unconfigured channel to be handled when monitorAll is enabled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestIdentifier(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{})

	if h.Identifier() != "prow-analyzer" {
		t.Errorf("Expected identifier 'prow-analyzer', got %q", h.Identifier())
	}
}

func TestHandle_NotCallbackEvent(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.URLVerification,
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected event not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_NotMessageEvent(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.AppMention),
			Data: &slackevents.AppMentionEvent{},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected event not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_BotMessage(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				BotID: "B123",
				Text:  "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected bot message not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_UnmonitoredChannel(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel: "C999", // Not monitored
				Text:    "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected unmonitored channel not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_NoProwURL(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel: "C123",
				Text:    "Just a regular message without a Prow URL",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected message without Prow URL not to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_Success(t *testing.T) {
	// Create a mock Slack server that accepts posts
	messageChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			messageChan <- true
		}
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))
	h := New(slackClient, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel:   "C123",
				TimeStamp: "123.456",
				Text:      "Check this: https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if !handled {
		t.Error("Expected event to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}

	// Wait for error message to be posted (analyzer will fail but should post error)
	select {
	case <-messageChan:
		// Success - error message was posted
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for error message to be posted to Slack")
	}
}

// TestAnalyzeAndRespond_WithMockServer tests the async path with a real HTTP server
func TestAnalyzeAndRespond_WithMockServer(t *testing.T) {
	// Create mock MCP server
	sessionID := "test-session"
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", sessionID)
			w.Write([]byte(`{"jsonrpc":"2.0","id":0}`))
		} else {
			resp := `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Analysis result"}]}}`
			w.Write([]byte("data: " + resp + "\n"))
		}
	}))
	defer mcpServer.Close()

	// Create mock Slack server
	messageChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			messageChan <- true
			w.Write([]byte(`{"ok":true,"ts":"123"}`))
		}
	}))
	defer slackServer.Close()

	// Create Slack client pointing to mock server
	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))

	// Create analyzer pointing to mock MCP server
	anal := analyzer.NewAnalyzer(mcpServer.URL, "test-token", "template")

	h := &handler{
		client:            slackClient,
		analyzer:          anal,
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 5),
	}

	event := &slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123.456",
	}

	logger := slog.Default()

	// Acquire semaphore before calling analyzeAndRespond (mimics Handle behavior)
	h.semaphore <- struct{}{}
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/test", logger)

	// Wait for message to be posted (with timeout)
	select {
	case <-messageChan:
		// Success - message was posted
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for Slack message to be posted")
	}
}

// TestAnalyzeAndRespond_PostError tests error path when posting fails
func TestAnalyzeAndRespond_PostError(t *testing.T) {
	// Create mock MCP server
	mcpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
		}
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", "test")
			w.Write([]byte(`{"jsonrpc":"2.0","id":0}`))
		} else {
			resp := `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Analysis"}]}}`
			w.Write([]byte("data: " + resp + "\n"))
		}
	}))
	defer mcpServer.Close()

	// Create Slack server that returns errors
	postAttemptChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			postAttemptChan <- true
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte(`{"ok":false,"error":"posting_error"}`))
		}
	}))
	defer slackServer.Close()

	slackClient := slack.New("test", slack.OptionAPIURL(slackServer.URL+"/"))
	anal := analyzer.NewAnalyzer(mcpServer.URL, "token", "template")

	h := &handler{
		client:            slackClient,
		analyzer:          anal,
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 5),
	}

	event := &slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123",
	}

	logger := slog.Default()

	// Acquire semaphore before calling analyzeAndRespond (mimics Handle behavior)
	h.semaphore <- struct{}{}
	// Should not panic, just log error
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/test", logger)

	// Wait for post attempt (with timeout)
	select {
	case <-postAttemptChan:
		// Success - posting was attempted (though it failed as expected)
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for Slack post attempt")
	}
}

// newSlackTestServer returns a Slack client wired to a test server that accepts
// any API call (used for handled=true paths where an async post is attempted).
func newSlackTestServer(t *testing.T) *slack.Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	t.Cleanup(srv.Close)
	return slack.New("test-token", slack.OptionAPIURL(srv.URL+"/"))
}

func TestHandle_AllowedBotMessage(t *testing.T) {
	// A Prow URL posted by an allow-listed bot should be handled.
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-chai"}))
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				BotID:     "B-chai",
				Channel:   "C123",
				TimeStamp: "123.456",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if !handled {
		t.Error("Expected allow-listed bot message to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_NonAllowedBotMessageIgnored(t *testing.T) {
	// A bot that is not on the allow-list must still be ignored, even when other
	// bots are allow-listed.
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-chai"}))
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				BotID:     "B-other",
				Channel:   "C123",
				TimeStamp: "123.456",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected non-allow-listed bot message to be ignored")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_SelfBotMessageIgnored(t *testing.T) {
	// The bot's own posts must never be analyzed, even if its ID is (mistakenly)
	// on the allow-list — this prevents an analysis loop.
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-self"}), WithSelfBotID("B-self"))
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				BotID:     "B-self",
				Channel:   "C123",
				TimeStamp: "123.456",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected the bot's own message to be ignored")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_ProwURLInAttachment(t *testing.T) {
	// Bots like chai-bot put the Prow URL in an attachment, not the message body.
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-chai"}))
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				BotID:     "B-chai",
				Channel:   "C123",
				TimeStamp: "123.456",
				Text:      "Job failed :x:",
				Attachments: []slack.Attachment{
					{Text: "See https://prow.ci.openshift.org/view/gs/test/job/1 for details"},
				},
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if !handled {
		t.Error("Expected a Prow URL in an attachment to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_DuplicateSuppressed(t *testing.T) {
	// The same (channel, URL) delivered twice (e.g. a Slack retry) must trigger
	// only one analysis; the second is acknowledged (handled) but suppressed.
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	newCallback := func(ts string) *slackevents.EventsAPIEvent {
		return &slackevents.EventsAPIEvent{
			Type: slackevents.CallbackEvent,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Type: string(slackevents.Message),
				Data: &slackevents.MessageEvent{
					Channel:   "C123",
					TimeStamp: ts,
					Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
				},
			},
		}
	}

	if handled, err := h.Handle(newCallback("111.111"), logger); !handled || err != nil {
		t.Fatalf("first delivery: handled=%v err=%v", handled, err)
	}
	// Second delivery of the same URL (different timestamp) should be suppressed.
	if handled, err := h.Handle(newCallback("222.222"), logger); !handled || err != nil {
		t.Fatalf("second delivery: handled=%v err=%v", handled, err)
	}

	hh := h.(*handler)
	hh.mu.Lock()
	seen := len(hh.recentlySeen)
	hh.mu.Unlock()
	if seen != 1 {
		t.Errorf("Expected exactly 1 deduplicated entry, got %d", seen)
	}
}

func TestHandle_DeletedMessageIgnored(t *testing.T) {
	h := New(&slack.Client{}, analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				SubType:   "message_deleted",
				Channel:   "C123",
				TimeStamp: "123.456",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if handled {
		t.Error("Expected a deleted message to be ignored")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_EditedMessageResolved(t *testing.T) {
	// An edit (message_changed) carries the real content in the nested Message and
	// the channel only on the outer event; the URL must still be found and handled.
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"})
	logger := slog.Default()

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				SubType: "message_changed",
				Channel: "C123",
				Message: &slackevents.MessageEvent{
					TimeStamp: "123.456",
					Text:      "https://prow.ci.openshift.org/view/gs/test/job/1",
				},
			},
		},
	}

	handled, err := h.Handle(callback, logger)

	if !handled {
		t.Error("Expected an edited message with a Prow URL to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestSeenRecently(t *testing.T) {
	h := &handler{recentlySeen: make(map[string]time.Time)}

	if h.seenRecently("k1") {
		t.Error("First observation of a key must not be reported as seen")
	}
	if !h.seenRecently("k1") {
		t.Error("Second observation within TTL must be reported as seen")
	}

	// A stale entry must expire and be dropped.
	h.recentlySeen["k2"] = time.Now().Add(-2 * dedupTTL)
	if h.seenRecently("k2") {
		t.Error("An entry older than dedupTTL must not be reported as seen")
	}
}

// httpDoerMock implements analyzer.HTTPDoer for handler tests.
type httpDoerMock struct {
	doFunc func(req *http.Request) (*http.Response, error)
}

func (m *httpDoerMock) Do(req *http.Request) (*http.Response, error) {
	return m.doFunc(req)
}

// overrideAnalyzerClient sets the unexported client field on an analyzer.Analyzer
// using reflect+unsafe. This is a standard Go testing pattern for accessing
// unexported fields in cross-package tests without modifying production code.
func overrideAnalyzerClient(t *testing.T, a *analyzer.Analyzer, mock *httpDoerMock) {
	t.Helper()
	v := reflect.ValueOf(a).Elem()
	f := v.FieldByName("client")
	reflect.NewAt(f.Type(), unsafe.Pointer(f.UnsafeAddr())).Elem().Set(reflect.ValueOf(mock))
}

func TestActorOf(t *testing.T) {
	tests := []struct {
		name string
		msg  *slackevents.MessageEvent
		want string
	}{
		{
			name: "human user",
			msg:  &slackevents.MessageEvent{User: "U123"},
			want: "U123",
		},
		{
			name: "bot with username",
			msg:  &slackevents.MessageEvent{Username: "chai-bot"},
			want: "chai-bot",
		},
		{
			name: "bot with ID only",
			msg:  &slackevents.MessageEvent{BotID: "B456"},
			want: "B456",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := actorOf(tt.msg); got != tt.want {
				t.Errorf("actorOf() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHandle_QueueFull(t *testing.T) {
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))

	h := &handler{
		client:            slackClient,
		analyzer:          analyzer.NewAnalyzer("", "", ""),
		monitoredChannels: map[string]bool{"C123": true},
		allowedBotIDs:     make(map[string]bool),
		semaphore:         make(chan struct{}, 1),
		recentlySeen:      make(map[string]time.Time),
	}
	h.semaphore <- struct{}{} // Fill the semaphore

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel:   "C123",
				TimeStamp: "900.001",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/900",
			},
		},
	}

	handled, err := h.Handle(callback, slog.Default())

	if !handled {
		t.Error("Expected event to be handled even when queue is full")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}

	<-h.semaphore // Release
}

func TestHandle_QueueFull_PostError(t *testing.T) {
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":false,"error":"test_error"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))

	h := &handler{
		client:            slackClient,
		analyzer:          analyzer.NewAnalyzer("", "", ""),
		monitoredChannels: map[string]bool{"C123": true},
		allowedBotIDs:     make(map[string]bool),
		semaphore:         make(chan struct{}, 1),
		recentlySeen:      make(map[string]time.Time),
	}
	h.semaphore <- struct{}{} // Fill the semaphore

	callback := &slackevents.EventsAPIEvent{
		Type: slackevents.CallbackEvent,
		InnerEvent: slackevents.EventsAPIInnerEvent{
			Type: string(slackevents.Message),
			Data: &slackevents.MessageEvent{
				Channel:   "C123",
				TimeStamp: "901.001",
				Text:      "https://prow.ci.openshift.org/view/gs/test/job/901",
			},
		},
	}

	handled, err := h.Handle(callback, slog.Default())

	if !handled {
		t.Error("Expected event to be handled even when queue is full and post fails")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}

	<-h.semaphore // Release
}

func TestAnalyzeAndRespond_JobPassed(t *testing.T) {
	postChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			postChan <- true
		}
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))

	anal := analyzer.NewAnalyzer("http://mcp-unused", "token", "template")
	overrideAnalyzerClient(t, anal, &httpDoerMock{
		doFunc: func(req *http.Request) (*http.Response, error) {
			// Return "passed: true" for any request (the finished.json fetch)
			return &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader(`{"passed":true}`)),
				Header:     make(http.Header),
			}, nil
		},
	})

	h := &handler{
		client:       slackClient,
		analyzer:     anal,
		semaphore:    make(chan struct{}, 5),
		recentlySeen: make(map[string]time.Time),
	}

	event := &slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123.456",
	}

	h.semaphore <- struct{}{} // Pre-acquire semaphore (mimics Handle behavior)
	h.analyzeAndRespond(context.Background(), event,
		"https://prow.ci.openshift.org/view/gs/bucket/job/1", slog.Default())

	select {
	case <-postChan:
		// Success — "job passed" skip notice was posted
	case <-time.After(2 * time.Second):
		t.Error("Expected 'job passed' skip notice to be posted")
	}
}

func TestAnalyzeAndRespond_JobPassed_PostError(t *testing.T) {
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":false,"error":"channel_not_found"}`))
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))

	anal := analyzer.NewAnalyzer("http://mcp-unused", "token", "template")
	overrideAnalyzerClient(t, anal, &httpDoerMock{
		doFunc: func(req *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader(`{"passed":true}`)),
				Header:     make(http.Header),
			}, nil
		},
	})

	h := &handler{
		client:       slackClient,
		analyzer:     anal,
		semaphore:    make(chan struct{}, 5),
		recentlySeen: make(map[string]time.Time),
	}

	event := &slackevents.MessageEvent{
		Channel:   "C123",
		TimeStamp: "123.789",
	}

	h.semaphore <- struct{}{} // Pre-acquire semaphore
	// Should not panic — just logs the post error
	h.analyzeAndRespond(context.Background(), event,
		"https://prow.ci.openshift.org/view/gs/bucket/job/2", slog.Default())
}

// Interface compliance check
var _ PartialHandler = (*handler)(nil)
