package sample

import (
	"os"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	dir, _ := os.MkdirTemp("", "tailmon-state-")
	os.Setenv("TAILMON_STATE_DIR", dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func TestRememberDisks(t *testing.T) {
	t.Setenv("TAILMON_STATE_DIR", t.TempDir())
	resetDiskMemo()
	defer resetDiskMemo()
	t0 := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	c := Disk{Mount: `C:\`, TotalGB: 930, FreeGB: 590, Kind: KindInternal}
	d := Disk{Mount: `D:\`, TotalGB: 16764, FreeGB: 15000, Label: "Elements", Kind: KindExternal}
	stick := Disk{Mount: `F:\`, TotalGB: 29, FreeGB: 3, Kind: KindRemovable}
	bigUSB := Disk{Mount: `G:\`, TotalGB: 1863, FreeGB: 100, Kind: KindRemovable}

	got := rememberDisks([]Disk{c, d, stick, bigUSB}, t0)
	if len(got) != 4 || got[1].Stale {
		t.Fatalf("all live, none stale: %+v", got)
	}

	// D: (disabled) and both USB devices gone; the agent restarts (reload
	// from the file).
	resetDiskMemo()
	got = rememberDisks([]Disk{c}, t0.Add(time.Hour))
	if len(got) != 3 {
		t.Fatalf("want C + stale D + stale G, got %+v", got)
	}
	if got[1].Mount != `D:\` || !got[1].Stale || got[1].SeenAt == nil || !got[1].SeenAt.Equal(t0) ||
		got[1].Label != "Elements" || got[1].FreeGB != 15000 {
		t.Errorf("stale D: %+v", got[1])
	}
	if got[2].Mount != `G:\` || !got[2].Stale {
		t.Errorf("a ~1 TB+ removable disk is remembered: %+v", got[2])
	}
	if got[0].Stale || got[0].SeenAt != nil {
		t.Errorf("live disk must not be stale: %+v", got[0])
	}

	// 31 days later D: is forgotten.
	got = rememberDisks([]Disk{c}, t0.Add(31*24*time.Hour))
	if len(got) != 1 {
		t.Errorf("entries unseen for 30 days must be dropped: %+v", got)
	}
}
