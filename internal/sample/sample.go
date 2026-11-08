// Package sample collects one point-in-time resource snapshot of the local
// machine. It is used by `tailmon sample` (one-shot), the HTTP agent, and the
// in-process local path of `tailmon json` / the TUI.
//
// Anti-leak rules honored here: no background tickers, no history, no global
// growth. One call = one bounded snapshot. All subprocess calls carry a 2s
// timeout, never inherit stdin, and are reaped via cmd.Run.
package sample

import (
	"context"
	"math"
	"os"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/mem"
	gnet "github.com/shirou/gopsutil/v4/net"
	"github.com/shirou/gopsutil/v4/process"

	"github.com/barathanaslan/tailmon/internal/version"
)

// SchemaVersion is bumped whenever the JSON shape changes incompatibly.
const SchemaVersion = 1

// cpuWindow is the measurement window shared by system CPU% and per-process
// CPU%. One sample therefore takes ~cpuWindow wall time.
const cpuWindow = 500 * time.Millisecond

// DefaultTopProcs / MaxTopProcs bound the top_procs list. The default keeps
// responses small; the hard cap keeps a hostile/typo'd ?top= from turning one
// sample into a full process-table dump.
const (
	DefaultTopProcs = 5
	MaxTopProcs     = 25
)

// ClampTop clamps a requested top-process count to [1, MaxTopProcs].
func ClampTop(n int) int {
	if n < 1 {
		return 1
	}
	if n > MaxTopProcs {
		return MaxTopProcs
	}
	return n
}

// commandMaxLen bounds the per-process command string (additive schema field;
// long argv lists get truncated with an ellipsis).
const commandMaxLen = 100

// Stats is the versioned snapshot served at /stats and printed by `sample`.
// Fields a platform cannot provide are null, never fabricated.
type Stats struct {
	Schema    int       `json:"schema"`
	Host      string    `json:"host"`
	OS        string    `json:"os"`
	Arch      string    `json:"arch"`
	SampledAt time.Time `json:"sampled_at"`
	UptimeSec uint64    `json:"uptime_sec"`
	CPU       CPU       `json:"cpu"`
	Mem       Mem       `json:"mem"`
	GPU       []GPU     `json:"gpu"`
	Disks     []Disk    `json:"disks"`
	Net       Net       `json:"net"`
	DiskIO    *DiskIO   `json:"disk_io,omitempty"` // additive (0.3.0)
	TopProcs  []Proc    `json:"top_procs"`
	Agent     Agent     `json:"agent"`
}

type CPU struct {
	Percent float64  `json:"percent"`
	Cores   int      `json:"cores"`
	Load1   *float64 `json:"load1"` // null on Windows
}

type Mem struct {
	TotalMB     uint64  `json:"total_mb"`
	UsedMB      uint64  `json:"used_mb"` // total - available (Activity Monitor's sense of "used")
	AvailableMB uint64  `json:"available_mb"`
	Pressure    *string `json:"pressure"` // macOS only: normal | warn | critical
	SwapUsedMB  uint64  `json:"swap_used_mb"`
}

type GPU struct {
	Name    string   `json:"name"`
	UtilPct *float64 `json:"util_pct"`
	// On unified-memory Macs vram_used_mb is the GPU's in-use share of system
	// memory and vram_total_mb is null (there is no separate pool).
	VRAMUsedMB  *uint64  `json:"vram_used_mb"`
	VRAMTotalMB *uint64  `json:"vram_total_mb"`
	TempC       *float64 `json:"temp_c"`
	// Additive (0.3.0). Unified: memory is shared with the CPU (Apple Silicon).
	Unified     bool     `json:"unified,omitempty"`
	PowerW      *float64 `json:"power_w,omitempty"`
	PowerLimitW *float64 `json:"power_limit_w,omitempty"`
	FanPct      *float64 `json:"fan_pct,omitempty"`
}

// Disk is one mounted volume. Free-space queries only (statfs /
// GetDiskFreeSpaceEx) — directories are never walked.
type Disk struct {
	Mount   string  `json:"mount"`
	FreeGB  float64 `json:"free_gb"`
	TotalGB float64 `json:"total_gb"`
	// Additive (0.3.0).
	UsedGB float64 `json:"used_gb,omitempty"` // omitted when 0: relayed old-agent disks must not read as empty
	Label  string  `json:"label,omitempty"`
	FSType string  `json:"fstype,omitempty"`
	Kind   string  `json:"kind,omitempty"` // internal | external | removable | network
	// Stale: the volume is absent right now (drive asleep, disabled, or
	// unplugged); the numbers are its last reading, taken at SeenAt.
	Stale  bool       `json:"stale,omitempty"`
	SeenAt *time.Time `json:"seen_at,omitempty"`
}

// Disk kinds.
const (
	KindInternal  = "internal"
	KindExternal  = "external"
	KindRemovable = "removable"
	KindNetwork   = "network"
)

// DiskIO: cumulative bytes since boot, summed over physical disks. Clients
// compute rates from two readings.
type DiskIO struct {
	ReadBytes  uint64 `json:"read_bytes"`
	WriteBytes uint64 `json:"write_bytes"`
}

type Net struct {
	RxBytes uint64 `json:"rx_bytes"` // cumulative counters since boot
	TxBytes uint64 `json:"tx_bytes"`
}

type Proc struct {
	PID    int32   `json:"pid"`
	Name   string  `json:"name"`
	CPUPct float64 `json:"cpu_pct"`
	MemMB  float64 `json:"mem_mb"`
	// Command is the (truncated) command line — additive schema-1 field,
	// omitted when the platform can't provide it cheaply.
	Command string `json:"command,omitempty"`
}

// Agent is the sampler's own footprint — the monitor must monitor itself.
type Agent struct {
	Version    string  `json:"version"`
	RSSMB      float64 `json:"rss_mb"`
	Goroutines int     `json:"goroutines"`
	UptimeSec  int64   `json:"uptime_sec"`
}

var processStart = time.Now()

// Collect gathers one snapshot with the default top-process count. It blocks
// for ~cpuWindow (the CPU measurement window). It never returns a nil *Stats
// together with a nil error.
func Collect(ctx context.Context) (*Stats, error) {
	return CollectTop(ctx, DefaultTopProcs)
}

// CollectTop is Collect with an explicit top-process count (clamped to
// [1, MaxTopProcs]).
func CollectTop(ctx context.Context, topN int) (*Stats, error) {
	return collect(ctx, ClampTop(topN), false)
}

// CollectLite is a snapshot WITHOUT process enumeration: cpu, mem, gpu,
// disks, net, disk_io, uptime, agent. top_procs is an empty list. CPU% comes
// from the counter delta since the previous sample (any kind) when that is
// recent; otherwise a short liteWindow is measured.
func CollectLite(ctx context.Context) (*Stats, error) {
	return collect(ctx, 0, true)
}

func collect(ctx context.Context, topN int, lite bool) (*Stats, error) {
	s := &Stats{
		Schema:   SchemaVersion,
		Host:     shortHostname(),
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		GPU:      []GPU{},
		Disks:    []Disk{},
		TopProcs: []Proc{},
	}

	if lite {
		pct, err := liteCPUPercent(ctx)
		if err != nil {
			return nil, err
		}
		s.CPU.Percent = round1(pct)
	} else {
		// --- CPU + per-process CPU share one measurement window. ---
		procs, _ := process.ProcessesWithContext(ctx)
		before, _ := cpuTimes(ctx)
		for _, p := range procs {
			_, _ = p.PercentWithContext(ctx, 0) // prime per-process deltas
		}
		select {
		case <-time.After(cpuWindow):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		if after, err := cpuTimes(ctx); err == nil {
			if before != nil {
				s.CPU.Percent = round1(busyPercent(*before, *after))
			}
			rememberCPU(*after)
		}
		s.TopProcs = topProcs(ctx, procs, topN)
	}
	if n, err := cpu.CountsWithContext(ctx, true); err == nil {
		s.CPU.Cores = n
	}
	s.CPU.Load1 = loadAvg1(ctx)

	// --- Memory. used = total - available: matches Activity Monitor and
	// avoids the "only 2GB used when it's really 8GB" misread. ---
	if vm, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		s.Mem.TotalMB = vm.Total / 1024 / 1024
		s.Mem.AvailableMB = vm.Available / 1024 / 1024
		if vm.Total > vm.Available {
			s.Mem.UsedMB = (vm.Total - vm.Available) / 1024 / 1024
		}
	}
	if sw, err := mem.SwapMemoryWithContext(ctx); err == nil {
		s.Mem.SwapUsedMB = sw.Used / 1024 / 1024
	}
	s.Mem.Pressure = memPressure(ctx)

	// --- Platform-specific GPU + disks. ---
	s.GPU = collectGPUs(ctx)
	s.Disks = rememberDisks(platformDisks(ctx), time.Now())
	s.DiskIO = diskIO(ctx)

	// --- Net counters (cumulative since boot). ---
	if io, err := gnet.IOCountersWithContext(ctx, false); err == nil && len(io) > 0 {
		s.Net.RxBytes = io[0].BytesRecv
		s.Net.TxBytes = io[0].BytesSent
	}

	if up, err := host.UptimeWithContext(ctx); err == nil {
		s.UptimeSec = up
	}

	s.Agent = SelfStats()
	s.SampledAt = time.Now().UTC()
	return s, nil
}

// SelfStats returns the running process's own footprint. Cheap: no subprocesses.
func SelfStats() Agent {
	a := Agent{
		Version:    version.Version,
		Goroutines: runtime.NumGoroutine(),
		UptimeSec:  int64(time.Since(processStart).Seconds()),
	}
	if p, err := process.NewProcess(int32(os.Getpid())); err == nil {
		if mi, err := p.MemoryInfo(); err == nil && mi != nil {
			a.RSSMB = round1(float64(mi.RSS) / 1024 / 1024)
		}
	}
	return a
}

// topProcs finishes the per-process CPU window primed in Collect and returns
// the top N by CPU. Name/RSS/command are only fetched for the winners.
func topProcs(ctx context.Context, procs []*process.Process, topN int) []Proc {
	type scored struct {
		p   *process.Process
		pct float64
	}
	scoredProcs := make([]scored, 0, len(procs))
	for _, p := range procs {
		pct, err := p.PercentWithContext(ctx, 0)
		if err != nil {
			continue // process vanished mid-window
		}
		scoredProcs = append(scoredProcs, scored{p, pct})
	}
	sort.Slice(scoredProcs, func(i, j int) bool { return scoredProcs[i].pct > scoredProcs[j].pct })

	top := make([]Proc, 0, topN)
	for _, sp := range scoredProcs {
		if len(top) == topN {
			break
		}
		name, err := sp.p.NameWithContext(ctx)
		if err != nil || name == "" {
			continue
		}
		entry := Proc{PID: sp.p.Pid, Name: name, CPUPct: round1(sp.pct)}
		if mi, err := sp.p.MemoryInfoWithContext(ctx); err == nil && mi != nil {
			entry.MemMB = round1(float64(mi.RSS) / 1024 / 1024)
		}
		if cl, err := sp.p.CmdlineWithContext(ctx); err == nil {
			entry.Command = shortCommand(cl)
		}
		top = append(top, entry)
	}
	return top
}

// shortCommand collapses a command line to one bounded single-spaced line.
// gopsutil reads it without subprocesses on all three platforms (sysctl on
// darwin, /proc on linux, PEB read on windows), so this stays cheap.
func shortCommand(cl string) string {
	cl = strings.Join(strings.Fields(cl), " ")
	if r := []rune(cl); len(r) > commandMaxLen {
		cl = string(r[:commandMaxLen-1]) + "…"
	}
	return cl
}

// shortHostname lowercases and strips the domain: "Barathans-MacStudio.local"
// -> "barathans-macstudio", matching tailscale HostName conventions.
func shortHostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "unknown"
	}
	h, _, _ = strings.Cut(h, ".")
	return strings.ToLower(h)
}

func round1(v float64) float64 {
	return math.Round(v*10) / 10
}

func bytesToGB1(b uint64) float64 {
	return round1(float64(b) / (1024 * 1024 * 1024))
}

// newDisk fills the derived fields from byte counts.
func newDisk(mount, label, fstype, kind string, total, free uint64) Disk {
	used := uint64(0)
	if total > free {
		used = total - free
	}
	return Disk{
		Mount: mount, Label: label, FSType: fstype, Kind: kind,
		TotalGB: bytesToGB1(total), FreeGB: bytesToGB1(free), UsedGB: bytesToGB1(used),
	}
}

// diskIO sums cumulative read/write bytes over physical disks. One cheap
// kernel query (IOKit registry on darwin, /proc/diskstats on linux, perf
// counters on windows) — no subprocesses. Nil when unavailable.
func diskIO(ctx context.Context) *DiskIO {
	counters, err := disk.IOCountersWithContext(ctx)
	if err != nil || len(counters) == 0 {
		return nil
	}
	var out DiskIO
	n := 0
	for name, c := range counters {
		if !physicalDiskName(name) {
			continue
		}
		out.ReadBytes += c.ReadBytes
		out.WriteBytes += c.WriteBytes
		n++
	}
	if n == 0 {
		return nil
	}
	return &out
}
