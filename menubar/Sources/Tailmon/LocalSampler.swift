// LocalSampler reads the menu bar label's numbers straight from the kernel:
// a few Mach/sysctl calls and one IORegistry property read. No HTTP, no
// subprocesses, no process scans — cheap enough to run every 5s with the
// menu closed. RAM math matches the agent (gopsutil darwin): available =
// (free + inactive) pages, used = total - available, so the label and the
// dropdown agree.
import Darwin
import Foundation
import IOKit

struct LocalSample: Equatable {
    var cpuPct: Double?
    var ramPct: Double?
    var pressure: String?
    var gpuPct: Double?
}

final class LocalSampler {
    private var prevTicks: [UInt32]?
    private var accelerator: io_object_t = 0

    deinit {
        if accelerator != 0 { IOObjectRelease(accelerator) }
    }

    func sample() -> LocalSample {
        LocalSample(cpuPct: cpuPercent(), ramPct: ramPercent(),
                    pressure: pressureLevel(), gpuPct: gpuPercent())
    }

    // MARK: CPU — delta of host-wide tick counters since the previous call.

    private func cpuPercent() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { prevTicks = ticks }
        guard let prev = prevTicks else { return nil }
        return Self.busyPercent(prev: prev, now: ticks)
    }

    /// ticks: [user, system, idle, nice] (CPU_STATE_* order). Counters are
    /// UInt32 and wrap; &- keeps the delta right across one wrap.
    static func busyPercent(prev: [UInt32], now: [UInt32]) -> Double? {
        guard prev.count == 4, now.count == 4 else { return nil }
        let d = zip(now, prev).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        let busy = total - d[Int(CPU_STATE_IDLE)]
        return min(100, max(0, 100 * busy / total))
    }

    // MARK: RAM

    private func ramPercent() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0, total > 0 else { return nil }
        let page = UInt64(vm_kernel_page_size)
        return Self.usedPercent(
            total: total, freePages: UInt64(stats.free_count),
            inactivePages: UInt64(stats.inactive_count), pageSize: page)
    }

    static func usedPercent(total: UInt64, freePages: UInt64, inactivePages: UInt64, pageSize: UInt64) -> Double {
        let available = min(total, (freePages + inactivePages) * pageSize)
        return 100 * Double(total - available) / Double(total)
    }

    // MARK: Pressure — kern.memorystatus_level is the free-memory %.

    private func pressureLevel() -> String? {
        var level: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return Self.pressure(freePct: Int(level))
    }

    /// Same buckets as the agent: >20% free normal, 10-20 warn, <10 critical.
    static func pressure(freePct: Int) -> String {
        if freePct > 20 { return "normal" }
        if freePct >= 10 { return "warn" }
        return "critical"
    }

    // MARK: GPU — IOAccelerator PerformanceStatistics["Device Utilization %"].

    private func gpuPercent() -> Double? {
        if accelerator == 0 { accelerator = Self.findAccelerator() }
        guard accelerator != 0 else { return nil }
        if let v = Self.deviceUtilization(accelerator) { return v }
        // The registry entry can be replaced (GPU driver restart): look again once.
        IOObjectRelease(accelerator)
        accelerator = Self.findAccelerator()
        return accelerator == 0 ? nil : Self.deviceUtilization(accelerator)
    }

    private static func findAccelerator() -> io_object_t {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iter) }
        while case let entry = IOIteratorNext(iter), entry != 0 {
            if deviceUtilization(entry) != nil { return entry }
            IOObjectRelease(entry)
        }
        return 0
    }

    private static func deviceUtilization(_ entry: io_object_t) -> Double? {
        guard let prop = IORegistryEntryCreateCFProperty(
            entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
            let v = prop["Device Utilization %"] as? NSNumber
        else { return nil }
        return v.doubleValue
    }
}
