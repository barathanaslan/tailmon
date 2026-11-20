package sample

import (
	"context"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func TestParseIoregDeviceUtil(t *testing.T) {
	// Captured from a real M3 Ultra: PerformanceStatistics is one long line.
	out := `"PerformanceStatistics" = {"In use system memory (driver)"=0,"Alloc system memory"=7113703424,"Tiler Utilization %"=7,"Renderer Utilization %"=6,"Device Utilization %"=7,"SplitSceneCount"=0}`
	v, ok := parseIoregDeviceUtil(out)
	if !ok || v != 7 {
		t.Errorf("got %v, %v; want 7, true", v, ok)
	}
	if _, ok := parseIoregDeviceUtil(`"SomethingElse" = 3`); ok {
		t.Error("absent key must report not-ok (util_pct null)")
	}
}

func TestParseIoregInUseMem(t *testing.T) {
	out := `"PerformanceStatistics" = {"In use system memory (driver)"=0,"In use system memory"=693125120,"Device Utilization %"=45}`
	v, ok := parseIoregInUseMem(out)
	if !ok || v != 693125120 {
		t.Errorf("got %v, %v", v, ok)
	}
	if _, ok := parseIoregInUseMem(`"In use system memory (driver)"=5`); ok {
		t.Error("the (driver) key must not match")
	}
}

func TestPressureFromLevel(t *testing.T) {
	for _, c := range []struct {
		lvl  int
		want string
	}{{94, "normal"}, {21, "normal"}, {20, "warn"}, {10, "warn"}, {9, "critical"}, {0, "critical"}} {
		if got := pressureFromLevel(c.lvl); got == nil || *got != c.want {
			t.Errorf("%d: want %q, got %v", c.lvl, c.want, got)
		}
	}
}

func TestWholeDisk(t *testing.T) {
	for in, want := range map[string]string{"/dev/disk3s5": "disk3", "/dev/disk12s1s1": "disk12", "map auto_home": "", "/dev/disk4": "disk4"} {
		if got := wholeDisk(in); got != want {
			t.Errorf("wholeDisk(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestVolumeMount(t *testing.T) {
	const local = 0x1000 // MNT_LOCAL
	cases := []struct {
		mount, fs string
		flags     uint32
		want      bool
	}{
		{"/Volumes/Elements", "exfat", local, true},
		{"/Volumes/Backup", "apfs", local, true},
		{"/Volumes/Share", "smbfs", 0, false},
		{"/Volumes/Installer", "hfs", local | 0x00100000, false}, // nobrowse
		{"/System/Volumes/Data", "apfs", local, false},
		{"/Volumes/a/b", "apfs", local, false},
	}
	for _, c := range cases {
		if got := volumeMount(c.mount, c.fs, c.flags); got != c.want {
			t.Errorf("volumeMount(%q,%q) = %v, want %v", c.mount, c.fs, got, c.want)
		}
	}
}

func TestPlatformDisksDarwin(t *testing.T) {
	disks := platformDisks(context.Background())
	if len(disks) == 0 || disks[0].Mount != "/" || disks[0].Label != "HD" {
		t.Fatalf("root disk missing: %+v", disks)
	}
	d := disks[0]
	if d.TotalGB <= 0 || d.UsedGB <= 0 || d.Kind != KindInternal || d.FSType != "apfs" {
		t.Errorf("implausible root disk: %+v", d)
	}
}

// A .dmg opened the way Finder opens one (browsable, no nobrowse flag) is a
// disk image to IOKit and never listed as a disk; the internal disk is not.
func TestDiskImageNotListed(t *testing.T) {
	if testing.Short() {
		t.Skip("attaches a disk image")
	}
	img := filepath.Join(t.TempDir(), "tailmon-test.dmg")
	if out, err := exec.Command("/usr/bin/hdiutil", "create", "-size", "8m", "-fs", "APFS",
		"-volname", "TailmonTestImage", img).CombinedOutput(); err != nil {
		t.Skipf("hdiutil create: %v %s", err, out)
	}
	out, err := exec.Command("/usr/bin/hdiutil", "attach", "-noautoopen", img).CombinedOutput()
	if err != nil {
		t.Skipf("hdiutil attach: %v %s", err, out)
	}
	var dev, mount string
	for _, line := range strings.Split(string(out), "\n") {
		if f := strings.SplitN(line, "\t", 3); len(f) == 3 && strings.HasPrefix(strings.TrimSpace(f[2]), "/Volumes/") {
			dev, mount = strings.TrimSpace(f[0]), strings.TrimSpace(f[2])
		}
	}
	if dev == "" {
		t.Fatalf("no mounted volume in hdiutil output: %s", out)
	}
	t.Cleanup(func() { _ = exec.Command("/usr/bin/hdiutil", "detach", "-force", mount).Run() })

	if !isDiskImage(dev) {
		t.Errorf("isDiskImage(%q) = false for an attached .dmg", dev)
	}
	for _, d := range platformDisks(context.Background()) {
		if d.Mount == mount {
			t.Errorf("disk image listed as a disk: %+v", d)
		}
	}
	var root unix.Statfs_t
	if err := unix.Statfs("/System/Volumes/Data", &root); err != nil {
		t.Fatal(err)
	}
	if rootDev := cstr(root.Mntfromname[:]); isDiskImage(rootDev) {
		t.Errorf("isDiskImage(%q) = true for the internal disk", rootDev)
	}
	if isDiskImage("") || isDiskImage("map auto_home") || isDiskImage("/dev/disk999s9") {
		t.Error("non-devices and missing devices must report false")
	}
}
