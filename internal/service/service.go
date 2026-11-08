// Package service installs the tailmon agent as a per-machine background
// service, the same way on every install route (deploy scripts, Homebrew,
// Scoop, deb/rpm):
//
//	macOS    user LaunchAgent  ~/Library/LaunchAgents/com.bosphorify.tailmon.plist
//	Windows  scheduled task    "tailmon-agent", ONSTART as SYSTEM (needs an elevated shell)
//	Linux    systemd user unit ~/.config/systemd/user/tailmon.service
//
// The service runs `<binary> agent [--port N]`. The binary path is the one
// tailmon was started from, NOT symlink-resolved, so a package manager's
// stable link (/opt/homebrew/bin/tailmon, scoop's current\) survives upgrades.
package service

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/barathanaslan/tailmon/internal/port"
)

// Names shared by every platform.
const (
	LaunchdLabel = "com.bosphorify.tailmon"
	TaskName     = "tailmon-agent"
	UnitName     = "tailmon.service"
)

// Options for Install.
type Options struct {
	Binary string // absolute path to tailmon; default: the running executable
	Port   int    // 0 = default 7020
}

func (o Options) withDefaults() (Options, error) {
	if o.Binary == "" {
		exe, err := os.Executable()
		if err != nil {
			return o, fmt.Errorf("cannot find own executable: %w", err)
		}
		o.Binary = exe
	}
	if o.Port == 0 {
		o.Port = port.Default
	}
	return o, nil
}

// agentArgs is the service's argv after the binary.
func (o Options) agentArgs() []string {
	args := []string{"agent"}
	if o.Port != port.Default {
		args = append(args, "--port", strconv.Itoa(o.Port))
	}
	return args
}

// Install registers (or re-registers) the agent service and starts it.
func Install(o Options) error {
	o, err := o.withDefaults()
	if err != nil {
		return err
	}
	return install(o)
}

// Uninstall stops and removes the service. Logs are kept. Not an error when
// nothing is installed. With onlyIfBin set, the service is removed only when
// it runs that binary (the Tailmon.app cask removes the agent it installed,
// never one installed another way).
func Uninstall(onlyIfBin string) error {
	if onlyIfBin != "" {
		def, err := definition()
		if err != nil || !strings.Contains(def, onlyIfBin) {
			fmt.Println("service not registered with " + onlyIfBin + "; left as is")
			return nil
		}
	}
	return uninstall()
}

// Status describes the service registration and whether the agent answers.
func Status(p int) string {
	if p == 0 {
		p = port.Default
	}
	return status() + "\n" + health(p)
}

func health(p int) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	url := fmt.Sprintf("http://127.0.0.1:%d/health", p)
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Sprintf("agent: not answering on 127.0.0.1:%d", p)
	}
	defer resp.Body.Close()
	var h struct {
		Version string  `json:"version"`
		RSSMB   float64 `json:"rss_mb"`
		Uptime  int64   `json:"uptime_sec"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&h); err != nil {
		return fmt.Sprintf("agent: 127.0.0.1:%d answered HTTP %d", p, resp.StatusCode)
	}
	return fmt.Sprintf("agent: %s up %ds, rss %.1f MB (127.0.0.1:%d)", h.Version, h.Uptime, h.RSSMB, p)
}
