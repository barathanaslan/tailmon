package sample

import (
	"context"

	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/load"
)

func loadAvg1(ctx context.Context) *float64 {
	la, err := load.AvgWithContext(ctx)
	if err != nil {
		return nil
	}
	v := round1(la.Load1)
	return &v
}

// memPressure: macOS-only concept — null on Linux.
func memPressure(_ context.Context) *string { return nil }

// collectGPUs: nvidia-smi if present, else no gpu entry. (WSL is NOT a
// target — the Windows agent runs native and sees the real host.)
func collectGPUs(ctx context.Context) []GPU {
	return queryNvidiaSMI(ctx, []string{"nvidia-smi"})
}

// platformDisks reports the root volume only.
func platformDisks(ctx context.Context) []Disk {
	du, err := disk.UsageWithContext(ctx, "/")
	if err != nil {
		return []Disk{}
	}
	return []Disk{{Mount: "/", FreeGB: bytesToGB1(du.Free), TotalGB: bytesToGB1(du.Total)}}
}
