package analyzer

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

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
	if analyzer.client == nil {
		t.Error("Expected client to be initialized")
	}
	// Verify client is *http.Client with correct timeout
	httpClient, ok := analyzer.client.(*http.Client)
	if !ok {
		t.Error("Expected client to be *http.Client")
	} else if httpClient.Timeout != defaultMCPTimeout {
		t.Errorf("Expected timeout %v, got %v", defaultMCPTimeout, httpClient.Timeout)
	}
	// Verify injected functions
	if analyzer.jsonMarshal == nil {
		t.Error("Expected jsonMarshal to be initialized")
	}
	if analyzer.newRequest == nil {
		t.Error("Expected newRequest to be initialized")
	}
}

func TestMCPTimeout(t *testing.T) {
	tests := []struct {
		name string
		env  string
		set  bool
		want time.Duration
	}{
		{name: "unset uses default", set: false, want: defaultMCPTimeout},
		{name: "empty uses default", env: "", set: true, want: defaultMCPTimeout},
		{name: "valid override", env: "1800", set: true, want: 1800 * time.Second},
		{name: "non-numeric falls back", env: "abc", set: true, want: defaultMCPTimeout},
		{name: "zero falls back", env: "0", set: true, want: defaultMCPTimeout},
		{name: "negative falls back", env: "-5", set: true, want: defaultMCPTimeout},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.set {
				t.Setenv("MCP_TIMEOUT_SECONDS", tt.env)
			} else {
				os.Unsetenv("MCP_TIMEOUT_SECONDS")
			}
			if got := mcpTimeout(); got != tt.want {
				t.Errorf("mcpTimeout() = %v, want %v", got, tt.want)
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
		// The AI-generated label must appear at both the top and bottom of the output.
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
		expected  string
		expectErr bool
	}{
		{
			name:     "valid SSE",
			input:    "event: message\ndata: {\"result\":\"success\"}\n\n",
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
			result, err := readSSEData(strings.NewReader(tt.input))
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

func TestAnalyzeFailure_InitializeSession(t *testing.T) {
	sessionID := "test-session-123"
	analysisText := "Test analysis result"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("Expected POST, got %s", r.Method)
		}

		// Check authorization header
		authHeader := r.Header.Get("Authorization")
		if authHeader != "Bearer test-token" {
			t.Errorf("Expected Bearer token, got %s", authHeader)
		}

		// Parse request body
		var req MCPRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("Failed to decode request: %v", err)
		}

		// Handle initialize vs tools/call
		if req.Method == "initialize" {
			// Return session ID
			w.Header().Set("Mcp-Session-Id", sessionID)
			resp := MCPResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
			}
			json.NewEncoder(w).Encode(resp)
		} else if req.Method == "tools/call" {
			// Return analysis
			w.Header().Set("Content-Type", "text/event-stream")
			resp := MCPResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
			}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{
				{Type: "text", Text: analysisText},
			}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("event: message\ndata: " + string(jsonData) + "\n\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "test-token", "Analyze {job_url}")
	ctx := context.Background()

	result, err := analyzer.AnalyzeFailure(ctx, "https://prow.ci.openshift.org/view/test")
	if err != nil {
		t.Fatalf("AnalyzeFailure failed: %v", err)
	}

	if result.Analysis != analysisText {
		t.Errorf("Expected analysis %q, got %q", analysisText, result.Analysis)
	}
	if result.JobURL != "https://prow.ci.openshift.org/view/test" {
		t.Errorf("Expected job URL, got %q", result.JobURL)
	}
	if result.Duration == 0 {
		t.Error("Expected non-zero duration")
	}
}

func TestAnalyzeFailure_SessionReuse(t *testing.T) {
	callCount := 0
	sessionID := "reuse-session"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req MCPRequest
		json.NewDecoder(r.Body).Decode(&req)

		if req.Method == "initialize" {
			callCount++
			w.Header().Set("Mcp-Session-Id", sessionID)
			json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0", ID: req.ID})
		} else {
			resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{{Type: "text", Text: "analysis"}}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("data: " + string(jsonData) + "\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "token", "template")
	ctx := context.Background()

	// First call - should initialize
	_, err := analyzer.AnalyzeFailure(ctx, "url1")
	if err != nil {
		t.Fatalf("First AnalyzeFailure failed: %v", err)
	}

	// Second call - should reuse session
	_, err = analyzer.AnalyzeFailure(ctx, "url2")
	if err != nil {
		t.Fatalf("Second AnalyzeFailure failed: %v", err)
	}

	if callCount != 1 {
		t.Errorf("Expected 1 initialize call, got %d", callCount)
	}
}

func TestAnalyzeFailure_Errors(t *testing.T) {
	t.Run("initialize error - no session ID", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Don't set session ID header
			json.NewEncoder(w).Encode(MCPResponse{})
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no session ID") {
			t.Errorf("Expected session ID error, got: %v", err)
		}
	})

	t.Run("MCP error response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				resp := MCPResponse{
					JSONRPC: "2.0",
					ID:      req.ID,
					Error: &struct {
						Code    int    `json:"code"`
						Message string `json:"message"`
					}{Code: -32600, Message: "Invalid request"},
				}
				jsonData, _ := json.Marshal(resp)
				w.Write([]byte("data: " + string(jsonData) + "\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "MCP error") {
			t.Errorf("Expected MCP error, got: %v", err)
		}
	})

	t.Run("HTTP error status", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte("Server error"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "HTTP 500") {
			t.Errorf("Expected HTTP error, got: %v", err)
		}
	})

	t.Run("no content in response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
				// Empty content
				jsonData, _ := json.Marshal(resp)
				w.Write([]byte("data: " + string(jsonData) + "\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no content") {
			t.Errorf("Expected no content error, got: %v", err)
		}
	})

	t.Run("empty SSE response", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				// No SSE data line
				w.Write([]byte("event: message\n\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "no JSON data") {
			t.Errorf("Expected SSE parse error, got: %v", err)
		}
	})

	t.Run("context canceled", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(100 * time.Millisecond)
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		_, err := analyzer.AnalyzeFailure(ctx, "url")
		if err == nil {
			t.Error("Expected context canceled error")
		}
	})

	t.Run("invalid JSON in SSE", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var req MCPRequest
			json.NewDecoder(r.Body).Decode(&req)

			if req.Method == "initialize" {
				w.Header().Set("Mcp-Session-Id", "test")
				json.NewEncoder(w).Encode(MCPResponse{})
			} else {
				// Invalid JSON in data field
				w.Write([]byte("data: {invalid json\n"))
			}
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "parse response") {
			t.Errorf("Expected JSON parse error, got: %v", err)
		}
	})

	t.Run("init HTTP error 500", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte("Init failed"))
		}))
		defer server.Close()

		analyzer := NewAnalyzer(server.URL, "token", "template")
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")

		if err == nil || !strings.Contains(err.Error(), "init request failed") {
			t.Errorf("Expected init request failed error, got: %v", err)
		}
	})
}

// TestErrorInjection tests unreachable error paths using dependency injection
func TestErrorInjection(t *testing.T) {
	t.Run("json.Marshal error in AnalyzeFailure", func(t *testing.T) {
		// Mock client that succeeds for initialize
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				resp := &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
					Header:     make(http.Header),
				}
				resp.Header.Set("Mcp-Session-Id", "test-session")
				return resp, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized", // Pre-initialize to skip initializeSession
			jsonMarshal: mockJSONMarshalError,  // Inject failing marshaler
			newRequest:  http.NewRequestWithContext,
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "marshal request") {
			t.Errorf("Expected 'marshal request' error, got: %v", err)
		}
	})

	t.Run("http.NewRequestWithContext error in AnalyzeFailure", func(t *testing.T) {
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				resp := &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
					Header:     make(http.Header),
				}
				resp.Header.Set("Mcp-Session-Id", "test-session")
				return resp, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized", // Pre-initialize to skip initializeSession
			jsonMarshal: json.Marshal,
			newRequest:  mockNewRequestError, // Inject failing request builder
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "create request") {
			t.Errorf("Expected 'create request' error, got: %v", err)
		}
	})

	t.Run("json.Marshal error in initializeSession", func(t *testing.T) {
		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      &mockHTTPClient{},
			template:    "template",
			jsonMarshal: mockJSONMarshalError, // Inject failing marshaler
			newRequest:  http.NewRequestWithContext,
		}

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "marshal init request") {
			t.Errorf("Expected 'marshal init request' error, got: %v", err)
		}
	})

	t.Run("http.NewRequestWithContext error in initializeSession", func(t *testing.T) {
		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      &mockHTTPClient{},
			template:    "template",
			jsonMarshal: json.Marshal,
			newRequest:  mockNewRequestError, // Inject failing request builder
		}

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "create init request") {
			t.Errorf("Expected 'create init request' error, got: %v", err)
		}
	})

	t.Run("io.ReadAll error in AnalyzeFailure", func(t *testing.T) {
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: 200,
					Body:       &errorReader{}, // Body that fails on Read
					Header:     make(http.Header),
				}, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "read SSE stream") {
			t.Errorf("Expected 'read SSE stream' error, got: %v", err)
		}
	})

	t.Run("client.Do error in AnalyzeFailure", func(t *testing.T) {
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				return nil, errors.New("mock client.Do error")
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			sessionID:   "already-initialized",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}
		analyzer.initialized = true // Mark initialization as complete

		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "send request") {
			t.Errorf("Expected 'send request' error, got: %v", err)
		}
	})

	t.Run("stale session recovery on 404", func(t *testing.T) {
		initCount := 0
		callCount := 0
		analysisText := "recovered analysis"

		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				var mcpReq MCPRequest
				json.NewDecoder(req.Body).Decode(&mcpReq)

				if mcpReq.Method == "initialize" {
					initCount++
					resp := &http.Response{
						StatusCode: 200,
						Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
						Header:     make(http.Header),
					}
					resp.Header.Set("Mcp-Session-Id", "session-"+strings.Repeat("x", initCount))
					return resp, nil
				}

				callCount++
				if callCount == 1 {
					// First tools/call: simulate expired session
					body := `{"jsonrpc":"2.0","id":"server-error","error":{"code":-32600,"message":"Session not found"}}`
					return &http.Response{
						StatusCode: 404,
						Body:       io.NopCloser(strings.NewReader(body)),
						Header:     make(http.Header),
					}, nil
				}

				// Second tools/call: succeed with new session
				resp := MCPResponse{JSONRPC: "2.0", ID: 1}
				resp.Result.Content = []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				}{{Type: "text", Text: analysisText}}
				jsonData, _ := json.Marshal(resp)
				return &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader("data: " + string(jsonData) + "\n")),
					Header:     make(http.Header),
				}, nil
			},
		}

		a := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}

		result, err := a.AnalyzeFailure(context.Background(), "url")
		if err != nil {
			t.Fatalf("Expected successful retry, got error: %v", err)
		}
		if result.Analysis != analysisText {
			t.Errorf("Expected analysis %q, got %q", analysisText, result.Analysis)
		}
		if initCount != 2 {
			t.Errorf("Expected 2 initialize calls (original + recovery), got %d", initCount)
		}
		if callCount != 2 {
			t.Errorf("Expected 2 tools/call attempts, got %d", callCount)
		}
	})

	t.Run("initialization failure is retryable", func(t *testing.T) {
		callCount := 0
		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				callCount++
				if callCount == 1 {
					// First call fails
					return nil, errors.New("temporary network error")
				}
				// Second call succeeds
				resp := &http.Response{
					StatusCode: 200,
					Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
					Header:     make(http.Header),
				}
				resp.Header.Set("Mcp-Session-Id", "session-123")
				return resp, nil
			},
		}

		analyzer := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}

		// First call should fail
		_, err := analyzer.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "temporary network error") {
			t.Errorf("Expected temporary network error, got: %v", err)
		}

		// Second call should retry initialization (would be skipped if failure were cached)
		_, _ = analyzer.AnalyzeFailure(context.Background(), "url")
		if callCount < 2 {
			t.Errorf("Expected retry to trigger another HTTP call, got %d total calls", callCount)
		}
	})

	t.Run("io.ReadAll error in initializeSession", func(t *testing.T) {
		a := &Analyzer{
			mcpURL:   "http://test.com",
			token:    "token",
			template: "template",
			client: &mockHTTPClient{
				doFunc: func(req *http.Request) (*http.Response, error) {
					return &http.Response{
						StatusCode: 200,
						Body:       &errorReader{}, // Body that fails on Read
						Header:     make(http.Header),
					}, nil
				},
			},
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}

		err := a.initializeSession(context.Background())
		if err == nil || !strings.Contains(err.Error(), "read response") {
			t.Errorf("Expected 'read response' error, got: %v", err)
		}
	})

	t.Run("session re-init fails after expiry", func(t *testing.T) {
		initCount := 0

		mockClient := &mockHTTPClient{
			doFunc: func(req *http.Request) (*http.Response, error) {
				var mcpReq MCPRequest
				json.NewDecoder(req.Body).Decode(&mcpReq)

				if mcpReq.Method == "initialize" {
					initCount++
					if initCount == 1 {
						resp := &http.Response{
							StatusCode: 200,
							Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":0}`)),
							Header:     make(http.Header),
						}
						resp.Header.Set("Mcp-Session-Id", "session-1")
						return resp, nil
					}
					// Second init fails
					return nil, errors.New("network error on re-init")
				}

				// tools/call returns "Session not found" to trigger retry
				body := `{"jsonrpc":"2.0","id":"err","error":{"code":-32600,"message":"Session not found"}}`
				return &http.Response{
					StatusCode: 404,
					Body:       io.NopCloser(strings.NewReader(body)),
					Header:     make(http.Header),
				}, nil
			},
		}

		a := &Analyzer{
			mcpURL:      "http://test.com",
			token:       "token",
			client:      mockClient,
			template:    "template",
			jsonMarshal: json.Marshal,
			newRequest:  http.NewRequestWithContext,
		}

		_, err := a.AnalyzeFailure(context.Background(), "url")
		if err == nil || !strings.Contains(err.Error(), "initialize session") {
			t.Errorf("Expected 'initialize session' error, got: %v", err)
		}
	})
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
			name:     "PR dashboard URL has no derivable build",
			input:    "https://prow.ci.openshift.org/?pr=12345",
			expected: "",
		},
		{
			name:     "deck-internal view (not storage) has no derivable build",
			input:    "https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/view/job/123",
			expected: "",
		},
		{
			name:     "empty path after gs marker",
			input:    "https://prow.ci.openshift.org/view/gs/",
			expected: "",
		},
		{
			name:     "gcsweb-ci URL without view prefix",
			input:    "https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/bucket/logs/job/1",
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

	t.Run("FAILURE result without boolean is failed", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{"result":"FAILURE"}`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeFailed {
			t.Errorf("outcome = %v, want OutcomeFailed", got)
		}
	})

	t.Run("empty JSON returns unknown", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{}`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})

	t.Run("malformed JSON returns unknown", func(t *testing.T) {
		a := NewAnalyzer("mcp", "tok", "tmpl")
		a.client = &mockHTTPClient{doFunc: jsonResp(200, `{invalid`)}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})

	t.Run("newRequest error returns unknown", func(t *testing.T) {
		a := &Analyzer{
			mcpURL:      "mcp",
			token:       "tok",
			template:    "tmpl",
			client:      &mockHTTPClient{},
			jsonMarshal: json.Marshal,
			newRequest:  mockNewRequestError,
		}
		if got := a.JobOutcomeFor(context.Background(), viewURL); got != OutcomeUnknown {
			t.Errorf("outcome = %v, want OutcomeUnknown", got)
		}
	})
}

func TestPersonaFromURL(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want string
	}{
		{
			name: "standard persona URL with trailing path",
			url:  "https://ship-help.example.com/personas/ship_public/mcp",
			want: "ship_public",
		},
		{
			name: "no personas segment",
			url:  "https://example.com/api/mcp",
			want: "unknown",
		},
		{
			name: "empty persona after marker",
			url:  "https://example.com/personas/",
			want: "unknown",
		},
		{
			name: "persona without trailing path",
			url:  "https://example.com/personas/custom-persona",
			want: "custom-persona",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := personaFromURL(tt.url); got != tt.want {
				t.Errorf("personaFromURL(%q) = %q, want %q", tt.url, got, tt.want)
			}
		})
	}
}

func TestNewAnalyzer_TLSInsecureSkipVerify(t *testing.T) {
	t.Setenv("TLS_INSECURE_SKIP_VERIFY", "true")

	a := NewAnalyzer("https://example.com/mcp", "token", "template")

	httpClient, ok := a.client.(*http.Client)
	if !ok {
		t.Fatal("Expected client to be *http.Client")
	}
	transport, ok := httpClient.Transport.(*http.Transport)
	if !ok {
		t.Fatal("Expected transport to be *http.Transport when TLS_INSECURE_SKIP_VERIFY=true")
	}
	if transport.TLSClientConfig == nil || !transport.TLSClientConfig.InsecureSkipVerify {
		t.Error("Expected InsecureSkipVerify to be true")
	}
}
