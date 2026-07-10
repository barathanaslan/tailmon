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
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/mem"
	gnet "github.com/shirou/gopsutil/v4/net"
	"github.com/shirou/gopsutil/v4/process"

	"github.com/barathanaslan/studio-cli/internal/version"
)

// SchemaVersion is bumped whenever the JSON shape changes incompatibly.
const SchemaVersion = 1

// cpuWindow is the measurement window shared by system CPU% and per-process
// CPU%. One sample therefore takes ~cpuWindow wall time.
const cpuWindow = 500 * time.Millisecond

const topProcCount = 5

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
	Name        string   `json:"name"`
	UtilPct     *float64 `json:"util_pct"`
	VRAMUsedMB  *uint64  `json:"vram_used_mb"`  // null on unified-memory Macs
	VRAMTotalMB *uint64  `json:"vram_total_mb"` // null on unified-memory Macs
	TempC       *float64 `json:"temp_c"`
}

type Disk struct {
	Mount   string  `json:"mount"`
	FreeGB  float64 `json:"free_gb"`
	TotalGB float64 `json:"total_gb"`
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
}

// Agent is the sampler's own footprint — the monitor must monitor itself.
type Agent struct {
	Version    string  `json:"version"`
	RSSMB      float64 `json:"rss_mb"`
	Goroutines int     `json:"goroutines"`
	UptimeSec  int64   `json:"uptime_sec"`
}

var processStart = time.Now()

// Collect gathers one snapshot. It blocks for ~cpuWindow (the CPU measurement
// window). It never returns a nil *Stats together with a nil error.
func Collect(ctx context.Context) (*Stats, error) {
	s := &Stats{
		Schema:   SchemaVersion,
		Host:     shortHostname(),
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		GPU:      []GPU{},
		Disks:    []Disk{},
		TopProcs: []Proc{},
	}

	// --- CPU + per-process CPU share one measurement window. ---
	procs, _ := process.ProcessesWithContext(ctx)
	// Prime deltas: gopsutil computes percent-since-last-call for interval 0.
	_, _ = cpu.PercentWithContext(ctx, 0, false)
	for _, p := range procs {
		_, _ = p.PercentWithContext(ctx, 0)
	}
	select {
	case <-time.After(cpuWindow):
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if pcts, err := cpu.PercentWithContext(ctx, 0, false); err == nil && len(pcts) == 1 {
		s.CPU.Percent = round1(pcts[0])
	}
	if n, err := cpu.CountsWithContext(ctx, true); err == nil {
		s.CPU.Cores = n
	}
	s.CPU.Load1 = loadAvg1(ctx)
	s.TopProcs = topProcs(ctx, procs)

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
	s.Disks = platformDisks(ctx)

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
// the top N by CPU. Name/RSS are only fetched for the winners.
func topProcs(ctx context.Context, procs []*process.Process) []Proc {
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

	top := make([]Proc, 0, topProcCount)
	for _, sp := range scoredProcs {
		if len(top) == topProcCount {
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
		top = append(top, entry)
	}
	return top
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
