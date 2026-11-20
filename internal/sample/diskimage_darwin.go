package sample

import (
	"strings"
	"sync"

	"github.com/ebitengine/purego"
)

// Disk images (.dmg, .sparsebundle, RAM disks) look like ordinary local
// volumes in the mount table: a .dmg opened from Finder has no nobrowse flag,
// so it used to show as a disk. macOS tells them apart in the IORegistry: the
// block device under every image carries "Protocol Characteristics" with
// "Physical Interconnect" = "Virtual Interface". isDiskImage asks IOKit for
// that, starting at the volume's BSD device and searching up through its
// parents (an APFS volume in an image sits on the image's partition).
//
// Plain IOKit/CoreFoundation calls through purego (already linked in by
// gopsutil): no cgo, no subprocess, a few microseconds per volume. Every
// object created here is released before returning.

const (
	cfStringEncodingUTF8      = 0x08000100
	ioRegistryIterateRecurse  = 1
	ioRegistryIterateParents  = 2
	virtualInterconnect       = "Virtual Interface"
	interconnectKey           = "Physical Interconnect"
	protocolCharacteristicKey = "Protocol Characteristics"
)

var iokit struct {
	once sync.Once
	ok   bool

	bsdNameMatching    func(mainPort, options uint32, bsdName string) uintptr
	getMatchingService func(mainPort uint32, matching uintptr) uint32
	searchCFProperty   func(entry uint32, plane string, key, allocator uintptr, options uint32) uintptr
	objectRelease      func(object uint32) int32

	cfStringCreate     func(alloc uintptr, cStr string, encoding uint32) uintptr
	cfRelease          func(cf uintptr)
	cfGetTypeID        func(cf uintptr) uintptr
	cfDictionaryTypeID func() uintptr
	cfStringTypeID     func() uintptr
	cfDictionaryGet    func(dict, key uintptr) uintptr
	cfStringGetCString func(s uintptr, buf *byte, size int64, encoding uint32) bool
}

func loadIOKit() bool {
	iokit.once.Do(func() {
		io, err := purego.Dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			return
		}
		cf, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_LAZY|purego.RTLD_GLOBAL)
		if err != nil {
			return
		}
		purego.RegisterLibFunc(&iokit.bsdNameMatching, io, "IOBSDNameMatching")
		purego.RegisterLibFunc(&iokit.getMatchingService, io, "IOServiceGetMatchingService")
		purego.RegisterLibFunc(&iokit.searchCFProperty, io, "IORegistryEntrySearchCFProperty")
		purego.RegisterLibFunc(&iokit.objectRelease, io, "IOObjectRelease")
		purego.RegisterLibFunc(&iokit.cfStringCreate, cf, "CFStringCreateWithCString")
		purego.RegisterLibFunc(&iokit.cfRelease, cf, "CFRelease")
		purego.RegisterLibFunc(&iokit.cfGetTypeID, cf, "CFGetTypeID")
		purego.RegisterLibFunc(&iokit.cfDictionaryTypeID, cf, "CFDictionaryGetTypeID")
		purego.RegisterLibFunc(&iokit.cfStringTypeID, cf, "CFStringGetTypeID")
		purego.RegisterLibFunc(&iokit.cfDictionaryGet, cf, "CFDictionaryGetValue")
		purego.RegisterLibFunc(&iokit.cfStringGetCString, cf, "CFStringGetCString")
		iokit.ok = true
	})
	return iokit.ok
}

// isDiskImage: true when the device ("/dev/disk5s1" or "disk5s1") is backed
// by a disk image. False when it is not, or when IOKit cannot say.
func isDiskImage(dev string) bool {
	bsd := strings.TrimPrefix(dev, "/dev/")
	if !strings.HasPrefix(bsd, "disk") || !loadIOKit() {
		return false
	}
	// IOServiceGetMatchingService consumes the matching dictionary.
	matching := iokit.bsdNameMatching(0, 0, bsd)
	if matching == 0 {
		return false
	}
	media := iokit.getMatchingService(0, matching)
	if media == 0 {
		return false
	}
	defer iokit.objectRelease(media)

	key := iokit.cfStringCreate(0, protocolCharacteristicKey, cfStringEncodingUTF8)
	if key == 0 {
		return false
	}
	defer iokit.cfRelease(key)
	props := iokit.searchCFProperty(media, "IOService", key, 0, ioRegistryIterateRecurse|ioRegistryIterateParents)
	if props == 0 {
		return false
	}
	defer iokit.cfRelease(props)
	if iokit.cfGetTypeID(props) != iokit.cfDictionaryTypeID() {
		return false
	}

	ikey := iokit.cfStringCreate(0, interconnectKey, cfStringEncodingUTF8)
	if ikey == 0 {
		return false
	}
	defer iokit.cfRelease(ikey)
	val := iokit.cfDictionaryGet(props, ikey) // borrowed, not released
	if val == 0 || iokit.cfGetTypeID(val) != iokit.cfStringTypeID() {
		return false
	}
	buf := make([]byte, 64)
	if !iokit.cfStringGetCString(val, &buf[0], int64(len(buf)), cfStringEncodingUTF8) {
		return false
	}
	return cstr(buf) == virtualInterconnect
}
