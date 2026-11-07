// Package agent is the tailmon HTTP agent: it serves local stats to the
// tailnet, and the whole-fleet report to the menu bar app on loopback. Security model: NO tokens, NO root — it binds ONLY to the
// machine's Tailscale IP and 127.0.0.1; tailnet membership is the perimeter
// (monitor-only, read-only data).
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"time"

	"github.com/barathanaslan/tailmon/internal/aggregate"
	"github.com/barathanaslan/tailmon/internal/discover"
	"github.com/barathanaslan/tailmon/internal/port"
	"github.com/barathanaslan/tailmon/internal/sample"
	"github.com/barathanaslan/tailmon/internal/version"
)

// DefaultPort is the agent's TCP port (see package port).
const DefaultPort = port.Default

// Cache timeouts: one sample is bounded by 10s (the sampler's subprocesses
// carry their own 2s timeouts); one fleet report by the per-peer request
// timeout plus discovery.
const (
	sampleTimeout   = 10 * time.Second
	fleetTimeout    = 8 * time.Second
	discoverTTL     = 30 * time.Second
	discoverTimeout = 3 * time.Second
)

// config makes the handler testable: discovery and the peer port can be
// swapped out. The zero value means production behavior.
type config struct {
	hosts func(context.Context) ([]discover.Host, error)
	port  int
}

// server holds the agent's bounded state: one cached full sample, one cached
// lite sample, one cached discovery result, one cached fleet report.
type server struct {
	mux    *http.ServeMux
	full   *flight[*sample.Stats]
	lite   *flight[*sample.Stats]
	hosts  *flight[[]discover.Host]
	fleet  *flight[*aggregate.Report]
	client *http.Client
}

// Handler returns the agent's HTTP handler:
//
//	GET /stats         full sample (?top=N clamped to [1, MaxTopProcs], default DefaultTopProcs)
//	GET /stats?lite=1  no process enumeration (top_procs empty)
//	GET /health        the agent's own footprint
//	GET /fleet?top=N   the whole tailnet as one report — loopback clients only
func Handler() http.Handler { return newServer(config{}) }

func newServer(cfg config) *server {
	if cfg.hosts == nil {
		cfg.hosts = discover.Hosts
	}
	if cfg.port == 0 {
		cfg.port = port.Default
	}
	s := &server{mux: http.NewServeMux()}
	s.full = newFlight(cacheTTL, sampleTimeout, func(ctx context.Context) (*sample.Stats, error) {
		return sample.CollectTop(ctx, sample.MaxTopProcs)
	})
	s.lite = newFlight(cacheTTL, sampleTimeout, sample.CollectLite)
	s.hosts = newFlight(discoverTTL, discoverTimeout, cfg.hosts)
	// One long-lived client for peer fan-out: keep-alive to each peer, at
	// most one idle connection per peer, dropped after 30s idle.
	s.client = aggregate.NewClient()
	src := aggregate.Source{
		Hosts:  s.hosts.get,
		Local:  func(ctx context.Context, _ int) (*sample.Stats, error) { return s.full.get(ctx) },
		Port:   cfg.port,
		Client: s.client,
	}
	// Peers are always asked for MaxTopProcs so one cached report serves any
	// ?top=N (trimmed at marshal time) — no per-N cache state.
	s.fleet = newFlight(cacheTTL, fleetTimeout, func(ctx context.Context) (*aggregate.Report, error) {
		return src.Collect(ctx, sample.MaxTopProcs), nil
	})

	s.mux.HandleFunc("GET /stats", s.handleStats)
	s.mux.HandleFunc("GET /fleet", s.handleFleet)
	s.mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, sample.SelfStats())
	})
	return s
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

// closeIdle drops the fan-out client's idle peer connections (tests).
func (s *server) closeIdle() { s.client.CloseIdleConnections() }

func topParam(r *http.Request) int {
	if v := r.URL.Query().Get("top"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return sample.ClampTop(n)
		}
	}
	return sample.DefaultTopProcs
}

func (s *server) handleStats(w http.ResponseWriter, r *http.Request) {
	if lite := r.URL.Query().Get("lite"); lite == "1" || lite == "true" {
		stats, err := s.lite.get(r.Context())
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, stats)
		return
	}
	stats, err := s.full.get(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, trimProcs(stats, topParam(r)))
}

// handleFleet is for the menu bar app on this machine: loopback clients only,
// so a peer can never make this agent fan out across the tailnet.
func (s *server) handleFleet(w http.ResponseWriter, r *http.Request) {
	if !loopbackClient(r) {
		writeErr(w, http.StatusForbidden, errors.New("fleet is served to loopback clients only"))
		return
	}
	report, err := s.fleet.get(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	n := topParam(r)
	out := *report
	out.Hosts = make([]aggregate.HostResult, len(report.Hosts))
	for i, h := range report.Hosts {
		if h.Stats != nil {
			h.Stats = trimProcs(h.Stats, n)
		}
		out.Hosts[i] = h
	}
	writeJSON(w, &out)
}

// trimProcs returns a shallow copy with at most n top processes: cached
// values are shared and never mutated.
func trimProcs(st *sample.Stats, n int) *sample.Stats {
	out := *st
	if len(out.TopProcs) > n {
		out.TopProcs = out.TopProcs[:n]
	}
	return &out
}

func loopbackClient(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	a, err := netip.ParseAddr(host)
	return err == nil && a.Unmap().IsLoopback()
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

// Run starts the agent and blocks until ctx is canceled, then shuts down
// gracefully. It binds 127.0.0.1:port plus every local Tailscale (CGNAT)
// address. When started at boot (SYSTEM task / launchd) the Tailscale
// interface may not have its address yet, so if no Tailscale bind succeeds
// initially, a retry loop keeps trying every 15s and exits after the first
// success — steady state runs no background work.
func Run(ctx context.Context, port int) error {
	if err := lowerPriority(); err != nil {
		log.Printf("tailmon agent: cannot lower priority (%v)", err)
	}
	srv := &http.Server{
		Handler:           Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 8)
	bound := map[string]bool{}
	bind := func(addr string) bool {
		if bound[addr] {
			return true
		}
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			log.Printf("tailmon agent: cannot bind %s (%v)", addr, err)
			return false
		}
		bound[addr] = true
		log.Printf("tailmon agent %s listening on %s", version.Version, ln.Addr())
		go func() {
			if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
				select {
				case errCh <- err:
				default:
				}
			}
		}()
		return true
	}

	bindTailscale := func() bool {
		ok := false
		for _, ip := range tailscaleIPs() {
			if bind(fmt.Sprintf("%s:%d", ip, port)) {
				ok = true
			}
		}
		return ok
	}

	if !bind(fmt.Sprintf("127.0.0.1:%d", port)) {
		return fmt.Errorf("cannot bind 127.0.0.1:%d", port)
	}
	if !bindTailscale() {
		log.Printf("tailmon agent: no Tailscale address yet — retrying every 15s")
		go func() {
			t := time.NewTicker(15 * time.Second)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					if bindTailscale() {
						return
					}
				}
			}
		}()
	}

	select {
	case <-ctx.Done():
		shCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		log.Printf("tailmon agent: shutting down")
		return srv.Shutdown(shCtx)
	case err := <-errCh:
		return err
	}
}

var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// tailscaleIPs finds local IPv4 addresses in the Tailscale CGNAT range by
// walking the interfaces — no dependency on the tailscale CLI.
func tailscaleIPs() []string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	var out []string
	for _, a := range addrs {
		ipNet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip4 := ipNet.IP.To4()
		if ip4 == nil {
			continue
		}
		if addr, ok := netip.AddrFromSlice(ip4); ok && cgnat.Contains(addr) {
			out = append(out, addr.String())
		}
	}
	return out
}
