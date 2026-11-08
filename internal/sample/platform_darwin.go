package sample

import (
	"context"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/shirou/gopsutil/v4/load"
	"golang.org/x/sys/unix"
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

// memPressure buckets kern.memorystatus_level (system-wide free memory %, the
// same number `memory_pressure -Q` prints) into normal/warn/critical. One
// sysctl — no subprocess. Nil if the sysctl is missing.
func memPressure(_ context.Context) *string {
	v, err := unix.SysctlUint32("kern.memorystatus_level")
	if err != nil {
		return nil
	}
	return pressureFromLevel(int(v))
}

// pressureFromLevel: >20% free = normal, 10-20% = warn, <10% = critical —
// approximates where macOS itself flips its pressure state.
func pressureFromLevel(freePct int) *string {
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

var (
	deviceUtilRe  = regexp.MustCompile(`"Device Utilization %"\s*=\s*(\d+)`)
	inUseSysMemRe = regexp.MustCompile(`"In use system memory"\s*=\s*(\d+)`)
)

// collectGPUs reads Apple Silicon GPU utilization and in-use memory from the
// IOAccelerator registry entry — works WITHOUT root (unlike powermetrics).
// This ioreg call is the only subprocess a macOS sample spawns. Unified
// memory: vram_used_mb is the GPU's share of system memory, vram_total_mb
// stays null.
func collectGPUs(ctx context.Context) []GPU {
	out, err := runCmd(ctx, "/usr/sbin/ioreg", "-r", "-d", "1", "-c", "IOAccelerator")
	if err != nil {
		return []GPU{}
	}
	g := GPU{Name: gpuName(), Unified: true}
	if util, ok := parseIoregDeviceUtil(string(out)); ok {
		g.UtilPct = &util
	}
	if b, ok := parseIoregInUseMem(string(out)); ok {
		mb := b / 1024 / 1024
		g.VRAMUsedMB = &mb
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

// parseIoregInUseMem extracts "In use system memory" (bytes). The regexp
// requires the closing quote, so "In use system memory (driver)" never matches.
func parseIoregInUseMem(out string) (uint64, bool) {
	m := inUseSysMemRe.FindStringSubmatch(out)
	if m == nil {
		return 0, false
	}
	v, err := strconv.ParseUint(m[1], 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

var (
	gpuNameOnce sync.Once
	gpuNameVal  string
)

// gpuName: the Apple Silicon GPU shares the SoC name ("Apple M3 Ultra").
// Read once per process via sysctl — it never changes.
func gpuName() string {
	gpuNameOnce.Do(func() {
		gpuNameVal = "Apple GPU"
		if v, err := unix.Sysctl("machdep.cpu.brand_string"); err == nil {
			if v = strings.TrimSpace(v); v != "" {
				gpuNameVal = v
			}
		}
	})
	return gpuNameVal
}

// realFSTypes are the volume formats reported besides the root volume.
var realFSTypes = map[string]bool{"apfs": true, "hfs": true, "exfat": true, "msdos": true, "ntfs": true}

// platformDisks reports the root volume as mount "/" labelled "HD" (usage
// from the Data volume, which is where user data lives on a sealed-system
// Mac) plus every real volume under /Volumes. getfsstat with MNT_NOWAIT
// returns the kernel's cached mount table without touching any filesystem.
func platformDisks(_ context.Context) []Disk {
	disks := []Disk{}
	var root unix.Statfs_t
	rootDev := ""
	if err := unix.Statfs("/System/Volumes/Data", &root); err == nil {
		disks = append(disks, statfsDisk("/", "HD", KindInternal, &root))
		rootDev = wholeDisk(cstr(root.Mntfromname[:]))
	} else if err := unix.Statfs("/", &root); err == nil {
		disks = append(disks, statfsDisk("/", "HD", KindInternal, &root))
	}

	n, err := unix.Getfsstat(nil, unix.MNT_NOWAIT)
	if err != nil || n <= 0 {
		return disks
	}
	buf := make([]unix.Statfs_t, n)
	n, err = unix.Getfsstat(buf, unix.MNT_NOWAIT)
	if err != nil {
		return disks
	}
	for i := 0; i < n; i++ {
		st := &buf[i]
		mount := cstr(st.Mntonname[:])
		if !volumeMount(mount, cstr(st.Fstypename[:]), st.Flags) {
			continue
		}
		// Refresh usage for this one volume (the NOWAIT table can be stale).
		var fresh unix.Statfs_t
		if err := unix.Statfs(mount, &fresh); err == nil {
			st = &fresh
		}
		kind := KindExternal
		switch {
		case st.Flags&unix.MNT_REMOVABLE != 0:
			kind = KindRemovable
		case rootDev != "" && wholeDisk(cstr(st.Mntfromname[:])) == rootDev:
			kind = KindInternal // another volume in the internal APFS container
		}
		disks = append(disks, statfsDisk(mount, path.Base(mount), kind, st))
	}
	return disks
}

// volumeMount: a user-visible local volume under /Volumes in a real format.
// Skips /System/Volumes/*, snapshots, nobrowse mounts (disk images mounted
// by installers/apps usually are) and network filesystems.
func volumeMount(mount, fstype string, flags uint32) bool {
	if !strings.HasPrefix(mount, "/Volumes/") || strings.Count(mount, "/") != 2 {
		return false
	}
	if !realFSTypes[fstype] {
		return false
	}
	if flags&unix.MNT_LOCAL == 0 || flags&unix.MNT_DONTBROWSE != 0 {
		return false
	}
	return true
}

func statfsDisk(mount, label, kind string, st *unix.Statfs_t) Disk {
	bs := uint64(st.Bsize)
	return newDisk(mount, label, cstr(st.Fstypename[:]), kind, st.Blocks*bs, st.Bavail*bs)
}

// wholeDisk: "/dev/disk3s5" -> "disk3"; "" when not a /dev/diskN device.
func wholeDisk(dev string) string {
	dev = strings.TrimPrefix(dev, "/dev/")
	if !strings.HasPrefix(dev, "disk") {
		return ""
	}
	i := len("disk")
	for i < len(dev) && dev[i] >= '0' && dev[i] <= '9' {
		i++
	}
	return dev[:i]
}

func cstr(b []byte) string {
	if i := strings.IndexByte(string(b), 0); i >= 0 {
		return string(b[:i])
	}
	return string(b)
}

// physicalDiskName: on darwin gopsutil reads statistics from the block
// storage drivers, which exist only for physical devices (disk0, external
// drives) — synthesized APFS containers never appear. Count them all.
func physicalDiskName(string) bool { return true }
