package sample

import (
	"context"
	"regexp"
	"strconv"
	"strings"

	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/load"
)

// loadAvg1 returns the 1-minute load average.
func loadAvg1(ctx context.Context) *float64 {
	la, err := load.AvgWithContext(ctx)
	if err != nil {
		return nil
	}
	v := round1(la.Load1)
	return &v
}

var freePctRe = regexp.MustCompile(`System-wide memory free percentage:\s*(\d+)%`)

// memPressure buckets `memory_pressure -Q` output into normal/warn/critical.
// The command prints e.g. "System-wide memory free percentage: 94%".
// Buckets: >20% free = normal, 10-20% = warn, <10% = critical — approximates
// where macOS itself flips its pressure state. Nil if the command is missing.
func memPressure(ctx context.Context) *string {
	out, err := runCmd(ctx, "/usr/bin/memory_pressure", "-Q")
	if err != nil {
		return nil
	}
	return pressureFromFreePct(string(out))
}

func pressureFromFreePct(out string) *string {
	m := freePctRe.FindStringSubmatch(out)
	if m == nil {
		return nil
	}
	freePct, err := strconv.Atoi(m[1])
	if err != nil {
		return nil
	}
	var level string
	switch {
	case freePct > 20:
		level = "normal"
	case freePct >= 10:
		level = "warn"
	default:
		level = "critical"
	}
	return &level
}

var deviceUtilRe = regexp.MustCompile(`"Device Utilization %"\s*=\s*(\d+)`)

// collectGPUs reads Apple Silicon GPU utilization from the IOAccelerator
// registry entry — works WITHOUT root (unlike powermetrics). Unified memory:
// vram_* stay null; util is real. If the key is absent, util_pct is null.
func collectGPUs(ctx context.Context) []GPU {
	out, err := runCmd(ctx, "/usr/sbin/ioreg", "-r", "-d", "1", "-c", "IOAccelerator")
	if err != nil {
		return []GPU{}
	}
	g := GPU{Name: gpuName(ctx)}
	if util, ok := parseIoregDeviceUtil(string(out)); ok {
		g.UtilPct = &util
	}
	return []GPU{g}
}

// parseIoregDeviceUtil extracts "Device Utilization %" from the
// PerformanceStatistics dict in `ioreg -r -d 1 -c IOAccelerator` output.
func parseIoregDeviceUtil(out string) (float64, bool) {
	m := deviceUtilRe.FindStringSubmatch(out)
	if m == nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

// gpuName: the Apple Silicon GPU shares the SoC name ("Apple M3 Ultra").
func gpuName(ctx context.Context) string {
	out, err := runCmd(ctx, "/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string")
	if err != nil {
		return "Apple GPU"
	}
	name := strings.TrimSpace(string(out))
	if name == "" {
		return "Apple GPU"
	}
	return name
}

// platformDisks reports the root volume only.
func platformDisks(ctx context.Context) []Disk {
	du, err := disk.UsageWithContext(ctx, "/")
	if err != nil {
		return []Disk{}
	}
	return []Disk{{Mount: "/", FreeGB: bytesToGB1(du.Free), TotalGB: bytesToGB1(du.Total)}}
}
