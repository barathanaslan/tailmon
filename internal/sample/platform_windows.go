package sample

import (
	"context"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
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

// platformDisks reports every drive letter with a nonzero size, fixed and
// removable (C:\, D:\, E:\, ...). Network shares and optical drives are
// skipped. Per drive: GetDriveType, GetVolumeInformation (label + format) and
// GetDiskFreeSpaceEx — cached volume metadata, never a directory walk.
func platformDisks(_ context.Context) []Disk {
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return []Disk{}
	}
	disks := []Disk{}
	for i := 0; i < 26; i++ {
		if mask&(1<<uint(i)) == 0 {
			continue
		}
		root := string(rune('A'+i)) + `:\`
		rootPtr, _ := windows.UTF16PtrFromString(root)
		var kind string
		switch windows.GetDriveType(rootPtr) {
		case windows.DRIVE_FIXED:
			kind = KindInternal
			if usbBus(root[:2]) {
				kind = KindExternal
			}
		case windows.DRIVE_REMOVABLE:
			kind = KindRemovable
		default:
			continue // network, optical, ramdisk, unknown
		}
		var free, total, totalFree uint64
		if err := windows.GetDiskFreeSpaceEx(rootPtr, &free, &total, &totalFree); err != nil || total == 0 {
			continue // empty card readers etc.
		}
		label, fstype := volumeInfo(rootPtr)
		disks = append(disks, newDisk(root, label, strings.ToLower(fstype), kind, total, free))
	}
	return disks
}

func volumeInfo(root *uint16) (label, fstype string) {
	var name, fs [windows.MAX_PATH + 1]uint16
	if err := windows.GetVolumeInformation(root, &name[0], uint32(len(name)), nil, nil, nil, &fs[0], uint32(len(fs))); err != nil {
		return "", ""
	}
	return windows.UTF16ToString(name[:]), windows.UTF16ToString(fs[:])
}

// STORAGE_PROPERTY_QUERY / STORAGE_DEVICE_DESCRIPTOR (winioctl.h).
const ioctlStorageQueryProperty = 0x002D1400

type storagePropertyQuery struct {
	PropertyID uint32 // StorageDeviceProperty = 0
	QueryType  uint32 // PropertyStandardQuery = 0
	Extra      [1]byte
}

type storageDeviceDescriptor struct {
	Version               uint32
	Size                  uint32
	DeviceType            byte
	DeviceTypeModifier    byte
	RemovableMedia        byte
	CommandQueueing       byte
	VendorIDOffset        uint32
	ProductIDOffset       uint32
	ProductRevisionOffset uint32
	SerialNumberOffset    uint32
	BusType               uint32
	RawPropertiesLength   uint32
}

const busTypeUsb = 7

// usbBus reports whether the volume sits on a USB-attached disk (a "fixed"
// external drive). Opening the volume with zero access rights needs no
// privileges and does no disk I/O; the descriptor comes from the driver.
func usbBus(letter string) bool {
	p, _ := windows.UTF16PtrFromString(`\\.\` + letter)
	h, err := windows.CreateFile(p, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	q := storagePropertyQuery{}
	var buf [512]byte
	var n uint32
	if err := windows.DeviceIoControl(h, ioctlStorageQueryProperty,
		(*byte)(unsafe.Pointer(&q)), uint32(unsafe.Sizeof(q)),
		&buf[0], uint32(len(buf)), &n, nil); err != nil {
		return false
	}
	if n < uint32(unsafe.Sizeof(storageDeviceDescriptor{})) {
		return false
	}
	d := (*storageDeviceDescriptor)(unsafe.Pointer(&buf[0]))
	return d.BusType == busTypeUsb
}

// physicalDiskName: gopsutil's windows counters are per drive letter, one
// per volume; summing them is the per-disk total.
func physicalDiskName(string) bool { return true }
