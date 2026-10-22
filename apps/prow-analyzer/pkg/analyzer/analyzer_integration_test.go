//go:build integration

package analyzer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// Real HTTP test servers exercise MCP session setup, headers, and SSE responses.

func TestAnalyzeFailure_InitializeSession(t *testing.T) {
	sessionID := "test-session-123"
	analysisText := "Test analysis result"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("Expected POST, got %s", r.Method)
		}
		authHeader := r.Header.Get("Authorization")
		if authHeader != "Bearer test-token" {
			t.Errorf("Expected Bearer token, got %s", authHeader)
		}

		var req MCPRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("Failed to decode request: %v", err)
		}

		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", sessionID)
			json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0", ID: req.ID})
		} else if req.Method == "tools/call" {
			w.Header().Set("Content-Type", "text/event-stream")
			resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
			resp.Result.Content = []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{{Type: "text", Text: analysisText}}
			jsonData, _ := json.Marshal(resp)
			w.Write([]byte("event: message\ndata: " + string(jsonData) + "\n\n"))
		}
	}))
	defer server.Close()

	analyzer := NewAnalyzer(server.URL, "test-token", "Analyze {job_url}")
	result, err := analyzer.AnalyzeFailure(context.Background(), "https://prow.ci.openshift.org/view/test")
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
	if _, err := analyzer.AnalyzeFailure(context.Background(), "url1"); err != nil {
		t.Fatalf("First AnalyzeFailure failed: %v", err)
	}
	if _, err := analyzer.AnalyzeFailure(context.Background(), "url2"); err != nil {
		t.Fatalf("Second AnalyzeFailure failed: %v", err)
	}
	if callCount != 1 {
		t.Errorf("Expected 1 initialize call, got %d", callCount)
	}
}

func TestAnalyzeFailure_Errors(t *testing.T) {
	t.Run("initialize error - no session ID", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		cancel()
		if _, err := analyzer.AnalyzeFailure(ctx, "url"); err == nil {
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

// Distinct IDs let the shared backend session distinguish concurrent requests.
func TestNextID_ConcurrentUniqueness(t *testing.T) {
	a := NewAnalyzer("url", "token", "template")

	const goroutines = 64
	const perGoroutine = 200
	ids := make([]int64, goroutines*perGoroutine)

	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(base int) {
			defer wg.Done()
			for i := 0; i < perGoroutine; i++ {
				ids[base+i] = a.nextID.Add(1) // distinct index per goroutine: race-free write
			}
		}(g * perGoroutine)
	}
	wg.Wait()

	seen := make(map[int64]struct{}, len(ids))
	for _, id := range ids {
		if _, dup := seen[id]; dup {
			t.Fatalf("duplicate JSON-RPC id %d handed out under concurrency", id)
		}
		seen[id] = struct{}{}
	}
	if len(seen) != len(ids) {
		t.Fatalf("got %d unique ids, want %d", len(seen), len(ids))
	}
}

// Caller-chosen job URLs verify response delivery independently of request-ID
// allocation. Request-ID uniqueness remains a separate shared-session invariant.
func TestAnalyzeFailure_ConcurrentCallerMarkerCorrelation(t *testing.T) {
	const callers = 32

	var mu sync.Mutex
	toolCallIDs := make(map[int]int) // JSON-RPC id -> times seen (uniqueness invariant)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID     int    `json:"id"`
			Method string `json:"method"`
			Params struct {
				Arguments struct {
					Question string `json:"question"`
				} `json:"arguments"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", "marker-session")
			json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0", ID: req.ID})
			return
		}
		// tools/call: record the id for the separate uniqueness invariant, and echo
		// the caller-supplied marker (its job URL, carried in the prompt) back in the
		// response content so delivery is verified independently of the id.
		mu.Lock()
		toolCallIDs[req.ID]++
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
		resp.Result.Content = []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}{{Type: "text", Text: "echo:" + req.Params.Arguments.Question}}
		data, _ := json.Marshal(resp)
		w.Write([]byte("event: message\ndata: " + string(data) + "\n\n"))
	}))
	defer server.Close()

	// The template places the caller's distinct job URL into the prompt the server
	// receives, giving each caller a unique, self-chosen marker.
	a := NewAnalyzer(server.URL, "token", "Analyze {job_url}")

	markers := make([]string, callers)
	results := make([]string, callers)
	errs := make([]error, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		markers[i] = fmt.Sprintf("https://prow.ci.openshift.org/view/caller-%d", i)
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			res, err := a.AnalyzeFailure(context.Background(), markers[idx])
			if err != nil {
				errs[idx] = err
				return
			}
			results[idx] = res.Analysis
		}(i)
	}
	wg.Wait()

	// Primary invariant: each caller received the response carrying its OWN marker.
	for i := range results {
		if errs[i] != nil {
			t.Errorf("caller %d failed: %v", i, errs[i])
			continue
		}
		want := "echo:Analyze " + markers[i]
		if results[i] != want {
			t.Errorf("caller %d got %q, want %q (cross-delivery, duplication, or loss)", i, results[i], want)
		}
	}

	// Separate invariant: every tools/call id the server saw was unique and there
	// was exactly one per caller — no two concurrent requests shared an id.
	for id, n := range toolCallIDs {
		if n != 1 {
			t.Errorf("server saw tools/call id %d %d times, want exactly 1", id, n)
		}
	}
	if len(toolCallIDs) != callers {
		t.Fatalf("server saw %d distinct tools/call ids, want %d", len(toolCallIDs), callers)
	}
}

// The client associates responses by HTTP round-trip, not by validating their
// JSON-RPC IDs. Keep this contract explicit alongside request-ID uniqueness.
func TestAnalyzeFailure_MismatchedResponseID(t *testing.T) {
	const wrongID = 999999

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req MCPRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		if req.Method == "initialize" {
			w.Header().Set("Mcp-Session-Id", "mismatch-session")
			// Even the initialize response carries a deliberately mismatched id.
			json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0", ID: wrongID})
			return
		}
		if req.ID == wrongID {
			t.Fatalf("request id unexpectedly equal to the deliberate wrong id %d", wrongID)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		resp := MCPResponse{JSONRPC: "2.0", ID: wrongID} // deliberately != req.ID
		resp.Result.Content = []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}{{Type: "text", Text: "analysis despite mismatched id"}}
		data, _ := json.Marshal(resp)
		w.Write([]byte("event: message\ndata: " + string(data) + "\n\n"))
	}))
	defer server.Close()

	a := NewAnalyzer(server.URL, "token", "Analyze {job_url}")
	res, err := a.AnalyzeFailure(context.Background(), "https://prow.ci.openshift.org/view/test")
	if err != nil {
		t.Fatalf("AnalyzeFailure failed on mismatched response id: %v", err)
	}
	if res.Analysis != "analysis despite mismatched id" {
		t.Errorf("got %q, want the echoed analysis (response accepted despite id mismatch)", res.Analysis)
	}
}

// Sentinels in backend errors must reach neither returned diagnostics nor
// operational stdout; audit categorization alone does not protect that boundary.
func TestAnalyzeFailure_ErrorsArePayloadFree(t *testing.T) {
	const httpSentinel = "SENSITIVE-HTTP-BODY-a1b2c3d4"
	const mcpSentinel = "SENSITIVE-MCP-MESSAGE-e5f6a7b8"

	initOK := func(w http.ResponseWriter) {
		w.Header().Set("Mcp-Session-Id", "payload-free-session")
		json.NewEncoder(w).Encode(MCPResponse{JSONRPC: "2.0"})
	}

	cases := []struct {
		name    string
		handler http.HandlerFunc
	}{
		{
			name: "tools/call HTTP error body",
			handler: func(w http.ResponseWriter, r *http.Request) {
				var req MCPRequest
				json.NewDecoder(r.Body).Decode(&req)
				if req.Method == "initialize" {
					initOK(w)
					return
				}
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte(httpSentinel))
			},
		},
		{
			name: "MCP protocol error message",
			handler: func(w http.ResponseWriter, r *http.Request) {
				var req MCPRequest
				json.NewDecoder(r.Body).Decode(&req)
				if req.Method == "initialize" {
					initOK(w)
					return
				}
				resp := MCPResponse{JSONRPC: "2.0", ID: req.ID}
				resp.Error = &struct {
					Code    int    `json:"code"`
					Message string `json:"message"`
				}{Code: -32000, Message: mcpSentinel}
				data, _ := json.Marshal(resp)
				w.Header().Set("Content-Type", "text/event-stream")
				w.Write([]byte("event: message\ndata: " + string(data) + "\n\n"))
			},
		},
		{
			name: "initialize HTTP error body",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte(httpSentinel))
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(tc.handler)
			defer server.Close()

			var analyzeErr error
			stdout := captureStdout(t, func() {
				a := NewAnalyzer(server.URL, "token", "Analyze {job_url}")
				_, analyzeErr = a.AnalyzeFailure(context.Background(), "https://prow.ci.openshift.org/view/test")
			})

			if analyzeErr == nil {
				t.Fatal("expected a failure, got nil error")
			}
			for _, sentinel := range []string{httpSentinel, mcpSentinel} {
				if strings.Contains(analyzeErr.Error(), sentinel) {
					t.Errorf("returned error leaked sentinel %q: %v", sentinel, analyzeErr)
				}
				if strings.Contains(stdout, sentinel) {
					t.Errorf("operational stdout leaked sentinel %q; captured output:\n%s", sentinel, stdout)
				}
			}
		})
	}
}

// captureStdout redirects os.Stdout for the duration of fn and returns everything
// written to it. The analyzer logs operational metadata via fmt.Print* (stdout),
// so this lets a test assert on that output. Not safe for parallel use.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		io.Copy(&buf, r)
		done <- buf.String()
	}()

	fn()

	w.Close()
	os.Stdout = orig
	out := <-done
	r.Close()
	return out
}
