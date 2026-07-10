package agent

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/barathanaslan/studio-cli/internal/sample"
)

// TestStatsTopParam: one cached max-depth sample must serve any ?top=N —
// different N within the TTL, invalid values fall back to the default.
func TestStatsTopParam(t *testing.T) {
	srv := httptest.NewServer(Handler())
	defer srv.Close()

	get := func(q string) sample.Stats {
		t.Helper()
		resp, err := srv.Client().Get(srv.URL + "/stats" + q)
		if err != nil {
			t.Fatalf("GET %s: %v", q, err)
		}
		defer resp.Body.Close()
		var s sample.Stats
		if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
			t.Fatalf("decode %s: %v", q, err)
		}
		return s
	}

	if n := len(get("?top=1").TopProcs); n != 1 {
		t.Errorf("top=1: got %d procs, want 1", n)
	}
	// Same TTL window, bigger ask: must not be capped by the earlier trim.
	if n := len(get("?top=25").TopProcs); n <= 1 {
		t.Errorf("top=25 after top=1: got %d procs, want >1", n)
	}
	if n := len(get("").TopProcs); n > sample.DefaultTopProcs {
		t.Errorf("default: got %d procs, want <= %d", n, sample.DefaultTopProcs)
	}
	if n := len(get("?top=9999").TopProcs); n > sample.MaxTopProcs {
		t.Errorf("top=9999: got %d procs, want <= %d (clamp)", n, sample.MaxTopProcs)
	}
	if n := len(get("?top=bogus").TopProcs); n > sample.DefaultTopProcs {
		t.Errorf("top=bogus: got %d procs, want default <= %d", n, sample.DefaultTopProcs)
	}
}
