package sample

import (
	"context"
	"errors"
	"math"
	"runtime"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
)

// liteWindow is the CPU measurement window a lite sample uses when there is
// no recent counter reading to diff against.
const liteWindow = 250 * time.Millisecond

// cpuPrevMaxAge: a remembered counter reading older than this is too stale to
// be a meaningful "current" CPU% and a fresh window is measured instead.
// cpuPrevMinAge: a reading this recent gives too short (noisy) a window.
const (
	cpuPrevMaxAge = 60 * time.Second
	cpuPrevMinAge = 200 * time.Millisecond
)

// cpuPrev is the ONE previous system-wide counter reading (bounded state, no
// history). Every sample, lite or full, updates it.
var cpuPrev struct {
	sync.Mutex
	t  cpu.TimesStat
	at time.Time
}

func cpuTimes(ctx context.Context) (*cpu.TimesStat, error) {
	ts, err := cpu.TimesWithContext(ctx, false)
	if err != nil {
		return nil, err
	}
	if len(ts) != 1 {
		return nil, errors.New("cpu times: unexpected shape")
	}
	return &ts[0], nil
}

func rememberCPU(t cpu.TimesStat) {
	cpuPrev.Lock()
	cpuPrev.t, cpuPrev.at = t, time.Now()
	cpuPrev.Unlock()
}

// liteCPUPercent: delta against the remembered reading when it is between
// cpuPrevMinAge and cpuPrevMaxAge old, else a liteWindow measurement.
func liteCPUPercent(ctx context.Context) (float64, error) {
	now, err := cpuTimes(ctx)
	if err != nil {
		return 0, err
	}
	cpuPrev.Lock()
	prev, at := cpuPrev.t, cpuPrev.at
	cpuPrev.Unlock()
	if age := time.Since(at); !at.IsZero() && age >= cpuPrevMinAge && age <= cpuPrevMaxAge {
		rememberCPU(*now)
		return busyPercent(prev, *now), nil
	}
	select {
	case <-time.After(liteWindow):
	case <-ctx.Done():
		return 0, ctx.Err()
	}
	after, err := cpuTimes(ctx)
	if err != nil {
		return 0, err
	}
	rememberCPU(*after)
	return busyPercent(*now, *after), nil
}

// busyPercent mirrors gopsutil's own calculation (cpu.calculateBusy) so the
// lite and full paths report the same number for the same window.
func busyPercent(t1, t2 cpu.TimesStat) float64 {
	t1All, t1Busy := allBusy(t1)
	t2All, t2Busy := allBusy(t2)
	if t2Busy <= t1Busy {
		return 0
	}
	if t2All <= t1All {
		return 100
	}
	return math.Min(100, math.Max(0, (t2Busy-t1Busy)/(t2All-t1All)*100))
}

func allBusy(t cpu.TimesStat) (total, busy float64) {
	total = t.Total()
	if runtime.GOOS == "linux" {
		total -= t.Guest + t.GuestNice
	}
	return total, total - t.Idle - t.Iowait
}
