package agent

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/barathanaslan/tailmon/internal/aggregate"
	"github.com/barathanaslan/tailmon/internal/discover"
)

var errKilled = errors.New("signal: killed") // what a timed-out tailscale CLI call returns

func twoHosts() []discover.Host {
	return []discover.Host{
		{Name: "self", IP: "100.0.0.1", Self: true, Online: true},
		{Name: "box", IP: "100.0.0.2", Online: true},
	}
}

// waitAsk blocks until no ask is in flight.
func waitAsk(r *roster) {
	r.mu.Lock()
	done := r.inflight
	r.mu.Unlock()
	if done != nil {
		<-done
	}
}

// The list tailscale gave last outlives any number of failed asks: this is
// the 2026-11-25 fault (a busy machine, every `tailscale status` killed at
// its time limit, every peer gone from the report).
func TestRosterKeepsListWhenAsksFail(t *testing.T) {
	var calls atomic.Int32
	r := newRoster(5*time.Millisecond, time.Second, time.Second, time.Hour, func(context.Context) ([]discover.Host, error) {
		if calls.Add(1) == 1 {
			return twoHosts(), nil
		}
		return nil, errKilled
	})
	for i := 0; i < 5; i++ {
		hosts, err := r.get(context.Background())
		if err != nil || len(hosts) != 2 || hosts[1].Name != "box" {
			t.Fatalf("ask %d: hosts %+v, err %v", i, hosts, err)
		}
		waitAsk(r)
		time.Sleep(10 * time.Millisecond) // past ttl: the next get asks again
	}
	if n := calls.Load(); n < 3 {
		t.Fatalf("tailscale asked %d times; a failed ask must be followed by another after ttl", n)
	}
	if note := r.note(); note != "" {
		t.Errorf("note %q before staleAfter", note)
	}
	r.staleAfter = 0
	if note := r.note(); !strings.Contains(note, "signal: killed") || !strings.Contains(note, "device list from") {
		t.Errorf("stale note = %q", note)
	}
}

// A report never waits for a renewal: a slow ask runs beside it, alone, and
// its answer is used once it is there.
func TestRosterRenewsBesideTheReport(t *testing.T) {
	release := make(chan struct{})
	var calls atomic.Int32
	r := newRoster(5*time.Millisecond, 10*time.Second, time.Second, time.Hour, func(context.Context) ([]discover.Host, error) {
		if calls.Add(1) == 1 {
			return twoHosts(), nil
		}
		<-release
		return append(twoHosts(), discover.Host{Name: "new", IP: "100.0.0.4", Online: true}), nil
	})
	if _, err := r.get(context.Background()); err != nil {
		t.Fatal(err)
	}
	waitAsk(r)
	time.Sleep(10 * time.Millisecond)

	for i := 0; i < 20; i++ { // each of these finds the list due while the slow ask hangs
		start := time.Now()
		hosts, err := r.get(context.Background())
		if err != nil || len(hosts) != 2 {
			t.Fatalf("hosts %+v, err %v", hosts, err)
		}
		if d := time.Since(start); d > 200*time.Millisecond {
			t.Fatalf("get waited %v for the slow ask", d)
		}
	}
	// The renewal runs on its own goroutine; give it time to reach tailscale.
	for deadline := time.Now().Add(5 * time.Second); calls.Load() < 2 && time.Now().Before(deadline); {
		time.Sleep(time.Millisecond)
	}
	if n := calls.Load(); n != 2 {
		t.Fatalf("%d asks, want one initial and one renewal in flight", n)
	}
	close(release)
	waitAsk(r)
	if hosts, _ := r.get(context.Background()); len(hosts) != 3 {
		t.Fatalf("renewed list not used: %+v", hosts)
	}
}

// Before any list exists a report waits firstWait at most, says why it has
// no peers, and the ask it started still delivers.
func TestRosterFirstAsk(t *testing.T) {
	release := make(chan struct{})
	r := newRoster(time.Hour, 10*time.Second, 20*time.Millisecond, time.Hour, func(context.Context) ([]discover.Host, error) {
		<-release
		return twoHosts(), nil
	})
	if hosts, err := r.get(context.Background()); err == nil || hosts != nil || !strings.Contains(err.Error(), "still waiting") {
		t.Fatalf("slow first ask: hosts %+v, err %v", hosts, err)
	}
	close(release)
	waitAsk(r)
	if hosts, err := r.get(context.Background()); err != nil || len(hosts) != 2 {
		t.Fatalf("after the first ask finished: hosts %+v, err %v", hosts, err)
	}

	// Quick first ask: the report that started it gets the list.
	quick := newRoster(time.Hour, time.Second, time.Second, time.Hour, func(context.Context) ([]discover.Host, error) {
		time.Sleep(10 * time.Millisecond)
		return twoHosts(), nil
	})
	if hosts, err := quick.get(context.Background()); err != nil || len(hosts) != 2 {
		t.Fatalf("quick first ask: hosts %+v, err %v", hosts, err)
	}
}

// With no list ever, the error is the answer, and it is not asked for again
// before ttl (no CLI storm when tailscale is not installed).
func TestRosterNoListYet(t *testing.T) {
	var calls atomic.Int32
	r := newRoster(time.Hour, time.Second, time.Second, time.Hour, func(context.Context) ([]discover.Host, error) {
		calls.Add(1)
		return nil, discover.ErrNoTailscale
	})
	for i := 0; i < 5; i++ {
		if hosts, err := r.get(context.Background()); !errors.Is(err, discover.ErrNoTailscale) || hosts != nil {
			t.Fatalf("hosts %+v, err %v", hosts, err)
		}
	}
	if n := calls.Load(); n != 1 {
		t.Fatalf("%d asks within ttl, want 1", n)
	}
	if note := r.note(); note != "" {
		t.Errorf("note %q without a list", note)
	}
}

// The whole path: once the agent has seen the tailnet, /fleet keeps every
// peer (and keeps asking them) while tailscale discovery fails.
func TestFleetKeepsPeersWhenDiscoveryFails(t *testing.T) {
	var mu sync.Mutex
	failing := false
	var failed atomic.Int32
	s, srv, done := fleetServerWith(t, func(hosts []discover.Host) ([]discover.Host, error) {
		mu.Lock()
		defer mu.Unlock()
		if failing {
			failed.Add(1)
			return nil, errKilled
		}
		return hosts, nil
	}, 20*time.Millisecond)
	defer done()

	if r := getFleet(t, srv, ""); len(r.Hosts) != 3 || r.Note != "" {
		t.Fatalf("first report: %d hosts, note %q", len(r.Hosts), r.Note)
	}
	mu.Lock()
	failing = true
	mu.Unlock()

	deadline := time.Now().Add(10 * time.Second)
	for failed.Load() < 2 { // at least two failed renewals behind the reports below
		if time.Now().After(deadline) {
			t.Fatal("discovery was never asked again")
		}
		getFleet(t, srv, "")
		time.Sleep(cacheTTL / 4)
	}
	time.Sleep(cacheTTL) // a report built after those failures
	r := getFleet(t, srv, "")
	if len(r.Hosts) != 3 {
		t.Fatalf("after failed discovery: %d hosts (note %q), want 3", len(r.Hosts), r.Note)
	}
	if r.Note != "" {
		t.Errorf("note %q while the list is younger than discoverStaleAfter", r.Note)
	}
	for _, h := range r.Hosts {
		if h.Host == "peer" && (h.Status != aggregate.StatusLive || h.Stats == nil) {
			t.Errorf("peer no longer live: %+v", h)
		}
	}
	s.hosts.staleAfter = 0
	time.Sleep(cacheTTL)
	if r := getFleet(t, srv, ""); len(r.Hosts) != 3 || !strings.Contains(r.Note, "device list from") {
		t.Errorf("old list: %d hosts, note %q", len(r.Hosts), r.Note)
	}
}
