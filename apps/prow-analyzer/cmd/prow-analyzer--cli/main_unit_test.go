//go:build unit

package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/audit"
)

type stubAnalyzer struct {
	outcome  analyzer.JobOutcome
	result   *analyzer.AnalysisResult
	err      error
	calls    []string
	contexts []context.Context
}

func (stub *stubAnalyzer) JobOutcomeFor(ctx context.Context, jobURL string) analyzer.JobOutcome {
	stub.calls = append(stub.calls, "outcome:"+jobURL)
	stub.contexts = append(stub.contexts, ctx)
	return stub.outcome
}

func (stub *stubAnalyzer) AnalyzeFailure(ctx context.Context, jobURL string) (*analyzer.AnalysisResult, error) {
	stub.calls = append(stub.calls, "analysis:"+jobURL)
	stub.contexts = append(stub.contexts, ctx)
	return stub.result, stub.err
}

type cliExit int

func TestMain(t *testing.T) {
	for _, testCase := range []struct {
		name           string
		args           []string
		url, token     string
		outcome        analyzer.JobOutcome
		err            error
		status         int
		stdout, stderr string
		calls          int
		auditStatus    string
	}{
		{name: "usage", stderr: "  -mcp-url string\n    \tShip-help MCP URL\n  -prompt string\n    \tAnalysis prompt template (default \"Analyze this Prow CI failure: {job_url}\")\n  -token string\n    \tShip-help MCP token\n\n\nEnvironment variables:\n  SHIP_HELP_MCP_URL    Ship-help MCP endpoint\n  SHIP_HELP_MCP_TOKEN  Authentication token\n", status: 1},
		{name: "unknown command", args: []string{"unknown", "job"}, stderr: "Unknown command: unknown\n", status: 1},
		{name: "missing URL", args: []string{"analyze", "job"}, token: "token", stderr: "Error: Both --mcp-url and --token are required (or set SHIP_HELP_MCP_URL and SHIP_HELP_MCP_TOKEN)\n", status: 1},
		{name: "missing token", args: []string{"analyze", "job"}, url: "url", stderr: "Error: Both --mcp-url and --token are required (or set SHIP_HELP_MCP_URL and SHIP_HELP_MCP_TOKEN)\n", status: 1},
		{name: "passing job", args: []string{"analyze", "job"}, url: "url", token: "token", outcome: analyzer.OutcomePassed, stdout: "✅ This Prow job passed — no failure analysis needed.\n", calls: 1, auditStatus: "skipped"},
		{name: "analysis error", args: []string{"analyze", "job"}, url: "url", token: "token", err: errors.New("redacted backend failure"), stderr: "Error: redacted backend failure\n", status: 1, calls: 2, auditStatus: "failed"},
		{name: "analysis success", args: []string{"analyze", "job"}, url: "url", token: "token", calls: 2, auditStatus: "success"},
		{name: "flags override env", args: []string{"-mcp-url", "url", "-token", "token", "-prompt", "custom {job_url}", "analyze", "job"}, url: "env-url", token: "env-token", calls: 2, auditStatus: "success"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Setenv("SHIP_HELP_MCP_URL", testCase.url)
			t.Setenv("SHIP_HELP_MCP_TOKEN", testCase.token)
			t.Setenv("USER", "unit-user")
			oldFlags, oldUsage, oldArgs := flag.CommandLine, flag.Usage, os.Args
			oldFactory, oldExit := newAnalyzer, exit
			oldStdout, oldStderr := stdout, stderr
			oldReceived, oldOutcome := received, outcome
			t.Cleanup(func() {
				flag.CommandLine, flag.Usage, os.Args = oldFlags, oldUsage, oldArgs
				newAnalyzer, exit = oldFactory, oldExit
				stdout, stderr = oldStdout, oldStderr
				received, outcome = oldReceived, oldOutcome
			})
			flag.CommandLine = flag.NewFlagSet("cli", flag.ContinueOnError)
			flag.Usage = func() { flag.CommandLine.PrintDefaults() }
			os.Args = append([]string{"cli"}, testCase.args...)
			var output, errorOutput bytes.Buffer
			stdout, stderr = &output, &errorOutput
			auditCalls := []string{}
			var interactionContext context.Context
			received = func(ctx context.Context, source, actor, channel, trigger string) {
				interactionContext = ctx
				if audit.InteractionID(ctx) != "cli:job" || source != "cli" || actor != "unit-user" || channel != "" || trigger != "job" {
					t.Error("received audit contract changed")
				}
				auditCalls = append(auditCalls, "received")
			}
			outcome = func(ctx context.Context, status string, attrs ...any) {
				if ctx != interactionContext || audit.InteractionID(ctx) != "cli:job" {
					t.Error("outcome correlation changed")
				}
				auditCalls = append(auditCalls, status)
				var wantAttrs []any
				switch testCase.auditStatus {
				case "failed":
					wantAttrs = []any{"error", audit.RedactError(testCase.err)}
				case "success":
					wantAttrs = []any{"duration_ms", int64(1500), "response_chars", len("test analysis"), "response_sha256", audit.Hash("test analysis")}
				case "skipped":
					wantAttrs = []any{"reason", "job_passing"}
				}
				if status != testCase.auditStatus || !reflect.DeepEqual(attrs, wantAttrs) {
					t.Errorf("outcome = %q %v, want %q %v", status, attrs, testCase.auditStatus, wantAttrs)
				}
			}
			stub := &stubAnalyzer{outcome: testCase.outcome, err: testCase.err, result: &analyzer.AnalysisResult{Analysis: "test analysis", Duration: 1500 * time.Millisecond}}
			factoryCalls := 0
			newAnalyzer = func(url, token, prompt string) failureAnalyzer {
				factoryCalls++
				if url != "url" || token != "token" {
					t.Errorf("constructor credentials = %q %q", url, token)
				}
				wantPrompt := "Analyze this Prow CI failure: {job_url}"
				if testCase.name == "flags override env" {
					wantPrompt = "custom {job_url}"
				}
				if prompt != wantPrompt {
					t.Errorf("prompt = %q", prompt)
				}
				return stub
			}
			exit = func(status int) { panic(cliExit(status)) }
			status := 0
			func() {
				defer func() {
					if recovered := recover(); recovered != nil {
						value, ok := recovered.(cliExit)
						if !ok {
							panic(recovered)
						}
						status = int(value)
					}
				}()
				main()
			}()
			if status != testCase.status {
				t.Errorf("status = %d, want %d", status, testCase.status)
			}
			wantOutput := testCase.stdout
			if testCase.calls > 0 {
				wantOutput = fmt.Sprintf("%s\n%s\n\n🔍 Analyzing Prow failure...\nURL: job\n\n", analyzer.Disclaimer, analyzer.ReviewNotice) + wantOutput
			}
			if testCase.auditStatus == "success" {
				wantOutput += fmt.Sprintf("%s — the following analysis is AI-generated:\n\ntest analysis\n\n---\n%s • Analysis completed in 1.5s\n\n%s\n%s\n", analyzer.AILabel, analyzer.AILabel, analyzer.ReviewNotice, analyzer.Disclaimer)
			}
			if output.String() != wantOutput || errorOutput.String() != testCase.stderr {
				t.Errorf("stdout=%q stderr=%q, want stdout=%q stderr=%q", output.String(), errorOutput.String(), wantOutput, testCase.stderr)
			}
			if len(stub.calls) != testCase.calls {
				t.Errorf("boundary calls = %v", stub.calls)
			}
			if testCase.calls == 0 && factoryCalls != 0 {
				t.Error("constructed analyzer before validation")
			}
			wantAuditCalls := []string{}
			if testCase.calls > 0 {
				wantAuditCalls = []string{"received", testCase.auditStatus}
			}
			if !reflect.DeepEqual(auditCalls, wantAuditCalls) {
				t.Errorf("audit calls=%v", auditCalls)
			}
			if testCase.calls > 0 {
				if factoryCalls != 1 || stub.calls[0] != "outcome:job" {
					t.Errorf("factory=%d calls=%v", factoryCalls, stub.calls)
				}
			}
			var wantCalls []string
			if testCase.calls > 0 {
				wantCalls = append(wantCalls, "outcome:job")
			}
			if testCase.calls == 2 {
				wantCalls = append(wantCalls, "analysis:job")
			}
			if !reflect.DeepEqual(stub.calls, wantCalls) {
				t.Errorf("operations = %v, want %v", stub.calls, wantCalls)
			}
			for _, ctx := range stub.contexts {
				if ctx != interactionContext || audit.InteractionID(ctx) != "cli:job" {
					t.Error("analyzer operation context changed")
				}
			}
		})
	}
}

func TestNewAnalyzer(t *testing.T) {
	oldConstructor := constructAnalyzer
	t.Cleanup(func() { constructAnalyzer = oldConstructor })
	want := &analyzer.Analyzer{}
	constructAnalyzer = func(url, token, prompt string, opts ...analyzer.AnalyzerOption) *analyzer.Analyzer {
		if url != "https://example.invalid/mcp" || token != "token" || prompt != "prompt" || len(opts) != 0 {
			t.Error("constructor adapter arguments changed")
		}
		return want
	}
	client := newAnalyzer("https://example.invalid/mcp", "token", "prompt")
	if client != want {
		t.Fatalf("constructor result %T", client)
	}
}
