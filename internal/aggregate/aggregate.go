// Package aggregate fans out to every reachable tailmon agent and combines
// the answers into one document. Used by `tailmon json` and the TUI.
package aggregate

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/barathanaslan/studio-cli/internal/agent"
	"github.com/barathanaslan/studio-cli/internal/discover"
	"github.com/barathanaslan/studio-cli/internal/sample"
)

// RequestTimeout bounds each per-host /stats request (plan: 800ms).
const RequestTimeout = 800 * time.Millisecond

// Host statuses.
const (
	StatusLive    = "live"     // agent (or in-process local sample) answered
	StatusNoAgent = "no-agent" // host online but :7020 closed / errored
	StatusOffline = "offline"  // tailscale says the host is offline
)

type HostResult struct {
	Host   string        `json:"host"`
	IP     string        `json:"ip,omitempty"`
	OS     string        `json:"os,omitempty"`
	Status string        `json:"status"`
	Source string        `json:"source,omitempty"` // "local" (in-process) or "agent"
	Error  string        `json:"error,omitempty"`
	Stats  *sample.Stats `json:"stats"`
}

type Report struct {
	Schema      int          `json:"schema"`
	GeneratedAt time.Time    `json:"generated_at"`
	Hosts       []HostResult `json:"hosts"`
	Note        string       `json:"note,omitempty"`
}

// NewClient returns the HTTP client used for agent requests: tight timeout,
// no implicit proxies, bounded idle pool.
func NewClient() *http.Client {
	return &http.Client{
		Timeout: RequestTimeout,
		Transport: &http.Transport{
			Proxy:               nil,
			MaxIdleConnsPerHost: 1,
			IdleConnTimeout:     30 * time.Second,
		},
	}
}

// FetchStats GETs one agent's /stats. Shared by `json` and the TUI.
func FetchStats(ctx context.Context, client *http.Client, ip string, port int) (*sample.Stats, error) {
	url := fmt.Sprintf("http://%s:%d/stats", ip, port)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("agent returned %d", resp.StatusCode)
	}
	var s sample.Stats
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		return nil, err
	}
	return &s, nil
}

// Collect discovers peers and queries every reachable agent in parallel. The
// local machine is sampled in-process — it shows up even with no local agent
// running. With no tailscale CLI it degrades to localhost only.
func Collect(ctx context.Context) *Report {
	report := &Report{Schema: sample.SchemaVersion}
	hosts, err := discover.Hosts(ctx)
	if err != nil {
		// Degrade gracefully: local sample only.
		report.Note = "tailscale unavailable (" + err.Error() + "); local sample only"
		hosts = nil
	}

	client := NewClient()
	results := make([]HostResult, 0, len(hosts)+1)

	if len(hosts) == 0 {
		results = append(results, localResult(ctx, discover.Host{Self: true}))
	} else {
		results = results[:len(hosts)]
		var wg sync.WaitGroup
		for i, h := range hosts {
			if h.Self {
				results[i] = localResult(ctx, h)
				continue
			}
			if !h.Online {
				results[i] = HostResult{Host: h.Name, IP: h.IP, OS: h.OS, Status: StatusOffline}
				continue
			}
			wg.Add(1)
			go func(i int, h discover.Host) {
				defer wg.Done()
				r := HostResult{Host: h.Name, IP: h.IP, OS: h.OS, Source: "agent"}
				stats, err := FetchStats(ctx, client, h.IP, agent.DefaultPort)
				if err != nil {
					r.Status, r.Source, r.Error = StatusNoAgent, "", err.Error()
				} else {
					r.Status, r.Stats = StatusLive, stats
				}
				results[i] = r
			}(i, h)
		}
		wg.Wait()
	}
	client.CloseIdleConnections()

	report.GeneratedAt = time.Now().UTC()
	report.Hosts = results
	return report
}

// localResult samples this machine in-process.
func localResult(ctx context.Context, h discover.Host) HostResult {
	r := HostResult{Host: h.Name, IP: h.IP, OS: h.OS, Status: StatusLive, Source: "local"}
	stats, err := sample.Collect(ctx)
	if err != nil {
		r.Status, r.Source, r.Error = StatusNoAgent, "", err.Error()
		return r
	}
	if r.Host == "" {
		r.Host = stats.Host
	}
	r.Stats = stats
	return r
}
