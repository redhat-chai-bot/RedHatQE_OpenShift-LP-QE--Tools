//go:build unit

package analyzer

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// mcpDoer builds an in-memory HTTPDoer that answers MCP "initialize" with a
// session-id header and "tools/call" with the given SSE body. It lets the
// AnalyzeFailure path be exercised without a real HTTP server or goroutine.
func mcpDoer(sessionID, toolsCallSSE string) *mockHTTPClient {
	return &mockHTTPClient{doFunc: func(req *http.Request) (*http.Response, error) {
		var mcpReq MCPRequest
		json.NewDecoder(req.Body).Decode(&mcpReq)
		if mcpReq.Method == "initialize" {
			resp := &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
				Header:     make(http.Header),
			}
			resp.Header.Set("Mcp-Session-Id", sessionID)
			return resp, nil
		}
		return &http.Response{
			StatusCode: 200,
			Body:       io.NopCloser(strings.NewReader(toolsCallSSE)),
			Header:     make(http.Header),
		}, nil
	}}
}

// preInitAnalyzer returns an Analyzer whose session is already established, so a
// call to AnalyzeFailure goes straight to doAnalysis (skipping initialize).
func preInitAnalyzer(client HTTPDoer) *Analyzer {
	a := &Analyzer{
		mcpURL:      "http://test.com",
		token:       "token",
		client:      client,
		template:    "template",
		sessionID:   "already-initialized",
		jsonMarshal: json.Marshal,
		newRequest:  http.NewRequestWithContext,
	}
	a.initialized = true
	return a
}

func TestNewAnalyzer(t *testing.T) {
	mcpURL := "https://example.com/mcp"
	token := "test-token"
	template := "Analyze {job_url}"

	analyzer := NewAnalyzer(mcpURL, token, template)

	if analyzer.mcpURL != mcpURL {
		t.Errorf("Expected mcpURL %s, got %s", mcpURL, analyzer.mcpURL)
	}
	if analyzer.token != token {
		t.Errorf("Expected token %s, got %s", token, analyzer.token)
	}
	if analyzer.template != template {
		t.Errorf("Expected template %s, got %s", template, analyzer.template)
	}
	httpClient, ok := analyzer.client.(*http.Client)
	if !ok {
		t.Error("Expected client to be *http.Client")
	} else if httpClient.Timeout != DefaultMCPTimeout {
		t.Errorf("Expected timeout %v, got %v", DefaultMCPTimeout, httpClient.Timeout)
	}
	if analyzer.jsonMarshal == nil {
		t.Error("Expected jsonMarshal to be initialized")
	}
	if analyzer.newRequest == nil {
		t.Error("Expected newRequest to be initialized")
	}
}

func TestNewAnalyzer_TLSInsecure(t *testing.T) {
	t.Setenv("TLS_INSECURE_SKIP_VERIFY", "true")
	a := NewAnalyzer("url", "token", "template")

	httpClient, ok := a.client.(*http.Client)
	if !ok {
		t.Fatal("Expected client to be *http.Client")
	}
	if httpClient.Transport == nil {
		t.Error("Expected a custom Transport when TLS_INSECURE_SKIP_VERIFY=true")
	}
}

func TestNewAnalyzer_WithHTTPClient(t *testing.T) {
	stub := &mockHTTPClient{}
	a := NewAnalyzer("url", "token", "template", WithHTTPClient(stub))
	if a.client != stub {
		t.Error("Expected WithHTTPClient to override the analyzer's HTTP client")
	}
}

func TestNewAnalyzer_WithInsecureSkipVerify(t *testing.T) {
	t.Setenv("TLS_INSECURE_SKIP_VERIFY", "")
	a := NewAnalyzer("url", "token", "template", WithInsecureSkipVerify(true))

	httpClient, ok := a.client.(*http.Client)
	if !ok {
		t.Fatal("Expected client to be *http.Client")
	}
	if httpClient.Transport == nil {
		t.Error("Expected a custom Transport when WithInsecureSkipVerify(true) is set")
	}
}

func TestMCPTimeout(t *testing.T) {
	tests := []struct {
		name string
		env  string
		set  bool
		want time.Duration
	}{
		{name: "unset uses default", set: false, want: DefaultMCPTimeout},
		{name: "empty uses default", env: "", set: true, want: DefaultMCPTimeout},
		{name: "valid override", env: "1800", set: true, want: 1800 * time.Second},
		{name: "non-numeric falls back", env: "abc", set: true, want: DefaultMCPTimeout},
		{name: "zero falls back", env: "0", set: true, want: DefaultMCPTimeout},
		{name: "negative falls back", env: "-5", set: true, want: DefaultMCPTimeout},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.set {
				t.Setenv("MCP_TIMEOUT_SECONDS", tt.env)
			} else {
				os.Unsetenv("MCP_TIMEOUT_SECONDS")
			}
			if got := MCPTimeout(); got != tt.want {
				t.Errorf("MCPTimeout() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestExtractProwURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "plain URL",
			input:    "Check this: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
		},
		{
			name:     "Slack formatted URL",
			input:    "<https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456>",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456",
		},
		{
			name:     "URL with trailing punctuation",
			input:    "Failed: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789)",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789",
		},
		{
			name:     "Slack link with label",
			input:    "Check <https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/abc|this link>",
			expected: "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/abc",
		},
		{
			name:     "no URL",
			input:    "No Prow URL here",
			expected: "",
		},
		{
			name:     "deck-internal URL",
			input:    "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
			expected: "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
		},
		{
			name:     "prow PR URL",
			input:    "https://prow.ci.openshift.org/?pr=12345",
			expected: "https://prow.ci.openshift.org/?pr=12345",
		},
		{
			name:     "multiple trailing punctuation",
			input:    "URL: https://prow.ci.openshift.org/view/gs/test/job/1>.",
			expected: "https://prow.ci.openshift.org/view/gs/test/job/1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ExtractProwURL(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

func TestContainsProwURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected bool
	}{
		{
			name:     "contains URL",
			input:    "Check https://prow.ci.openshift.org/view/gs/test/job/1",
			expected: true,
		},
		{
			name:     "no URL",
			input:    "Just some text",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ContainsProwURL(tt.input)
			if result != tt.expected {
				t.Errorf("Expected %v, got %v", tt.expected, result)
			}
		})
	}
}

func TestFormatSlackResponse(t *testing.T) {
	t.Run("valid result", func(t *testing.T) {
		result := &AnalysisResult{
			JobURL:   "https://prow.ci.openshift.org/view/gs/test/job/1",
			Analysis: "Root cause: test failure",
			Duration: 78600 * time.Millisecond,
		}

		response := FormatSlackResponse(result)

		if !strings.Contains(response, "🔍 *Prow Analyzer Analysis*") {
			t.Error("Expected header in response")
		}
		if !strings.Contains(response, "Root cause: test failure") {
			t.Error("Expected analysis in response")
		}
		if !strings.Contains(response, "78.6s") {
			t.Error("Expected duration in response")
		}
		if !strings.Contains(response, "Powered by ship-help MCP") {
			t.Error("Expected footer in response")
		}
		if !strings.Contains(response, Disclaimer) {
			t.Error("Expected mandatory Red Hat AI agent disclaimer in response")
		}
		if strings.Count(response, AILabel) < 2 {
			t.Errorf("Expected AI-generated label at top and bottom of response, found %d occurrence(s)", strings.Count(response, AILabel))
		}
		if !strings.Contains(response, ReviewNotice) {
			t.Error("Expected persistent review notice in response")
		}
	})

	t.Run("nil result", func(t *testing.T) {
		response := FormatSlackResponse(nil)
		if !strings.Contains(response, "❌ Error") {
			t.Error("Expected error message for nil result")
		}
		if !strings.Contains(response, Disclaimer) {
			t.Error("Expected mandatory Red Hat AI agent disclaimer in nil-result response")
		}
	})
}

func TestReadSSEData(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		debug     bool
		expected  string
		expectErr bool
	}{
		{
			name:     "valid SSE",
			input:    "event: message\ndata: {\"result\":\"success\"}\n\n",
			expected: "{\"result\":\"success\"}",
		},
		{
			// debug=true exercises the verbose metadata-only logging branches for
			// all line kinds: ping (":"), non-data ("event:"), and data lines. None
			// log payload content.
			name:     "valid SSE with debug logging",
			input:    ": ping\nevent: message\ndata: {\"result\":\"success\"}\n\n",
			debug:    true,
			expected: "{\"result\":\"success\"}",
		},
		{
			name:      "no data line",
			input:     "event: message\n\n",
			expectErr: true,
		},
		{
			name:     "with ping comments",
			input:    ": ping - 2026-08-06\n: ping - 2026-08-06\ndata: {\"result\":\"ok\"}\n\n",
			expected: "{\"result\":\"ok\"}",
		},
		{
			name:     "non-JSON data returned",
			input:    "data: test\n\n",
			expected: "test",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := readSSEData(strings.NewReader(tt.input), tt.debug)
			if tt.expectErr {
				if err == nil {
					t.Errorf("Expected error, got result %q", result)
				}
				return
			}
			if err != nil {
				t.Errorf("Unexpected error: %v", err)
				return
			}
			if result != tt.expected {
				t.Errorf("Expected %q, got %q", tt.expected, result)
			}
		})
	}
}

// TestWithDebug verifies the WithDebug option toggles the analyzer's debug flag,
// overriding the default.
func TestWithDebug(t *testing.T) {
	a := NewAnalyzer("url", "token", "tmpl", WithDebug(true))
	if !a.debug {
		t.Error("Expected debug to be true after WithDebug(true)")
	}
}

// TestWithTimeout verifies the WithTimeout option overrides the default HTTP
// client timeout for a positive duration and is ignored for a non-positive one
// (leaving the MCPTimeout default in place).
func TestWithTimeout(t *testing.T) {
	a := NewAnalyzer("url", "token", "tmpl", WithTimeout(42*time.Second))
	httpClient, ok := a.client.(*http.Client)
	if !ok {
		t.Fatal("Expected client to be *http.Client")
	}
	if httpClient.Timeout != 42*time.Second {
		t.Errorf("Expected timeout 42s, got %v", httpClient.Timeout)
	}

	// A non-positive duration is ignored; the MCPTimeout default applies.
	t.Setenv("MCP_TIMEOUT_SECONDS", "")
	def := NewAnalyzer("url", "token", "tmpl", WithTimeout(0))
	defClient, ok := def.client.(*http.Client)
	if !ok {
		t.Fatal("Expected client to be *http.Client")
	}
	if defClient.Timeout != DefaultMCPTimeout {
		t.Errorf("Expected default timeout %v, got %v", DefaultMCPTimeout, defClient.Timeout)
	}
}

// TestAnalyzer_Timeout verifies the effective-timeout accessor: a positive
// WithTimeout override is returned directly, otherwise it falls back to the
// MCPTimeout default. Callers (e.g. the Slack handler's dedup window) rely on
// this to honor a per-instance override rather than the unprefixed env var.
func TestAnalyzer_Timeout(t *testing.T) {
	override := 90 * time.Second
	a := NewAnalyzer("url", "token", "tmpl", WithTimeout(override))
	if got := a.Timeout(); got != override {
		t.Errorf("Timeout() with override = %v, want %v", got, override)
	}

	t.Setenv("MCP_TIMEOUT_SECONDS", "")
	def := NewAnalyzer("url", "token", "tmpl")
	if got := def.Timeout(); got != DefaultMCPTimeout {
		t.Errorf("Timeout() without override = %v, want %v", got, DefaultMCPTimeout)
	}
}

// TestReadSSEData_ScannerError covers the scanner.Err() branch of readSSEData
// using a reader that always fails.
func TestReadSSEData_ScannerError(t *testing.T) {
	_, err := readSSEData(&errorReader{}, false)
	if err == nil || !strings.Contains(err.Error(), "reading stream") {
		t.Errorf("Expected 'reading stream' error, got: %v", err)
	}
}

func TestFinishedJSONURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "view/gs URL",
			input:    "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
			expected: "https://storage.googleapis.com/test-platform-results/logs/job/123/finished.json",
		},
		{
			name:     "legacy view/gcs URL",
			input:    "https://prow.ci.openshift.org/view/gcs/bucket/logs/job/9",
			expected: "https://storage.googleapis.com/bucket/logs/job/9/finished.json",
		},
		{
			name:     "trailing slash trimmed",
			input:    "https://prow.ci.openshift.org/view/gs/bucket/job/1/",
			expected: "https://storage.googleapis.com/bucket/job/1/finished.json",
		},
		{
			name:     "empty path after marker has no derivable build",
			input:    "https://prow.ci.openshift.org/view/gs/",
			expected: "",
		},
		{
			name:     "PR dashboard URL has no derivable build",
			input:    "https://prow.ci.openshift.org/?pr=12345",
			expected: "",
		},
		{
			name:     "deck-internal view (not storage) has no derivable build",
			input:    "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := finishedJSONURL(tt.input); got != tt.expected {
				t.Errorf("finishedJSONURL(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestJobOutcomeFor(t *testing.T) {
	const viewURL = "https://prow.ci.openshift.org/view/gs/bucket/logs/job/1"
	const wantFetch = "https://storage.googleapis.com/bucket/logs/job/1/finished.json"

	jsonResp := func(status int, body string) func(*http.Request) (*http.Response, error) {
		return func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: status,
				Body:       io.NopCloser(strings.NewReader(body)),
				Header:     make(http.Header),
			}, nil
		}
	}

	t.Run("passed via boolean derives correct finished.json URL", func(t *testing.T) {
		var gotURL string
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: func(req *http.Request) (*http.Response, error) {
			gotURL = req.URL.String()
			return jsonResp(200, `{"passed":true,"result":"SUCCESS"}`)(req)
		}}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomePassed {
			t.Errorf("outcome = %v, want OutcomePassed", got)
		}
		if gotURL != wantFetch {
			t.Errorf("fetched %q, want %q", gotURL, wantFetch)
		}
	})

	t.Run("result SUCCESS without boolean is passed", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{"result":"success"}`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomePassed {
			t.Errorf("outcome = %v, want OutcomePassed", got)
		}
	})

	t.Run("passed false is failed", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{"passed":false,"result":"FAILURE"}`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeFailed {
			t.Errorf("outcome = %v, want OutcomeFailed", got)
		}
	})

	t.Run("result FAILURE without boolean is failed", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{"result":"FAILURE"}`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeFailed {
			t.Errorf("outcome = %v, want OutcomeFailed", got)
		}
	})

	t.Run("empty finished.json is unknown", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{}`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})

	t.Run("undecodable body is unknown", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{not json`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})

	t.Run("request build error is unknown", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.newRequest = mockNewRequestError
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})

	t.Run("404 is unknown", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(404, `not found`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})

	t.Run("network error is unknown", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return nil, errors.New("boom")
		}}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})

	t.Run("non-view URL is unknown and makes no request", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		called := false
		a.client = &mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			called = true
			return jsonResp(200, `{"passed":true}`)(nil)
		}}
		if got := a.JobOutcomeFor(context.Background(), "https://prow.ci.openshift.org/?pr=1"); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
		if called {
			t.Error("expected no HTTP request for a non-view URL")
		}
	})
}

func TestPersonaFromURL(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want string
	}{
		{name: "no personas marker", url: "https://example.com/mcp", want: "unknown"},
		{name: "persona with trailing segment", url: "https://host/personas/ocp_ai_helpdesk/mcp", want: "ocp_ai_helpdesk"},
		{name: "persona without trailing slash", url: "https://host/personas/ship_public", want: "ship_public"},
		{name: "empty persona after marker", url: "https://host/personas/", want: "unknown"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := personaFromURL(tt.url); got != tt.want {
				t.Errorf("personaFromURL(%q) = %q, want %q", tt.url, got, tt.want)
			}
		})
	}
}

// TestAnalyzeFailure covers the AnalyzeFailure / ensureSession / initializeSession
// / doAnalysis paths entirely through an in-memory HTTPDoer (no real server, no
// goroutine), driving each success and error branch directly.
func TestAnalyzeFailure(t *testing.T) {
	// --- doAnalysis error branches (session pre-established) ---

	t.Run("marshal request error", func(t *testing.T) {
		a := preInitAnalyzer(&mockHTTPClient{})
		a.jsonMarshal = mockJSONMarshalError
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "marshal request") {
			t.Errorf("Expected 'marshal request' error, got: %v", err)
		}
	})

	t.Run("create request error", func(t *testing.T) {
		a := preInitAnalyzer(&mockHTTPClient{})
		a.newRequest = mockNewRequestError
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "create request") {
			t.Errorf("Expected 'create request' error, got: %v", err)
		}
	})

	t.Run("send request error", func(t *testing.T) {
		a := preInitAnalyzer(&mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return nil, errors.New("mock client.Do error")
		}})
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "send request") {
			t.Errorf("Expected 'send request' error, got: %v", err)
		}
	})

	t.Run("read SSE stream error", func(t *testing.T) {
		a := preInitAnalyzer(&mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: &errorReader{}, Header: make(http.Header)}, nil
		}})
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "read SSE stream") {
			t.Errorf("Expected 'read SSE stream' error, got: %v", err)
		}
	})

	t.Run("HTTP non-200 (not session-not-found) surfaces without retry", func(t *testing.T) {
		a := preInitAnalyzer(&mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: 500,
				Body:       io.NopCloser(strings.NewReader("boom")),
				Header:     make(http.Header),
			}, nil
		}})
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
			t.Errorf("Expected 'HTTP 500' error, got: %v", err)
		}
	})

	t.Run("empty SSE (no data line)", func(t *testing.T) {
		a := preInitAnalyzer(&mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader("event: message\n\n")),
				Header:     make(http.Header),
			}, nil
		}})
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "no JSON data") {
			t.Errorf("Expected 'no JSON data' error, got: %v", err)
		}
	})

	t.Run("invalid JSON in SSE", func(t *testing.T) {
		a := preInitAnalyzer(&mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader("data: {invalid json\n")),
				Header:     make(http.Header),
			}, nil
		}})
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "parse response") {
			t.Errorf("Expected 'parse response' error, got: %v", err)
		}
	})

	t.Run("MCP error response", func(t *testing.T) {
		sse := `data: {"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid request"}}` + "\n"
		a := preInitAnalyzer(&mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader(sse)),
				Header:     make(http.Header),
			}, nil
		}})
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "MCP error") {
			t.Errorf("Expected 'MCP error', got: %v", err)
		}
	})

	t.Run("no content in response", func(t *testing.T) {
		sse := `data: {"jsonrpc":"2.0","id":1}` + "\n"
		a := preInitAnalyzer(&mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader(sse)),
				Header:     make(http.Header),
			}, nil
		}})
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "no content") {
			t.Errorf("Expected 'no content' error, got: %v", err)
		}
	})

	// --- initializeSession error branches (fresh, uninitialized analyzer) ---

	t.Run("marshal init request error", func(t *testing.T) {
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: &mockHTTPClient{},
			template: "template", jsonMarshal: mockJSONMarshalError, newRequest: http.NewRequestWithContext,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "marshal init request") {
			t.Errorf("Expected 'marshal init request' error, got: %v", err)
		}
	})

	t.Run("create init request error", func(t *testing.T) {
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: &mockHTTPClient{},
			template: "template", jsonMarshal: json.Marshal, newRequest: mockNewRequestError,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "create init request") {
			t.Errorf("Expected 'create init request' error, got: %v", err)
		}
	})

	t.Run("send init request error", func(t *testing.T) {
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token",
			client:   &mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) { return nil, errors.New("neterr") }},
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "initialize session") {
			t.Errorf("Expected 'initialize session' error, got: %v", err)
		}
	})

	t.Run("init read body error", func(t *testing.T) {
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token",
			client: &mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 200, Body: &errorReader{}, Header: make(http.Header)}, nil
			}},
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "read response") {
			t.Errorf("Expected 'read response' error, got: %v", err)
		}
	})

	t.Run("init non-200 status", func(t *testing.T) {
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token",
			client: &mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: 500,
					Body:       io.NopCloser(strings.NewReader("nope")),
					Header:     make(http.Header),
				}, nil
			}},
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "init request failed") {
			t.Errorf("Expected 'init request failed' error, got: %v", err)
		}
	})

	t.Run("init returns no session ID", func(t *testing.T) {
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token",
			client: &mockHTTPClient{doFunc: func(*http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader(`{}`)),
					Header:     make(http.Header),
				}, nil
			}},
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "no session ID") {
			t.Errorf("Expected 'no session ID' error, got: %v", err)
		}
	})

	// --- success and session-reuse ---

	t.Run("success then session reuse", func(t *testing.T) {
		initCount := 0
		client := &mockHTTPClient{doFunc: func(req *http.Request) (*http.Response, error) {
			var mcpReq MCPRequest
			json.NewDecoder(req.Body).Decode(&mcpReq)
			if mcpReq.Method == "initialize" {
				initCount++
				resp := &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}
				resp.Header.Set("Mcp-Session-Id", "sid")
				return resp, nil
			}
			sse := `data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"analysis"}]}}` + "\n"
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(sse)), Header: make(http.Header)}, nil
		}}
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: client,
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		r1, err := a.AnalyzeFailure(context.Background(), "url1")
		if err != nil {
			t.Fatalf("first AnalyzeFailure: %v", err)
		}
		if r1.Analysis != "analysis" {
			t.Errorf("Analysis = %q, want %q", r1.Analysis, "analysis")
		}
		if r1.JobURL != "url1" || r1.Duration == 0 {
			t.Errorf("unexpected result: %+v", r1)
		}
		if _, err := a.AnalyzeFailure(context.Background(), "url2"); err != nil {
			t.Fatalf("second AnalyzeFailure: %v", err)
		}
		if initCount != 1 {
			t.Errorf("Expected 1 initialize call (session reused), got %d", initCount)
		}
	})

	t.Run("stale session recovery on 404", func(t *testing.T) {
		initCount, callCount := 0, 0
		client := &mockHTTPClient{doFunc: func(req *http.Request) (*http.Response, error) {
			var mcpReq MCPRequest
			json.NewDecoder(req.Body).Decode(&mcpReq)
			if mcpReq.Method == "initialize" {
				initCount++
				resp := &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}
				resp.Header.Set("Mcp-Session-Id", "session-"+strings.Repeat("x", initCount))
				return resp, nil
			}
			callCount++
			if callCount == 1 {
				return &http.Response{
					StatusCode: 404,
					Body:       io.NopCloser(strings.NewReader(`{"error":{"message":"Session not found"}}`)),
					Header:     make(http.Header),
				}, nil
			}
			sse := `data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"recovered"}]}}` + "\n"
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(sse)), Header: make(http.Header)}, nil
		}}
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: client,
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		result, err := a.AnalyzeFailure(context.Background(), "url")
		if err != nil {
			t.Fatalf("Expected successful retry, got: %v", err)
		}
		if result.Analysis != "recovered" {
			t.Errorf("Analysis = %q, want %q", result.Analysis, "recovered")
		}
		if initCount != 2 || callCount != 2 {
			t.Errorf("Expected 2 init + 2 tools/call, got %d + %d", initCount, callCount)
		}
	})

	t.Run("stale session recovery via MCP error message", func(t *testing.T) {
		initCount, callCount := 0, 0
		client := &mockHTTPClient{doFunc: func(req *http.Request) (*http.Response, error) {
			var mcpReq MCPRequest
			json.NewDecoder(req.Body).Decode(&mcpReq)
			if mcpReq.Method == "initialize" {
				initCount++
				resp := &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}
				resp.Header.Set("Mcp-Session-Id", "session-"+strings.Repeat("y", initCount))
				return resp, nil
			}
			callCount++
			if callCount == 1 {
				// HTTP 200, but the MCP payload reports the session is gone — this
				// drives the MCP-error session-not-found branch (distinct from the 404
				// HTTP-body path above).
				sse := `data: {"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Session not found"}}` + "\n"
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(sse)), Header: make(http.Header)}, nil
			}
			sse := `data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"recovered-via-mcp"}]}}` + "\n"
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(sse)), Header: make(http.Header)}, nil
		}}
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: client,
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		result, err := a.AnalyzeFailure(context.Background(), "url")
		if err != nil {
			t.Fatalf("Expected successful retry via MCP session recovery, got: %v", err)
		}
		if result.Analysis != "recovered-via-mcp" {
			t.Errorf("Analysis = %q, want %q", result.Analysis, "recovered-via-mcp")
		}
		if initCount != 2 || callCount != 2 {
			t.Errorf("Expected 2 init + 2 tools/call, got %d + %d", initCount, callCount)
		}
	})

	t.Run("re-init fails after session expired", func(t *testing.T) {
		initCount := 0
		client := &mockHTTPClient{doFunc: func(req *http.Request) (*http.Response, error) {
			var mcpReq MCPRequest
			json.NewDecoder(req.Body).Decode(&mcpReq)
			if mcpReq.Method == "initialize" {
				initCount++
				if initCount == 1 {
					resp := &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}
					resp.Header.Set("Mcp-Session-Id", "session-1")
					return resp, nil
				}
				return nil, errors.New("reinit network error")
			}
			return &http.Response{
				StatusCode: 404,
				Body:       io.NopCloser(strings.NewReader("Session not found")),
				Header:     make(http.Header),
			}, nil
		}}
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: client,
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "reinit network error") {
			t.Errorf("Expected re-init error to surface, got: %v", err)
		}
		if initCount != 2 {
			t.Errorf("Expected 2 initialize attempts, got %d", initCount)
		}
	})

	t.Run("initialization failure is retryable", func(t *testing.T) {
		callCount := 0
		client := &mockHTTPClient{doFunc: func(req *http.Request) (*http.Response, error) {
			callCount++
			if callCount == 1 {
				return nil, errors.New("temporary network error")
			}
			resp := &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: make(http.Header)}
			resp.Header.Set("Mcp-Session-Id", "session-123")
			return resp, nil
		}}
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: client,
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "temporary network error") {
			t.Errorf("Expected temporary network error, got: %v", err)
		}
		_, _ = a.AnalyzeFailure(context.Background(), "url")
		if callCount < 2 {
			t.Errorf("Expected retry to trigger another HTTP call, got %d total calls", callCount)
		}
	})

	t.Run("success via mcpDoer helper", func(t *testing.T) {
		sse := `data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}` + "\n"
		a := &Analyzer{
			mcpURL: "http://test.com", token: "token", client: mcpDoer("sid", sse),
			template: "template", jsonMarshal: json.Marshal, newRequest: http.NewRequestWithContext,
		}
		r, err := a.AnalyzeFailure(context.Background(), "url")
		if err != nil || r.Analysis != "ok" {
			t.Fatalf("unexpected: r=%+v err=%v", r, err)
		}
	})
}
