package agent

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/barathanaslan/tailmon/internal/discover"
)

// roster is the agent's list of tailnet machines. The list changes rarely
// (a machine joins or leaves the tailnet), while asking tailscale for it can
// be slow: on macOS the CLI is the GUI app's own binary, and on a machine
// whose cores are all taken one `tailscale status --json` took 2.5 to 13 s
// (2026-11-25: load 50 on 12 cores, every call over the old 2 s bound). So
// the two are kept apart:
//
//   - a report takes the list tailscale gave last and never waits for a new
//     one; only the very first ask waits, briefly;
//   - when the list is older than ttl, the request that notices starts one
//     ask on its own goroutine (still on demand: an idle agent runs nothing);
//   - an ask that fails or runs out of time leaves the list as it was. Peers
//     keep being asked at their agents, which is what decides live/offline.
//
// Bounded: one list, at most one ask in flight.
type roster struct {
	ttl        time.Duration // age at which the list is asked for again
	timeout    time.Duration // longest one ask may run
	firstWait  time.Duration // how long a report waits when there is no list yet
	staleAfter time.Duration // list age from which a failing ask is put in the report
	fn         func(context.Context) ([]discover.Host, error)

	mu       sync.Mutex
	hosts    []discover.Host // the last list tailscale gave
	gotAt    time.Time       // when it gave it; zero: never
	triedAt  time.Time       // when the last ask ended, either way
	err      error           // how the last ask ended
	inflight chan struct{}   // non-nil while an ask is running
}

func newRoster(ttl, timeout, firstWait, staleAfter time.Duration, fn func(context.Context) ([]discover.Host, error)) *roster {
	return &roster{ttl: ttl, timeout: timeout, firstWait: firstWait, staleAfter: staleAfter, fn: fn}
}

// get returns the last list tailscale gave, starting a new ask when that list
// is due. An error comes back only while no ask has ever succeeded. Callers
// must not mutate the returned slice.
func (r *roster) get(ctx context.Context) ([]discover.Host, error) {
	r.mu.Lock()
	if r.inflight == nil && (r.triedAt.IsZero() || time.Since(r.triedAt) >= r.ttl) {
		r.inflight = make(chan struct{})
		go r.ask(r.inflight)
	}
	hosts, have, err, running := r.hosts, !r.gotAt.IsZero(), r.err, r.inflight
	r.mu.Unlock()
	if have {
		return hosts, nil
	}
	if running == nil {
		return nil, err // the last ask failed less than ttl ago
	}

	wait := time.NewTimer(r.firstWait)
	defer wait.Stop()
	select {
	case <-running:
	case <-wait.C:
		return nil, fmt.Errorf("no answer from tailscale status after %v, still waiting", r.firstWait)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.gotAt.IsZero() {
		return nil, r.err
	}
	return r.hosts, nil
}

// ask runs one discovery. Detached from any request: the answer is for every
// later report, so no client going away may cancel it.
func (r *roster) ask(done chan struct{}) {
	ctx, cancel := context.WithTimeout(context.Background(), r.timeout)
	hosts, err := r.fn(ctx)
	cancel()

	r.mu.Lock()
	r.triedAt, r.err = time.Now(), err
	if err == nil {
		r.hosts, r.gotAt = hosts, r.triedAt
	}
	r.inflight = nil
	close(done)
	r.mu.Unlock()
}

// note is the line a report carries when its list is old because tailscale
// keeps failing: the machines shown are the ones known at that time. Empty
// while the list is current or only briefly behind.
func (r *roster) note() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err == nil || r.gotAt.IsZero() || time.Since(r.gotAt) < r.staleAfter {
		return ""
	}
	return fmt.Sprintf("tailscale status failing (%v); device list from %s", r.err, r.gotAt.Format("15:04"))
}
