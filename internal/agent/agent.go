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
	"time"

	"github.com/barathanaslan/studio-cli/internal/sample"
	"github.com/barathanaslan/studio-cli/internal/version"
)

// DefaultPort: 7020 (7012/7013/8765 are taken by other services here).
const DefaultPort = 7020

// Handler returns the agent's HTTP handler: GET /stats and GET /health.
func Handler() http.Handler {
	c := &sampleCache{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) {
		data, err := c.get(r.Context())
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(data)
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(sample.SelfStats())
	})
	return mux
}

// Run starts the agent and blocks until ctx is canceled, then shuts down
// gracefully. It binds 127.0.0.1:port plus every local Tailscale (CGNAT)
// address; if no Tailscale address exists it serves loopback only.
func Run(ctx context.Context, port int) error {
	addrs := []string{fmt.Sprintf("127.0.0.1:%d", port)}
	for _, ip := range tailscaleIPs() {
		addrs = append(addrs, fmt.Sprintf("%s:%d", ip, port))
	}

	srv := &http.Server{
		Handler:           Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	listeners := make([]net.Listener, 0, len(addrs))
	var lastBindErr error
	for _, addr := range addrs {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			lastBindErr = fmt.Errorf("bind %s: %w", addr, err)
			log.Printf("tailmon agent: cannot bind %s (%v)", addr, err)
			continue
		}
		listeners = append(listeners, ln)
	}
	if len(listeners) == 0 {
		return fmt.Errorf("no listenable addresses: %w", lastBindErr)
	}

	errCh := make(chan error, len(listeners))
	for _, ln := range listeners {
		log.Printf("tailmon agent %s listening on %s", version.Version, ln.Addr())
		go func(l net.Listener) {
			if err := srv.Serve(l); err != nil && !errors.Is(err, http.ErrServerClosed) {
				errCh <- err
			}
		}(ln)
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
