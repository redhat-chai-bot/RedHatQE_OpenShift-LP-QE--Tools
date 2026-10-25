package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/audit"
)

type failureAnalyzer interface {
	JobOutcomeFor(context.Context, string) analyzer.JobOutcome
	AnalyzeFailure(context.Context, string) (*analyzer.AnalysisResult, error)
}

var exit = os.Exit
var stdout io.Writer = os.Stdout
var stderr io.Writer = os.Stderr
var received = audit.Received
var outcome = audit.Outcome
var constructAnalyzer = analyzer.NewAnalyzer
var newAnalyzer = func(url, token, prompt string) failureAnalyzer {
	return constructAnalyzer(url, token, prompt)
}

func main() {
	var (
		mcpURL = flag.String("mcp-url", os.Getenv("SHIP_HELP_MCP_URL"), "Ship-help MCP URL")
		token  = flag.String("token", os.Getenv("SHIP_HELP_MCP_TOKEN"), "Ship-help MCP token")
		prompt = flag.String("prompt", "Analyze this Prow CI failure: {job_url}", "Analysis prompt template")
	)

	defaultUsage := flag.Usage
	flag.Usage = func() {
		defaultUsage()
		fmt.Fprintf(flag.CommandLine.Output(), "\n\nEnvironment variables:\n")
		fmt.Fprintf(flag.CommandLine.Output(), "  SHIP_HELP_MCP_URL    Ship-help MCP endpoint\n")
		fmt.Fprintf(flag.CommandLine.Output(), "  SHIP_HELP_MCP_TOKEN  Authentication token\n")
	}

	flag.CommandLine.SetOutput(stdout)
	flag.Parse()

	if len(flag.Args()) != 2 {
		flag.CommandLine.SetOutput(stderr)
		flag.Usage()
		exit(1)
	}

	var i int
	command := flag.Args()[i]
	i++
	jobURL := flag.Args()[i]
	i++

	if command != "analyze" {
		fmt.Fprintf(stderr, "Unknown command: %s\n", command)
		exit(1)
	}

	if *mcpURL == "" || *token == "" {
		fmt.Fprintf(stderr, "Error: Both --mcp-url and --token are required (or set SHIP_HELP_MCP_URL and SHIP_HELP_MCP_TOKEN)\n")
		exit(1)
	}

	a := newAnalyzer(*mcpURL, *token, *prompt)

	// Display the mandatory Red Hat AI agent notice and the persistent review
	// notice at the point of first interaction.
	fmt.Fprintf(stdout, "%s\n%s\n\n", analyzer.Disclaimer, analyzer.ReviewNotice)

	fmt.Fprintf(stdout, "🔍 Analyzing Prow failure...\n")
	fmt.Fprintf(stdout, "URL: %s\n\n", jobURL)

	// Establish a correlation ID and record the interaction trigger (audit 1/3).
	ctx := audit.WithInteractionID(context.Background(), "cli:"+jobURL)
	received(ctx, "cli", os.Getenv("USER"), "", jobURL)

	// Prow Analyzer only explains failures; skip jobs that passed.
	if a.JobOutcomeFor(ctx, jobURL) == analyzer.OutcomePassed {
		outcome(ctx, "skipped", "reason", "job_passing")
		fmt.Fprintf(stdout, "✅ This Prow job passed — no failure analysis needed.\n")
		return
	}

	result, err := a.AnalyzeFailure(ctx, jobURL)
	if err != nil {
		// Keep diagnostic strings out of audit records; operational stderr receives
		// the returned error, with HTTP/MCP backend payloads elided by the analyzer.
		outcome(ctx, "failed", "error", audit.RedactError(err))
		fmt.Fprintf(stderr, "Error: %v\n", err)
		exit(1)
	}
	// Audit the AI action / outcome (event 3/3): metadata only, not the content.
	outcome(ctx, "success",
		"duration_ms", result.Duration.Milliseconds(),
		"response_chars", len(result.Analysis),
		"response_sha256", audit.Hash(result.Analysis),
	)

	// Label the AI-generated content at the point of delivery (top and bottom).
	fmt.Fprintf(stdout, "%s — the following analysis is AI-generated:\n\n", analyzer.AILabel)
	fmt.Fprintf(stdout, "%s\n", result.Analysis)
	fmt.Fprintf(stdout, "\n---\n")
	fmt.Fprintf(stdout, "%s • Analysis completed in %.1fs\n", analyzer.AILabel, result.Duration.Seconds())
	// Re-display the notices alongside the output that must be reviewed before use.
	fmt.Fprintf(stdout, "\n%s\n%s\n", analyzer.ReviewNotice, analyzer.Disclaimer)
}
