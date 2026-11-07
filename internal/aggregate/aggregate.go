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

	"github.com/barathanaslan/tailmon/internal/discover"
	"github.com/barathanaslan/tailmon/internal/port"
	"github.com/barathanaslan/tailmon/internal/sample"
)

// RequestTimeout bounds each per-host /stats request. A cold sample costs
// ~600ms by construction (the 500ms CPU measurement window) — measured 580ms
// on Windows, 645ms on macOS — so the original 800ms left almost no headroom
// and a busy host would drop out of the view as a bogus "no agent". Requests
// run concurrently and asynchronously, so a generous bound costs nothing but
// a later card update for the one slow host.
const RequestTimeout = 2500 * time.Millisecond

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
// top > 0 requests that many top processes (?top=N); 0 means server default.
func FetchStats(ctx context.Context, client *http.Client, ip string, port, top int) (*sample.Stats, error) {
	url := fmt.Sprintf("http://%s:%d/stats", ip, port)
	if top > 0 {
		url += fmt.Sprintf("?top=%d", sample.ClampTop(top))
	}
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

// Source says where a report's pieces come from. The zero value of each
// field means the CLI default: tailscale discovery, the local agent (or an
// in-process sample) for this machine, port.Default, a fresh client.
type Source struct {
	Hosts  func(ctx context.Context) ([]discover.Host, error)
	Local  func(ctx context.Context, top int) (*sample.Stats, error)
	Port   int
	Client *http.Client // reused across calls when set (keep-alive)
}

// Collect discovers peers and queries every reachable agent in parallel. The
// local machine is sampled in-process — it shows up even with no local agent
// running. With no tailscale CLI it degrades to localhost only.
func Collect(ctx context.Context) *Report { return CollectTop(ctx, 0) }

// CollectTop is Collect with an explicit top-process count per host
// (0 = default).
func CollectTop(ctx context.Context, top int) *Report {
	return Source{}.Collect(ctx, top)
}

// Collect builds one report from src.
func (src Source) Collect(ctx context.Context, top int) *Report {
	hostsFn, localFn, p, client := src.Hosts, src.Local, src.Port, src.Client
	if hostsFn == nil {
		hostsFn = discover.Hosts
	}
	if localFn == nil {
		localFn = localStats
	}
	if p == 0 {
		p = port.Default
	}
	if client == nil {
		client = NewClient()
		defer client.CloseIdleConnections()
	}

	report := &Report{Schema: sample.SchemaVersion}
	hosts, err := hostsFn(ctx)
	if err != nil {
		// Degrade gracefully: local sample only.
		report.Note = "tailscale unavailable (" + err.Error() + "); local sample only"
		hosts = nil
	}

	results := make([]HostResult, 0, len(hosts)+1)
	if len(hosts) == 0 {
		results = append(results, localResult(ctx, discover.Host{Self: true}, top, localFn))
	} else {
		results = results[:len(hosts)]
		var wg sync.WaitGroup
		for i, h := range hosts {
			if h.Self {
				continue // sampled below, concurrently with the peers
			}
			if !h.Online {
				results[i] = HostResult{Host: h.Name, IP: h.IP, OS: h.OS, Status: StatusOffline}
				continue
			}
			wg.Add(1)
			go func(i int, h discover.Host) {
				defer wg.Done()
				r := HostResult{Host: h.Name, IP: h.IP, OS: h.OS, Source: "agent"}
				stats, err := FetchStats(ctx, client, h.IP, p, top)
				if err != nil {
					r.Status, r.Source, r.Error = StatusNoAgent, "", err.Error()
				} else {
					r.Status, r.Stats = StatusLive, stats
				}
				results[i] = r
			}(i, h)
		}
		for i, h := range hosts {
			if h.Self {
				results[i] = localResult(ctx, h, top, localFn)
			}
		}
		wg.Wait()
	}

	report.GeneratedAt = time.Now().UTC()
	report.Hosts = results
	return report
}

func localResult(ctx context.Context, h discover.Host, top int, localFn func(context.Context, int) (*sample.Stats, error)) HostResult {
	r := HostResult{Host: h.Name, IP: h.IP, OS: h.OS, Status: StatusLive, Source: "local"}
	stats, err := localFn(ctx, top)
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

// localStats gets this machine's stats. It asks the local agent first —
// that shares the agent's 1s single-flight cache with every other viewer
// (no double sampling, and no 500ms measurement window when the answer is
// already warm). Only when no agent runs does it sample in-process.
func localStats(ctx context.Context, top int) (*sample.Stats, error) {
	if stats, err := fetchLocalAgent(ctx, top); err == nil {
		return stats, nil
	}
	if top > 0 {
		return sample.CollectTop(ctx, top)
	}
	return sample.Collect(ctx)
}

func fetchLocalAgent(ctx context.Context, top int) (*sample.Stats, error) {
	cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	client := &http.Client{Timeout: 2 * time.Second}
	defer client.CloseIdleConnections()
	return FetchStats(cctx, client, "127.0.0.1", port.Default, top)
}
