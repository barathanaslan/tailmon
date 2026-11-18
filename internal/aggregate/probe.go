package aggregate

import (
	"sync"
	"time"

	"github.com/barathanaslan/tailmon/internal/discover"
)

// Tailscale's Online flag is a hint, not the truth. For a device shared in
// from another tailnet the flag can stay "offline" while the device is up and
// its agent answers (2026-11-18: both shared peers "offline, last seen 40m
// ago" in `tailscale status`, both answering on :7020). So a peer flagged
// offline is still asked, and only its answer decides between live and
// offline.
//
// Asking a peer that really is off costs a whole request timeout (tailscale
// blackholes its address), and every ask makes tailscale try to reach it. A
// long-lived caller therefore keeps a Probes: a flagged-offline peer that did
// not answer last time is asked at most once per ProbeInterval, in the
// background, so no report ever waits for it; one that did answer is asked
// like any online peer.

// ProbeInterval: how often a silent, flagged-offline peer is asked again.
const ProbeInterval = 15 * time.Second

// Probes remembers, per peer, whether its agent answered the last time it was
// asked. Bounded: one small entry per current peer.
type Probes struct {
	mu sync.Mutex
	m  map[string]*probeState // by tailnet IP
}

type probeState struct {
	alive  bool      // the agent answered the last ask
	asking bool      // a background ask is running
	next   time.Time // earliest next background ask
}

func NewProbes() *Probes { return &Probes{m: map[string]*probeState{}} }

// alive reports whether ip answered its last ask.
func (p *Probes) alive(ip string) bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	st := p.m[ip]
	return st != nil && st.alive
}

// begin reports whether a background ask of ip may start now, and marks it
// started. At most one runs per peer, and none before the interval is over.
func (p *Probes) begin(ip string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	st := p.m[ip]
	if st == nil {
		st = &probeState{}
		p.m[ip] = st
	}
	if st.asking || now.Before(st.next) {
		return false
	}
	st.asking = true
	return true
}

// record stores the outcome of an ask (background or not).
func (p *Probes) record(ip string, answered bool, now time.Time) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	st := p.m[ip]
	if st == nil {
		st = &probeState{}
		p.m[ip] = st
	}
	st.alive, st.asking, st.next = answered, false, now.Add(ProbeInterval)
}

// keep drops the state of peers that left the tailnet.
func (p *Probes) keep(hosts []discover.Host) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	current := make(map[string]bool, len(hosts))
	for _, h := range hosts {
		current[h.IP] = true
	}
	for ip := range p.m {
		if !current[ip] {
			delete(p.m, ip)
		}
	}
}
