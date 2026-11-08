package agent

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/process"
)

// TestSoak is the leak regression test this project exists for: hit /stats,
// /stats?lite=1 and /fleet (fanning out to a second in-process agent) 5,000
// times each against an in-process agent and assert (a) RSS growth stays
// under 10 MB and (b) the goroutine count returns to baseline. Runs in the
// default `go test ./...` (no build tags, no -short skip).
func TestSoak(t *testing.T) {
	s, srv, done := fleetServer(t)
	defer done()
	client := srv.Client()

	get := func(path string) error {
		resp, err := client.Get(srv.URL + path)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if _, err := io.Copy(io.Discard, resp.Body); err != nil {
			return err
		}
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("%s: status %d", path, resp.StatusCode)
		}
		return nil
	}

	// Warm up: a couple of real samples + request-path allocations so pools,
	// TLS of the transport, and gopsutil internals reach steady state before
	// the baseline is taken.
	paths := []string{"/stats", "/stats?lite=1", "/fleet?top=10"}
	for i := 0; i < 50; i++ {
		for _, p := range paths {
			if err := get(p); err != nil {
				t.Fatalf("warmup request %s failed: %v", p, err)
			}
		}
	}
	time.Sleep(1100 * time.Millisecond) // let the TTL lapse -> next batch resamples
	for _, p := range paths {
		if err := get(p); err != nil {
			t.Fatalf("warmup resample %s failed: %v", p, err)
		}
	}
	s.closeIdle()
	client.CloseIdleConnections()
	time.Sleep(100 * time.Millisecond)

	debug.FreeOSMemory()
	rssBefore := selfRSS(t)
	goroutinesBefore := runtime.NumGoroutine()

	for i := 0; i < 5000; i++ {
		for _, p := range paths {
			if err := get(p); err != nil {
				t.Fatalf("request %d %s failed: %v", i, p, err)
			}
		}
	}
	if err := get("/health"); err != nil {
		t.Fatalf("health failed: %v", err)
	}

	s.closeIdle()
	client.CloseIdleConnections()
	debug.FreeOSMemory()
	rssAfter := selfRSS(t)

	growthMB := float64(int64(rssAfter)-int64(rssBefore)) / (1024 * 1024)
	t.Logf("RSS before=%.1fMB after=%.1fMB growth=%.2fMB",
		float64(rssBefore)/(1024*1024), float64(rssAfter)/(1024*1024), growthMB)
	if growthMB >= 10 {
		t.Errorf("RSS grew %.2f MB over 3x5000 requests (limit 10 MB) — leak", growthMB)
	}

	// Goroutines must settle back to (near) baseline. Poll up to 5s: the
	// server's per-connection goroutines wind down asynchronously.
	deadline := time.Now().Add(5 * time.Second)
	var goroutinesAfter int
	for {
		goroutinesAfter = runtime.NumGoroutine()
		if goroutinesAfter <= goroutinesBefore || time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Logf("goroutines before=%d after=%d", goroutinesBefore, goroutinesAfter)
	if goroutinesAfter > goroutinesBefore+2 {
		t.Errorf("goroutines did not return to baseline: before=%d after=%d",
			goroutinesBefore, goroutinesAfter)
	}
}

func selfRSS(t *testing.T) uint64 {
	t.Helper()
	p, err := process.NewProcess(int32(os.Getpid()))
	if err != nil {
		t.Fatalf("self process: %v", err)
	}
	mi, err := p.MemoryInfo()
	if err != nil {
		t.Fatalf("memory info: %v", err)
	}
	return mi.RSS
}
