package agent

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/barathanaslan/tailmon/internal/aggregate"
	"github.com/barathanaslan/tailmon/internal/discover"
	"github.com/barathanaslan/tailmon/internal/sample"
)

// fleetServer: an agent whose "tailnet" is itself (self), one live peer that
// is a second in-process agent, one offline peer, and extra peers a test adds.
func fleetServer(t *testing.T, extra ...discover.Host) (*server, *httptest.Server, func()) {
	t.Helper()
	peer := httptest.NewServer(Handler())
	_, portStr, _ := net.SplitHostPort(peer.Listener.Addr().String())
	peerPort, _ := strconv.Atoi(portStr)
	hosts := func(context.Context) ([]discover.Host, error) {
		return append([]discover.Host{
			{Name: "self", IP: "100.0.0.1", OS: "macOS", Online: true, Self: true},
			{Name: "peer", IP: "127.0.0.1", OS: "linux", Online: true},
			{Name: "gone", IP: goneIP, OS: "windows", Online: false},
		}, extra...), nil
	}
	// The offline peer is never dialed: nothing may leave the machine.
	fetch := func(ctx context.Context, c *http.Client, ip string, port, top int) (*sample.Stats, error) {
		if ip == goneIP {
			return nil, errors.New("unreachable")
		}
		return aggregate.FetchStats(ctx, c, ip, port, top)
	}
	s := newServer(config{hosts: hosts, port: peerPort, fetch: fetch})
	srv := httptest.NewServer(s)
	return s, srv, func() { srv.Close(); peer.Close() }
}

const goneIP = "100.0.0.3"

func getFleet(t *testing.T, srv *httptest.Server, q string) aggregate.Report {
	t.Helper()
	resp, err := srv.Client().Get(srv.URL + "/fleet" + q)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	var r aggregate.Report
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestFleet(t *testing.T) {
	_, srv, done := fleetServer(t)
	defer done()

	r := getFleet(t, srv, "?top=3")
	if len(r.Hosts) != 3 {
		t.Fatalf("want 3 hosts, got %d", len(r.Hosts))
	}
	byName := map[string]aggregate.HostResult{}
	for _, h := range r.Hosts {
		byName[h.Host] = h
	}
	if h := byName["self"]; h.Status != aggregate.StatusLive || h.Source != "local" || h.Stats == nil {
		t.Errorf("self: %+v", h)
	}
	if h := byName["peer"]; h.Status != aggregate.StatusLive || h.Stats == nil {
		t.Errorf("peer: %+v", h)
	}
	if h := byName["gone"]; h.Status != aggregate.StatusOffline || h.Stats != nil {
		t.Errorf("gone: %+v", h)
	}
	for _, h := range r.Hosts {
		if h.Stats != nil && len(h.Stats.TopProcs) > 3 {
			t.Errorf("%s: %d procs, want <= 3", h.Host, len(h.Stats.TopProcs))
		}
	}
	// Same cache window, bigger ask: the cached report must not be trimmed.
	r2 := getFleet(t, srv, "?top=10")
	for _, h := range r2.Hosts {
		if h.Host == "self" && len(h.Stats.TopProcs) <= 3 {
			t.Errorf("top=10 after top=3: self has %d procs", len(h.Stats.TopProcs))
		}
	}
}

// A peer tailscale reports offline while its agent answers (a stale flag, as
// seen on shared-in devices) is offline on the first report at most, then
// live: the agent asks it in the background and trusts the answer.
func TestFleetStaleOfflineFlag(t *testing.T) {
	_, srv, done := fleetServer(t, discover.Host{Name: "shared", IP: "localhost", OS: "linux", Online: false})
	defer done()

	deadline := time.Now().Add(10 * time.Second)
	for {
		for _, h := range getFleet(t, srv, "").Hosts {
			if h.Host == "shared" && h.Status == aggregate.StatusLive && h.Stats != nil {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("shared peer with a stale offline flag never became live")
		}
		time.Sleep(cacheTTL / 4)
	}
}

// /fleet must refuse anything that is not a loopback client: a peer must not
// be able to make this agent fan out across the tailnet.
func TestFleetLoopbackOnly(t *testing.T) {
	s := newServer(config{hosts: func(context.Context) ([]discover.Host, error) { return nil, nil }})
	for addr, want := range map[string]int{
		"100.64.1.2:5555":      http.StatusForbidden,
		"192.168.1.10:5555":    http.StatusForbidden,
		"[fd7a::1]:5555":       http.StatusForbidden,
		"garbage":              http.StatusForbidden,
		"127.0.0.1:5555":       http.StatusOK,
		"[::1]:5555":           http.StatusOK,
		"[::ffff:127.0.0.1]:1": http.StatusOK,
	} {
		req := httptest.NewRequest(http.MethodGet, "/fleet", nil)
		req.RemoteAddr = addr
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Errorf("%s: status %d, want %d", addr, rec.Code, want)
		}
	}
}

func TestStatsLite(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	resp, err := srv.Client().Get(srv.URL + "/stats?lite=1")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var s sample.Stats
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		t.Fatal(err)
	}
	if len(s.TopProcs) != 0 || s.Mem.TotalMB == 0 || len(s.Disks) == 0 {
		t.Errorf("lite: procs=%d mem=%d disks=%d", len(s.TopProcs), s.Mem.TotalMB, len(s.Disks))
	}
}
