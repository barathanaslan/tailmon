package sample

import (
	"context"

	"github.com/shirou/gopsutil/v4/disk"
)

// loadAvg1: Windows has no load average — null, never fabricated.
func loadAvg1(_ context.Context) *float64 { return nil }

// memPressure: macOS-only concept — null on Windows.
func memPressure(_ context.Context) *string { return nil }

// nvidiaSMICandidates per the plan: PATH first, then the two well-known
// absolute install locations.
var nvidiaSMICandidates = []string{
	"nvidia-smi",
	`C:\Windows\System32\nvidia-smi.exe`,
	`C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe`,
}

func collectGPUs(ctx context.Context) []GPU {
	return queryNvidiaSMI(ctx, nvidiaSMICandidates)
}

// platformDisks reports every mounted fixed volume (C:\, E:\, ...).
func platformDisks(ctx context.Context) []Disk {
	parts, err := disk.PartitionsWithContext(ctx, false)
	if err != nil {
		return []Disk{}
	}
	disks := []Disk{}
	for _, p := range parts {
		du, err := disk.UsageWithContext(ctx, p.Mountpoint)
		if err != nil || du.Total == 0 {
			continue // empty drive letters, card readers, etc.
		}
		disks = append(disks, Disk{Mount: p.Mountpoint, FreeGB: bytesToGB1(du.Free), TotalGB: bytesToGB1(du.Total)})
	}
	return disks
}
