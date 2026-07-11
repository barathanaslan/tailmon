// Package agent is the tailmon HTTP agent: it serves local stats to the
// tailnet. Security model: NO tokens, NO root — it binds ONLY to the
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

	"github.com/barathanaslan/tailmon/internal/sample"
	"github.com/barathanaslan/tailmon/internal/version"
)

// DefaultPort: 7020 (7012/7013/8765 are taken by other services here).
const DefaultPort = 7020

// Handler returns the agent's HTTP handler: GET /stats (optional ?top=N,
// clamped to [1, MaxTopProcs], default DefaultTopProcs) and GET /health.
func Handler() http.Handler {
	c := &sampleCache{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) {
		n := sample.DefaultTopProcs
		if v := r.URL.Query().Get("top"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				n = sample.ClampTop(parsed)
			}
		}
		stats, err := c.get(r.Context())
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
			return
		}
		// Shallow copy + trim: the cached Stats is shared, never mutated.
		out := *stats
		if len(out.TopProcs) > n {
			out.TopProcs = out.TopProcs[:n]
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(&out)
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(sample.SelfStats())
	})
	return mux
}

// Run starts the agent and blocks until ctx is canceled, then shuts down
// gracefully. It binds 127.0.0.1:port plus every local Tailscale (CGNAT)
// address. When started at boot (SYSTEM task / launchd) the Tailscale
// interface may not have its address yet, so if no Tailscale bind succeeds
// initially, a retry loop keeps trying every 15s and exits after the first
// success — steady state runs no background work.
func Run(ctx context.Context, port int) error {
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
