package sample

import (
	"context"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
)

func TestBusyPercent(t *testing.T) {
	a := cpu.TimesStat{User: 10, System: 10, Idle: 80}
	b := cpu.TimesStat{User: 20, System: 15, Idle: 165} // +15 busy of +100 total
	if got := busyPercent(a, b); got < 14.99 || got > 15.01 {
		t.Errorf("busy = %v, want 15", got)
	}
	if got := busyPercent(b, a); got != 0 {
		t.Errorf("counter reset should give 0, got %v", got)
	}
}

// Lite samples must not enumerate processes and must still report a CPU%.
func TestCollectLite(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s, err := CollectLite(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.TopProcs) != 0 {
		t.Errorf("lite sample has %d procs, want none", len(s.TopProcs))
	}
	if s.TopProcs == nil {
		t.Error("top_procs must be an empty list, not null")
	}
	if s.CPU.Percent < 0 || s.CPU.Percent > 100 || s.Mem.TotalMB == 0 {
		t.Errorf("implausible lite sample: cpu=%v mem=%v", s.CPU.Percent, s.Mem.TotalMB)
	}
	// A second lite sample right after reuses the remembered counters only
	// once cpuPrevMinAge has passed; either way it must be fast.
	time.Sleep(cpuPrevMinAge)
	start := time.Now()
	if _, err := CollectLite(ctx); err != nil {
		t.Fatal(err)
	}
	if d := time.Since(start); d > liteWindow+500*time.Millisecond {
		t.Errorf("warm lite sample took %v", d)
	}
}
