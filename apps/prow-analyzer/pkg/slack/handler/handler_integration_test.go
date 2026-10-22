//go:build integration

package handler

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

// Real HTTP test servers exercise async Slack handling and MCP analysis.

// newCapturingSlackServer returns a Slack client whose posted message texts are
// recorded. When ok is false, chat.postMessage returns an error so the caller's
// post-error path is exercised.
func newCapturingSlackServer(t *testing.T, ok bool) (*slack.Client, *[]string) {
	t.Helper()
	var mu sync.Mutex
	texts := &[]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			_ = r.ParseForm()
			mu.Lock()
			*texts = append(*texts, r.FormValue("text"))
			mu.Unlock()
			if !ok {
				w.Write([]byte(`{"ok":false,"error":"posting_error"}`))
				return
			}
		}
		w.Write([]byte(`{"ok":true,"ts":"123"}`))
	}))
	t.Cleanup(srv.Close)
	return slack.New("test-token", slack.OptionAPIURL(srv.URL+"/")), texts
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

func TestHandle_MonitorAllChannels(t *testing.T) {
	// monitor-all is now an explicit opt-in (fail-closed by default), so enable it.
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{}, WithMonitorAll(true))
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
	handled, err := h.Handle(callback, slog.Default())
	if !handled {
		t.Error("Expected event in unconfigured channel to be handled when monitorAll is enabled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_Success(t *testing.T) {
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
	handled, err := h.Handle(callback, slog.Default())
	if !handled {
		t.Error("Expected event to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
	select {
	case <-messageChan:
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for error message to be posted to Slack")
	}
}

func TestHandle_AllowedBotMessage(t *testing.T) {
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-chai"}))
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
	handled, err := h.Handle(callback, slog.Default())
	if !handled {
		t.Error("Expected allow-listed bot message to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_ProwURLInAttachment(t *testing.T) {
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"},
		WithAllowedBotIDs([]string{"B-chai"}))
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
	handled, err := h.Handle(callback, slog.Default())
	if !handled {
		t.Error("Expected a Prow URL in an attachment to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

func TestHandle_DuplicateSuppressed(t *testing.T) {
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"})
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
	if handled, err := h.Handle(newCallback("111.111"), slog.Default()); !handled || err != nil {
		t.Fatalf("first delivery: handled=%v err=%v", handled, err)
	}
	if handled, err := h.Handle(newCallback("222.222"), slog.Default()); !handled || err != nil {
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

func TestHandle_EditedMessageResolved(t *testing.T) {
	h := New(newSlackTestServer(t), analyzer.NewAnalyzer("", "", ""), []string{"C123"})
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
	handled, err := h.Handle(callback, slog.Default())
	if !handled {
		t.Error("Expected an edited message with a Prow URL to be handled")
	}
	if err != nil {
		t.Errorf("Expected no error, got %v", err)
	}
}

// TestAnalyzeAndRespond_WithMockServer exercises MCP analysis and Slack posting
// by invoking the response worker directly against real HTTP test servers.
func TestAnalyzeAndRespond_WithMockServer(t *testing.T) {
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

	messageChan := make(chan bool, 1)
	slackServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/chat.postMessage" {
			messageChan <- true
			w.Write([]byte(`{"ok":true,"ts":"123"}`))
		}
	}))
	defer slackServer.Close()

	slackClient := slack.New("test-token", slack.OptionAPIURL(slackServer.URL+"/"))
	anal := analyzer.NewAnalyzer(mcpServer.URL, "test-token", "template")
	h := &handler{
		client:            slackClient,
		analyzer:          anal,
		monitoredChannels: map[string]bool{"C123": true},
		semaphore:         make(chan struct{}, 5),
	}
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "123.456"}

	h.semaphore <- struct{}{}
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/test", slog.Default())

	select {
	case <-messageChan:
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for Slack message to be posted")
	}
}

// TestAnalyzeAndRespond_PostError tests the error path when posting fails.
func TestAnalyzeAndRespond_PostError(t *testing.T) {
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
	event := &slackevents.MessageEvent{Channel: "C123", TimeStamp: "123"}

	h.semaphore <- struct{}{}
	h.analyzeAndRespond(context.Background(), event, "https://prow.ci.openshift.org/view/test", slog.Default())

	select {
	case <-postAttemptChan:
	case <-time.After(2 * time.Second):
		t.Error("Timeout waiting for Slack post attempt")
	}
}

// Interface compliance check.
var _ PartialHandler = (*handler)(nil)
