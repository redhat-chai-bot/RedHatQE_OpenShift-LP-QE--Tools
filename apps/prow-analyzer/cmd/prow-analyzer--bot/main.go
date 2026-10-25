package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"

	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
	"github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/slack/handler"
)

// envBool reads a boolean environment variable, returning def when the variable
// is unset, empty, or not a valid boolean (as understood by strconv.ParseBool).
func envBool(key string, def bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return def
}

// envInt reads an integer environment variable, returning def when the variable
// is unset, empty, or not a valid integer (as understood by strconv.Atoi).
func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// envStr reads a string environment variable, returning def when it is unset or
// empty.
func envStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// defaultPrompt is the fallback for --prompt / PROW_AN__PROMPT__TEMPLATE.
// The analyzer substitutes the Prow URL for "{job_url}".
const defaultPrompt = "Analyze this Prow CI failure in detail. Provide: (1) Root cause, (2) Related Jira issues, (3) Recurring pattern analysis, (4) Recommended actions. URL: {job_url}"

var (
	exit            = os.Exit
	newSlackClient  = slack.New
	authTest        = (*slack.Client).AuthTest
	newAnalyzer     = analyzer.NewAnalyzer
	newHandler      = handler.New
	newSocketClient = socketmode.New
	runSocket       = (*socketmode.Client).Run
	ackSocket       = (*socketmode.Client).Ack
	dispatchEvent   = handleSocketEvent
	launchWorker    = func(worker func()) { go worker() }
)

var stdout io.Writer = os.Stdout

func main() {
	var (
		slackToken  = flag.String("slack-token", os.Getenv("PROW_AN__SLACK__BOT_TOKEN"), "Slack bot token (defaults to env. var. PROW_AN__SLACK__BOT_TOKEN, if set).")
		appToken    = flag.String("app-token", os.Getenv("PROW_AN__SLACK__APP_TOKEN"), "Slack app token for socket mode (defaults to env. var. PROW_AN__SLACK__APP_TOKEN, if set).")
		mcpURL      = flag.String("mcp-url", os.Getenv("PROW_AN__MCP__URL__SHIP_HELP"), "Ship-help MCP URL (defaults to env. var. PROW_AN__MCP__URL__SHIP_HELP, if set).")
		mcpToken    = flag.String("mcp-token", os.Getenv("PROW_AN__MCP__TOKEN__SHIP_HELP"), "Ship-help MCP token (defaults to env. var. PROW_AN__MCP__TOKEN__SHIP_HELP, if set).")
		channels    = flag.String("channels", os.Getenv("PROW_AN__MONITORED_CHANNELS"), "Comma-separated list of channel IDs to monitor (defaults to env. var. PROW_AN__MONITORED_CHANNELS, if set).")
		allowedBots = flag.String("allowed-bots", os.Getenv("PROW_AN__ALLOWED_BOT_IDS"), "Comma-separated list of bot IDs (B...) whose Prow URLs should be analyzed (defaults to env. var. PROW_AN__ALLOWED_BOT_IDS, if set).")
		prompt      = flag.String("prompt", envStr("PROW_AN__PROMPT__TEMPLATE", defaultPrompt), "Analysis prompt template with a {job_url} placeholder (defaults to env. var. PROW_AN__PROMPT__TEMPLATE, if set).")
		monitorAll  = flag.Bool("monitor-all", envBool("PROW_AN__MONITOR__ALL", false), "Monitor every channel the bot is a member of instead of only --channels. Fail-closed: without this and with no --channels, no channel is monitored (defaults to env. var. PROW_AN__MONITOR__ALL; set it to \"true\" to enable).")
		slackDebug  = flag.Bool("slack-debug", envBool("PROW_AN__SLACK__DEBUG", false), "Enable verbose Slack SDK and Socket Mode debug logging (defaults to env. var. PROW_AN__SLACK__DEBUG; set it to \"true\" to enable).")
		mcpDebug    = flag.Bool("mcp-debug", envBool("PROW_AN__MCP__SHIP_HELP__DEBUG", false), "Enable verbose MCP SSE logging (metadata only: per-line and byte counts, never payload content); off by default (defaults to env. var. PROW_AN__MCP__SHIP_HELP__DEBUG; set it to \"true\" to enable).")
		mcpTimeout  = flag.Int("mcp-timeout", envInt("PROW_AN__MCP__TIMEOUT_SEC", int(analyzer.DefaultMCPTimeout/time.Second)), "MCP/Prow HTTP request timeout in seconds; must exceed the longest analysis (defaults to env. var. PROW_AN__MCP__TIMEOUT_SEC, if set).")
		tlsInsecure = flag.Bool("tls-insecure", envBool("TLS_INSECURE_SKIP_VERIFY", false), "Skip TLS certificate verification for MCP/Prow HTTP requests (defaults to env. var. TLS_INSECURE_SKIP_VERIFY; set it to \"true\" to enable).")
	)

	flag.Parse()

	if *slackToken == "" {
		slog.Error("--slack-token is required (or set PROW_AN__SLACK__BOT_TOKEN)")
		exit(1)
	}
	if *appToken == "" {
		slog.Error("--app-token is required (or set PROW_AN__SLACK__APP_TOKEN)")
		exit(1)
	}
	if *mcpURL == "" || *mcpToken == "" {
		slog.Error("Both --mcp-url and --mcp-token are required (or set PROW_AN__MCP__URL__SHIP_HELP and PROW_AN__MCP__TOKEN__SHIP_HELP)")
		exit(1)
	}

	// Parse monitored channels. Fail-closed: when empty and --monitor-all is not
	// set, the bot monitors nothing. Set PROW_AN__MONITOR__ALL=true to opt into
	// monitoring every channel the bot is a member of.
	var monitoredChannels []string
	if *channels != "" {
		for _, ch := range strings.Split(*channels, ",") {
			if ch = strings.TrimSpace(ch); ch != "" {
				monitoredChannels = append(monitoredChannels, ch)
			}
		}
	}

	// Parse allow-listed bot IDs. When set, Prow URLs posted by these bots (e.g.
	// chai-bot) are analyzed too; the bot always ignores its own messages.
	var allowedBotIDs []string
	if *allowedBots != "" {
		for _, id := range strings.Split(*allowedBots, ",") {
			if id = strings.TrimSpace(id); id != "" {
				allowedBotIDs = append(allowedBotIDs, id)
			}
		}
	}

	slog.Info("Starting prow-analyzer-bot")
	switch {
	case *monitorAll:
		slog.Warn("PROW_AN__MONITOR__ALL enabled: monitoring EVERY channel the bot is a member of; messages from all such channels may be forwarded to ship-help under shared service credentials",
			"channels_configured", len(monitoredChannels))
	case len(monitoredChannels) == 0:
		slog.Warn("No channels configured and PROW_AN__MONITOR__ALL not set: fail-closed, the bot will not monitor any channel. Set PROW_AN__MONITORED_CHANNELS or PROW_AN__MONITOR__ALL=true")
	default:
		slog.Info("Monitoring channels", "channels", monitoredChannels)
	}
	if len(allowedBotIDs) > 0 {
		slog.Info("Analyzing Prow URLs from allow-listed bots", "botIDs", allowedBotIDs)
	}

	slackClient := newSlackClient(
		*slackToken,
		slack.OptionAppLevelToken(*appToken),
		slack.OptionDebug(*slackDebug),
		slack.OptionLog(log.New(stdout, "slack: ", log.Lshortfile|log.LstdFlags)),
	)

	// Determine this bot's own bot ID so its own messages are never analyzed
	// (loop prevention), even when bot allow-listing is enabled.
	handlerOpts := []handler.Option{
		handler.WithAllowedBotIDs(allowedBotIDs),
		handler.WithMonitorAll(*monitorAll),
	}
	if authResp, err := authTest(slackClient); err != nil {
		slog.Warn("AuthTest failed; self bot ID unknown (own messages still ignored via allow-list)", "error", err)
	} else {
		handlerOpts = append(handlerOpts, handler.WithSelfBotID(authResp.BotID))
	}

	a := newAnalyzer(*mcpURL, *mcpToken, *prompt,
		analyzer.WithInsecureSkipVerify(*tlsInsecure),
		analyzer.WithDebug(*mcpDebug),
		analyzer.WithTimeout(time.Duration(*mcpTimeout)*time.Second),
	)

	h := newHandler(slackClient, a, monitoredChannels, handlerOpts...)

	socketClient := newSocketClient(
		slackClient,
		socketmode.OptionDebug(*slackDebug),
		socketmode.OptionLog(log.New(stdout, "socketmode: ", log.Lshortfile|log.LstdFlags)),
	)

	launchWorker(func() {
		for evt := range socketClient.Events {
			dispatchEvent(evt, h, socketClient)
		}
	})

	fmt.Fprintln(stdout, "Prow analyzer bot is running...")
	if err := runSocket(socketClient); err != nil {
		slog.Error("Socket mode error", "error", err)
		exit(1)
	}
}

func handleSocketEvent(evt socketmode.Event, h handler.PartialHandler, socketClient *socketmode.Client) {
	slog.Info("Received socket mode event", "type", evt.Type)
	switch evt.Type {
	case socketmode.EventTypeConnecting:
		slog.Info("Connecting to Slack...")
	case socketmode.EventTypeConnected:
		slog.Info("Connected to Slack")
	case socketmode.EventTypeConnectionError:
		slog.Error("Connection error", "data", evt.Data)
	case socketmode.EventTypeEventsAPI:
		eventsAPIEvent, ok := evt.Data.(slackevents.EventsAPIEvent)
		if !ok {
			slog.Warn("Ignored event", "event", evt)
			return
		}

		ackSocket(socketClient, *evt.Request)

		logger := slog.With("type", eventsAPIEvent.Type)
		handled, err := h.Handle(&eventsAPIEvent, logger)
		if err != nil {
			logger.Error("Failed to handle event", "error", err)
		} else if handled {
			logger.Info("Event handled")
		}
	default:
		slog.Info("Unhandled event type", "type", evt.Type)
	}
}
