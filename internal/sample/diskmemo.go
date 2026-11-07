package sample

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"time"
)

// The agent remembers the last good reading of every volume it has seen, on
// disk, so a drive that is asleep or switched off (the box's WD D: is
// disabled most of the time) still shows up — marked stale, with its last
// numbers — for every viewer, even one that never saw it live.
//
// What is remembered: every non-removable volume, plus removable ones of
// about 1 TB or more (big USB disks that come and go by design); small sticks
// and cards are not. Entries unseen for 30 days are dropped; at most
// diskMemoMax entries are kept. The file is rewritten only when the set of
// volumes changes or the stored reading is older than diskMemoWriteEvery.
//
// Location: %ProgramData%\tailmon\disks.json on Windows (the agent runs as
// SYSTEM), <user cache dir>/tailmon/disks.json elsewhere. TAILMON_STATE_DIR
// overrides the directory (tests).
const (
	diskMemoMax        = 32
	diskMemoRetention  = 30 * 24 * time.Hour
	diskMemoWriteEvery = 10 * time.Minute
	diskMemoBigGB      = 900 // ~1 TB in GiB
)

type diskMemoEntry struct {
	Disk   Disk      `json:"disk"`
	SeenAt time.Time `json:"seen_at"`
}

var diskMemo struct {
	sync.Mutex
	loaded  bool
	entries map[string]diskMemoEntry // by mount
	written time.Time
}

func diskMemoPath() string {
	if d := os.Getenv("TAILMON_STATE_DIR"); d != "" {
		return filepath.Join(d, "disks.json")
	}
	if runtime.GOOS == "windows" {
		if pd := os.Getenv("ProgramData"); pd != "" {
			return filepath.Join(pd, "tailmon", "disks.json")
		}
	}
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "tailmon", "disks.json")
}

func rememberable(d Disk) bool {
	return d.Kind != KindRemovable || d.TotalGB >= diskMemoBigGB
}

// rememberDisks records the live volumes and appends remembered volumes that
// are absent now, marked stale. Bounded state; never fails the sample.
func rememberDisks(live []Disk, now time.Time) []Disk {
	diskMemo.Lock()
	defer diskMemo.Unlock()
	path := diskMemoPath()
	if !diskMemo.loaded {
		diskMemo.loaded = true
		diskMemo.entries = map[string]diskMemoEntry{}
		if b, err := os.ReadFile(path); err == nil && path != "" {
			var stored []diskMemoEntry
			if json.Unmarshal(b, &stored) == nil {
				for _, e := range stored {
					diskMemo.entries[e.Disk.Mount] = e
				}
			}
		}
	}

	changed := false
	liveMounts := map[string]bool{}
	for _, d := range live {
		liveMounts[d.Mount] = true
		if !rememberable(d) {
			if _, ok := diskMemo.entries[d.Mount]; ok {
				delete(diskMemo.entries, d.Mount) // that letter/mount is now a stick
				changed = true
			}
			continue
		}
		if _, ok := diskMemo.entries[d.Mount]; !ok {
			changed = true
		}
		d.Stale, d.SeenAt = false, nil
		diskMemo.entries[d.Mount] = diskMemoEntry{Disk: d, SeenAt: now}
	}
	for m, e := range diskMemo.entries {
		if now.Sub(e.SeenAt) > diskMemoRetention {
			delete(diskMemo.entries, m)
			changed = true
		}
	}
	if len(diskMemo.entries) > diskMemoMax { // drop the longest-unseen
		all := make([]diskMemoEntry, 0, len(diskMemo.entries))
		for _, e := range diskMemo.entries {
			all = append(all, e)
		}
		sort.Slice(all, func(i, j int) bool { return all[i].SeenAt.After(all[j].SeenAt) })
		for _, e := range all[diskMemoMax:] {
			delete(diskMemo.entries, e.Disk.Mount)
		}
		changed = true
	}

	out := live
	var absent []Disk
	for m, e := range diskMemo.entries {
		if liveMounts[m] {
			continue
		}
		d := e.Disk
		seen := e.SeenAt
		d.Stale, d.SeenAt = true, &seen
		absent = append(absent, d)
	}
	sort.Slice(absent, func(i, j int) bool { return absent[i].Mount < absent[j].Mount })
	out = append(out, absent...)

	if path != "" && (changed || now.Sub(diskMemo.written) >= diskMemoWriteEvery) {
		writeDiskMemo(path)
		diskMemo.written = now
	}
	return out
}

func writeDiskMemo(path string) {
	all := make([]diskMemoEntry, 0, len(diskMemo.entries))
	for _, e := range diskMemo.entries {
		all = append(all, e)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].Disk.Mount < all[j].Disk.Mount })
	b, err := json.MarshalIndent(all, "", " ")
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	tmp := path + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, path)
	}
}

// resetDiskMemo is for tests.
func resetDiskMemo() {
	diskMemo.Lock()
	diskMemo.loaded, diskMemo.entries, diskMemo.written = false, nil, time.Time{}
	diskMemo.Unlock()
}
