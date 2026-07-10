// Package discover finds tailnet peers via `tailscale status --json`.
package discover

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// timeout bounds every tailscale CLI call.
const timeout = 2 * time.Second

// ErrNoTailscale: the tailscale CLI is not installed/found. Callers must
// degrade gracefully (monitor localhost only).
var ErrNoTailscale = errors.New("tailscale CLI not found")

// Host is one tailnet machine that could plausibly run a tailmon agent.
type Host struct {
	Name   string `json:"name"`
	IP     string `json:"ip"` // Tailscale IPv4 (100.64.0.0/10)
	OS     string `json:"os"` // tailscale's notion: "macOS", "windows", "linux"
	Online bool   `json:"online"`
	Self   bool   `json:"self"`
}

// tailscaleCandidates per the plan: PATH first, then the macOS app bundle.
var tailscaleCandidates = []string{
	"tailscale",
	"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
}

type tsPeer struct {
	HostName     string   `json:"HostName"`
	OS           string   `json:"OS"`
	Online       bool     `json:"Online"`
	TailscaleIPs []string `json:"TailscaleIPs"`
}

type tsStatus struct {
	Self *tsPeer            `json:"Self"`
	Peer map[string]*tsPeer `json:"Peer"`
}

// Hosts returns Self plus every peer whose OS could run a tailmon agent
// (macOS / windows / linux — phones and OS-less shared devices are skipped).
// Self is always first; peers are sorted by name.
func Hosts(ctx context.Context) ([]Host, error) {
	bin := findTailscale()
	if bin == "" {
		return nil, ErrNoTailscale
	}
	out, err := runTailscale(ctx, bin, "status", "--json")
	if err != nil {
		return nil, err
	}
	return parseStatus(out)
}

func parseStatus(out []byte) ([]Host, error) {
	var st tsStatus
	if err := json.Unmarshal(out, &st); err != nil {
		return nil, errors.New("tailscale status returned non-JSON output")
	}
	var hosts []Host
	if st.Self != nil {
		self := hostFromPeer(st.Self)
		self.Self = true
		self.Online = true // we are running on it
		hosts = append(hosts, self)
	}
	var peers []Host
	for _, p := range st.Peer {
		if !agentCapableOS(p.OS) {
			continue
		}
		peers = append(peers, hostFromPeer(p))
	}
	sort.Slice(peers, func(i, j int) bool { return peers[i].Name < peers[j].Name })
	return append(hosts, peers...), nil
}

func hostFromPeer(p *tsPeer) Host {
	return Host{
		Name:   strings.ToLower(p.HostName),
		IP:     firstIPv4(p.TailscaleIPs),
		OS:     p.OS,
		Online: p.Online,
	}
}

func agentCapableOS(os string) bool {
	switch strings.ToLower(os) {
	case "macos", "darwin", "windows", "linux":
		return true
	}
	return false
}

func firstIPv4(ips []string) string {
	for _, s := range ips {
		if a, err := netip.ParseAddr(s); err == nil && a.Is4() {
			return s
		}
	}
	return ""
}

func findTailscale() string {
	for _, c := range tailscaleCandidates {
		if p, err := exec.LookPath(c); err == nil {
			return p
		}
	}
	return ""
}

// runTailscale execs the CLI with a hard 2s timeout, null stdin, discarded
// stderr, and a proper wait (reap).
func runTailscale(ctx context.Context, bin string, args ...string) ([]byte, error) {
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, bin, args...)
	cmd.Stdin = nil
	return cmd.Output()
}
