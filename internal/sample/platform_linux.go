package sample

import (
	"context"
	"os"
	"strings"

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

var linuxRealFS = map[string]bool{
	"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true, "zfs": true,
	"ntfs": true, "ntfs3": true, "fuseblk": true, "exfat": true, "vfat": true, "f2fs": true,
}

// platformDisks reports real filesystems (from /proc/self/mounts, no
// subprocess): skips tmpfs/overlay/squashfs/loop/snap mounts and /boot*.
// Each device is reported once (bind mounts / btrfs subvolumes repeat it).
func platformDisks(ctx context.Context) []Disk {
	parts, err := disk.PartitionsWithContext(ctx, false)
	if err != nil {
		return []Disk{}
	}
	disks := []Disk{}
	seen := map[string]bool{}
	for _, p := range parts {
		if !linuxRealFS[p.Fstype] || seen[p.Device] ||
			strings.HasPrefix(p.Device, "/dev/loop") ||
			strings.HasPrefix(p.Mountpoint, "/boot") ||
			strings.HasPrefix(p.Mountpoint, "/snap/") {
			continue
		}
		du, err := disk.UsageWithContext(ctx, p.Mountpoint)
		if err != nil || du.Total == 0 {
			continue
		}
		seen[p.Device] = true
		kind := KindInternal
		if removableDev(p.Device) {
			kind = KindRemovable
		}
		label := p.Mountpoint
		if p.Mountpoint != "/" {
			label = p.Mountpoint[strings.LastIndexByte(p.Mountpoint, '/')+1:]
		}
		disks = append(disks, newDisk(p.Mountpoint, label, p.Fstype, kind, du.Total, du.Free))
	}
	return disks
}

// removableDev: /sys/block/<disk>/removable == 1 for the device's parent disk.
func removableDev(dev string) bool {
	name := strings.TrimPrefix(dev, "/dev/")
	for _, d := range []string{name, strings.TrimRight(name, "0123456789")} {
		if b, err := os.ReadFile("/sys/block/" + d + "/removable"); err == nil {
			return strings.TrimSpace(string(b)) == "1"
		}
	}
	return false
}

// physicalDiskName: /proc/diskstats lists partitions, loop, dm and md devices
// too; only whole disks backed by a real device have /sys/block/<n>/device.
func physicalDiskName(name string) bool {
	_, err := os.Stat("/sys/block/" + name + "/device")
	return err == nil
}
