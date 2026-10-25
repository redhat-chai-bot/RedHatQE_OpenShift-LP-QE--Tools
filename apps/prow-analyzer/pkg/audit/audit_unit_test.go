//go:build unit

package audit

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"
)

// captureAudit captures real audit JSON without changing the production API.
// It swaps the package logger and must not be used concurrently.
func captureAudit(fn func()) string {
	var buf bytes.Buffer
	saved := logger
	logger = slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo})).
		With("log_type", "audit", "component", "prow-analyzer")
	defer func() { logger = saved }()
	fn()
	return buf.String()
}

func TestWithInteractionID(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "C123/456.789")
	if got := InteractionID(ctx); got != "C123/456.789" {
		t.Errorf("InteractionID = %q, want %q", got, "C123/456.789")
	}
}

func TestInteractionID_Absent(t *testing.T) {
	if got := InteractionID(context.Background()); got != "" {
		t.Errorf("InteractionID on empty ctx = %q, want empty", got)
	}
}

func TestHash(t *testing.T) {
	a := Hash("some analysis text")
	b := Hash("some analysis text")
	c := Hash("different text")
	if a != b {
		t.Errorf("Hash not deterministic: %q vs %q", a, b)
	}
	if a == c {
		t.Error("Hash collision on different inputs")
	}
	if len(a) != 16 {
		t.Errorf("Hash length = %d, want 16", len(a))
	}
}

func TestRedactError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "nil", err: nil, want: ""},
		{name: "session not found", err: errors.New("MCP error: Session not found"), want: "session_not_found"},
		{name: "context deadline", err: context.DeadlineExceeded, want: "timeout"},
		{name: "client timeout", err: errors.New("send request: Client.Timeout exceeded"), want: "timeout"},
		{name: "generic timeout", err: errors.New("dial tcp: i/o timeout"), want: "timeout"},
		{name: "mcp protocol error", err: errors.New("MCP error 42: bad tool"), want: "mcp_protocol_error"},
		{name: "http error with body", err: errors.New("HTTP 500: <internal body>"), want: "mcp_http_error"},
		{name: "no content", err: errors.New("no content in response"), want: "empty_response"},
		{name: "no json data", err: errors.New("no JSON data found in SSE stream (read 3 lines)"), want: "empty_response"},
		{name: "fallback", err: errors.New("marshal request: boom"), want: "analysis_error"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := RedactError(tt.err); got != tt.want {
				t.Errorf("RedactError(%v) = %q, want %q", tt.err, got, tt.want)
			}
		})
	}
}

// Verify the emitted schema, not just the hash helper: raw actor identity must
// be absent while its fingerprint and interaction correlation remain available.
func TestReceived(t *testing.T) {
	// A distinctive raw value that cannot collide with a hex digest or any other
	// field, so a Contains check reliably detects a leak.
	const rawActor = "U_RAW_ACTOR_SECRET"
	ctx := WithInteractionID(context.Background(), "C1/123.45")

	out := captureAudit(func() {
		Received(ctx, "slack", rawActor, "C1", "https://prow.ci.openshift.org/view/x")
	})

	// The raw actor value must never appear anywhere in the emitted line.
	if strings.Contains(out, rawActor) {
		t.Errorf("raw actor value leaked into audit output:\n%s", out)
	}

	var fields map[string]any
	if err := json.Unmarshal([]byte(out), &fields); err != nil {
		t.Fatalf("audit line is not valid JSON: %v\n%s", err, out)
	}

	// The raw "actor" key must not be emitted — only the pseudonym.
	if _, present := fields["actor"]; present {
		t.Errorf("raw \"actor\" key present in audit output:\n%s", out)
	}

	// The pseudonym must equal the intended fingerprint of the raw actor.
	if got, want := fields["actor_sha256"], Hash(rawActor); got != want {
		t.Errorf("actor_sha256 = %v, want %q", got, want)
	}

	// Sanity: this is the received lifecycle event, correlated by interaction_id.
	if fields["event"] != "interaction_received" {
		t.Errorf("event = %v, want interaction_received", fields["event"])
	}
	if fields["interaction_id"] != "C1/123.45" {
		t.Errorf("interaction_id = %v, want C1/123.45", fields["interaction_id"])
	}
}

// TestReceived_EmptyActor asserts the documented empty-actor behavior on the real
// emitted line: actor_sha256 is the empty string (not a hash of ""), and the raw
// "actor" key is still absent.
func TestReceived_EmptyActor(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "cli:url")

	out := captureAudit(func() {
		Received(ctx, "cli", "", "", "https://prow.ci.openshift.org/view/x")
	})

	var fields map[string]any
	if err := json.Unmarshal([]byte(out), &fields); err != nil {
		t.Fatalf("audit line is not valid JSON: %v\n%s", err, out)
	}

	if _, present := fields["actor"]; present {
		t.Errorf("raw \"actor\" key present in audit output:\n%s", out)
	}

	got, ok := fields["actor_sha256"].(string)
	if !ok {
		t.Fatalf("actor_sha256 missing or not a string:\n%s", out)
	}
	if got != "" {
		t.Errorf("actor_sha256 = %q, want empty string for empty actor (not a hash of \"\")", got)
	}
}

func TestToolQuery(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "test-id")
	ToolQuery(ctx, "ship-help-mcp", "tools/call", "tool", "ask_persona", "persona", "ship_public")
}

func TestOutcome(t *testing.T) {
	ctx := WithInteractionID(context.Background(), "test-id")
	Outcome(ctx, "success", "duration_ms", int64(1234), "response_chars", 42)
}
