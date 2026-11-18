package tui

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/barathanaslan/tailmon/internal/aggregate"
	"github.com/barathanaslan/tailmon/internal/discover"
	"github.com/barathanaslan/tailmon/internal/sample"
)

func rowNamed(m *model, name string) *row {
	for _, r := range m.rows {
		if r.host.Name == name {
			return r
		}
	}
	return nil
}

// Tailscale's offline flag can be stale (aggregate/probe.go): a flagged
// offline host is still asked, an answering host stays live whatever the
// flag says, and only its silence makes it offline.
func TestFlaggedOfflineHostIsAskedAndTrusted(t *testing.T) {
	m := newModel(context.Background())
	hosts := []discover.Host{
		{Name: "self", IP: "10.0.0.1", Online: true, Self: true},
		{Name: "shared", IP: "10.0.0.2", Online: false},
	}
	// Commands are only counted, never run: nothing is dialed.
	if cmds := m.mergeHosts(hosts); len(cmds) != 2 {
		t.Fatalf("new hosts: %d asks, want 2 (the flagged-offline one too)", len(cmds))
	}
	shared := rowNamed(m, "shared")
	if shared.status != aggregate.StatusOffline {
		t.Fatalf("before any answer: %s", shared.status)
	}

	m.applyStats(statsMsg{name: "shared", stats: &sample.Stats{}})
	if shared.status != aggregate.StatusLive {
		t.Fatalf("after its answer: %s", shared.status)
	}
	m.mergeHosts(hosts) // discovery repeats the stale flag
	if shared.status != aggregate.StatusLive || shared.stats == nil {
		t.Fatalf("discovery overruled a live answer: %s", shared.status)
	}

	m.applyStats(statsMsg{name: "shared", err: errors.New("timeout")})
	if shared.status != aggregate.StatusOffline || shared.stats != nil {
		t.Fatalf("after going silent: %s", shared.status)
	}
	if wait := time.Until(shared.nextProbe); wait < aggregate.ProbeInterval-time.Second {
		t.Fatalf("silent flagged-offline host is asked again in %v", wait)
	}

	// Inside the backoff it is left alone; after it, asked again.
	m.applyStats(statsMsg{name: "self", stats: &sample.Stats{}})
	m.lastDiscover = time.Now()
	if cmds := m.refreshCmds(false); len(cmds) != 1 {
		t.Fatalf("inside the backoff: %d asks, want 1 (self only)", len(cmds))
	}
	m.applyStats(statsMsg{name: "self", stats: &sample.Stats{}})
	shared.nextProbe = time.Now().Add(-time.Second)
	if cmds := m.refreshCmds(false); len(cmds) != 2 {
		t.Fatalf("after the backoff: %d asks, want 2", len(cmds))
	}
}

// An online host whose agent stops answering is "no agent", not offline.
func TestOnlineHostWithoutAnswerIsNoAgent(t *testing.T) {
	m := newModel(context.Background())
	m.mergeHosts([]discover.Host{{Name: "peer", IP: "10.0.0.2", Online: true}})
	peer := rowNamed(m, "peer")
	m.applyStats(statsMsg{name: "peer", stats: &sample.Stats{}})
	m.applyStats(statsMsg{name: "peer", err: errors.New("refused")})
	if peer.status != aggregate.StatusNoAgent {
		t.Fatalf("status %s", peer.status)
	}
}
