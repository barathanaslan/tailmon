package aggregate

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/barathanaslan/tailmon/internal/discover"
	"github.com/barathanaslan/tailmon/internal/sample"
)

// fakeNet stands in for the tailnet: per IP, the agent answers, refuses, or
// the address is a black hole (the request hangs until its context ends,
// which is what an offline tailnet address does).
type fakeNet struct {
	mu    sync.Mutex
	mode  map[string]string // "answer" | "refuse" | "hang"
	calls map[string]int
}

func newFakeNet(mode map[string]string) *fakeNet {
	return &fakeNet{mode: mode, calls: map[string]int{}}
}

func (f *fakeNet) set(ip, mode string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.mode[ip] = mode
}

func (f *fakeNet) asked(ip string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[ip]
}

func (f *fakeNet) fetch(ctx context.Context, _ *http.Client, ip string, _, _ int) (*sample.Stats, error) {
	f.mu.Lock()
	f.calls[ip]++
	mode := f.mode[ip]
	f.mu.Unlock()
	switch mode {
	case "answer":
		return &sample.Stats{Host: ip}, nil
	case "hang":
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return nil, errors.New("connection refused")
}

func (f *fakeNet) source(hosts []discover.Host, probes *Probes) Source {
	return Source{
		Hosts:  func(context.Context) ([]discover.Host, error) { return hosts, nil },
		Local:  func(context.Context, int) (*sample.Stats, error) { return &sample.Stats{Host: "self"}, nil },
		Probes: probes,
		Fetch:  f.fetch,
	}
}

func statuses(r *Report) map[string]HostResult {
	out := map[string]HostResult{}
	for _, h := range r.Hosts {
		out[h.Host] = h
	}
	return out
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// Without Probes (tailmon json): tailscale's offline flag does not decide —
// the agent is asked, and only its silence makes the host offline.
func TestCollectAsksFlaggedOfflinePeers(t *testing.T) {
	net := newFakeNet(map[string]string{"10.0.0.2": "answer", "10.0.0.3": "refuse", "10.0.0.4": "refuse"})
	hosts := []discover.Host{
		{Name: "self", IP: "10.0.0.1", Online: true, Self: true},
		{Name: "shared", IP: "10.0.0.2", Online: false}, // stale flag, agent up
		{Name: "gone", IP: "10.0.0.3", Online: false},
		{Name: "bare", IP: "10.0.0.4", Online: true}, // online, no agent
	}
	got := statuses(net.source(hosts, nil).Collect(context.Background(), 0))

	if h := got["shared"]; h.Status != StatusLive || h.Stats == nil || h.Source != "agent" {
		t.Errorf("shared: %+v", h)
	}
	if h := got["gone"]; h.Status != StatusOffline || h.Stats != nil || h.Error != "" {
		t.Errorf("gone: %+v", h)
	}
	if h := got["bare"]; h.Status != StatusNoAgent || h.Error == "" {
		t.Errorf("bare: %+v", h)
	}
	if h := got["self"]; h.Status != StatusLive || h.Source != "local" {
		t.Errorf("self: %+v", h)
	}
}

// With Probes (the agent): a flagged-offline peer never holds a report up,
// turns live once it has answered in the background, and a silent one is not
// asked again before the interval is over.
func TestCollectProbesInBackground(t *testing.T) {
	net := newFakeNet(map[string]string{"10.0.0.2": "answer", "10.0.0.3": "hang"})
	hosts := []discover.Host{
		{Name: "self", IP: "10.0.0.1", Online: true, Self: true},
		{Name: "shared", IP: "10.0.0.2", Online: false},
		{Name: "gone", IP: "10.0.0.3", Online: false},
	}
	probes := NewProbes()
	src := net.source(hosts, probes)

	start := time.Now()
	got := statuses(src.Collect(context.Background(), 0))
	if d := time.Since(start); d > RequestTimeout/2 {
		t.Fatalf("first report waited %v for a flagged-offline peer", d)
	}
	if got["shared"].Status != StatusOffline || got["gone"].Status != StatusOffline {
		t.Fatalf("first report: shared=%s gone=%s", got["shared"].Status, got["gone"].Status)
	}

	waitFor(t, "shared to answer its background ask", func() bool { return probes.alive("10.0.0.2") })
	start = time.Now()
	got = statuses(src.Collect(context.Background(), 0))
	if d := time.Since(start); d > RequestTimeout/2 {
		t.Fatalf("second report waited %v", d)
	}
	if h := got["shared"]; h.Status != StatusLive || h.Stats == nil {
		t.Errorf("shared after its answer: %+v", h)
	}
	if got["gone"].Status != StatusOffline {
		t.Errorf("gone: %+v", got["gone"])
	}
	if n := net.asked("10.0.0.3"); n != 1 {
		t.Errorf("gone was asked %d times, want 1 (one ask in flight)", n)
	}

	// The agent stops answering: offline on the report that notices, and no
	// further ask within the interval.
	net.set("10.0.0.2", "refuse")
	got = statuses(src.Collect(context.Background(), 0))
	if h := got["shared"]; h.Status != StatusOffline || h.Stats != nil {
		t.Errorf("shared after it went silent: %+v", h)
	}
	before := net.asked("10.0.0.2")
	src.Collect(context.Background(), 0)
	if n := net.asked("10.0.0.2"); n != before {
		t.Errorf("silent peer asked again inside the interval (%d -> %d)", before, n)
	}
}

// A peer tailscale reports online is asked on every report, Probes or not.
func TestCollectOnlinePeerAlwaysAsked(t *testing.T) {
	net := newFakeNet(map[string]string{"10.0.0.2": "refuse"})
	hosts := []discover.Host{
		{Name: "self", IP: "10.0.0.1", Online: true, Self: true},
		{Name: "bare", IP: "10.0.0.2", Online: true},
	}
	src := net.source(hosts, NewProbes())
	for i := 1; i <= 3; i++ {
		got := statuses(src.Collect(context.Background(), 0))
		if got["bare"].Status != StatusNoAgent {
			t.Fatalf("report %d: %+v", i, got["bare"])
		}
		if n := net.asked("10.0.0.2"); n != i {
			t.Fatalf("report %d: asked %d times", i, n)
		}
	}
}

func TestProbesIntervalAndPruning(t *testing.T) {
	p := NewProbes()
	t0 := time.Unix(1_700_000_000, 0)
	if !p.begin("a", t0) {
		t.Fatal("first ask must start")
	}
	if p.begin("a", t0) {
		t.Fatal("second ask started while the first is in flight")
	}
	p.record("a", false, t0)
	if p.begin("a", t0.Add(ProbeInterval-time.Second)) {
		t.Fatal("ask started before the interval was over")
	}
	if !p.begin("a", t0.Add(ProbeInterval)) {
		t.Fatal("ask did not start after the interval")
	}
	p.record("a", true, t0)
	p.record("b", true, t0)
	if !p.alive("a") || !p.alive("b") || p.alive("c") {
		t.Fatal("alive verdicts wrong")
	}
	p.keep([]discover.Host{{IP: "a"}})
	if !p.alive("a") || p.alive("b") {
		t.Fatal("keep must drop peers that left, and only those")
	}

	var none *Probes // one-shot callers: every method is a no-op
	none.record("a", true, t0)
	none.keep(nil)
	if none.alive("a") {
		t.Fatal("nil Probes must report nothing alive")
	}
}
