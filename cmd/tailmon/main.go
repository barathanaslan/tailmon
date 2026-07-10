// tailmon: tailnet-wide resource monitor. One binary, subcommands:
//
//	tailmon           TUI viewer (default)
//	tailmon agent     HTTP agent serving local stats on :7020
//	tailmon sample    print one local snapshot as JSON and exit
//	tailmon json      aggregate all reachable tailnet agents into one JSON doc
//	tailmon version   print version
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/barathanaslan/studio-cli/internal/agent"
	"github.com/barathanaslan/studio-cli/internal/aggregate"
	"github.com/barathanaslan/studio-cli/internal/sample"
	"github.com/barathanaslan/studio-cli/internal/tui"
	"github.com/barathanaslan/studio-cli/internal/version"
)

const usage = `tailmon — tailnet-wide resource monitor

Usage:
  tailmon              TUI: this machine + every online tailnet peer
  tailmon agent        HTTP agent on the Tailscale IP + 127.0.0.1 (--port, default 7020)
  tailmon sample       one local stats snapshot as JSON to stdout
  tailmon json         combined JSON for all reachable agents (for AI tools)
  tailmon version      print version
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	args := os.Args[1:]
	cmd := ""
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd = args[0]
		args = args[1:]
	}

	var err error
	switch cmd {
	case "":
		err = tui.Run(ctx)
	case "agent":
		fs := flag.NewFlagSet("agent", flag.ExitOnError)
		port := fs.Int("port", agent.DefaultPort, "port to listen on")
		_ = fs.Parse(args)
		err = agent.Run(ctx, *port)
	case "sample":
		err = runSample(ctx)
	case "json":
		err = runJSON(ctx)
	case "version":
		fmt.Println("tailmon " + version.Version)
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "tailmon: unknown subcommand %q\n\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "tailmon: "+err.Error())
		os.Exit(1)
	}
}

func runSample(ctx context.Context) error {
	s, err := sample.Collect(ctx)
	if err != nil {
		return err
	}
	return printJSON(s)
}

func runJSON(ctx context.Context) error {
	report := aggregate.Collect(ctx)
	return printJSON(report)
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
