// Turkish UI strings and number formatting for the dropdown. Pure functions,
// unit-tested.
import Foundation

enum Fmt {
    /// "14%" from 10 up, "9.6%" / "0.2%" below.
    static func pct(_ v: Double) -> String {
        if v <= 0 { return "0%" }
        return v >= 9.95 ? String(format: "%.0f%%", v) : String(format: "%.1f%%", v)
    }

    /// GiB -> "18.9" (< 100) or "372" (>= 100).
    static func gb(_ g: Double) -> String {
        g >= 99.95 ? String(format: "%.0f", g) : String(format: "%.1f", g)
    }

    /// "18.9 / 32 G" — RAM and VRAM use one decimal for the used part.
    static func memPair(usedMb: UInt64, totalMb: UInt64) -> String {
        let used = Double(usedMb) / 1024, total = Double(totalMb) / 1024
        return String(format: "%.1f / %@ G", used, trimmed(total))
    }

    /// "3.1 G"
    static func mem(_ mb: UInt64) -> String { String(format: "%.1f G", Double(mb) / 1024) }

    /// Disk used/total: "372 / 494 G" below 1 TiB total, "1.2 / 1.8 T" above.
    static func diskPair(used: Double, total: Double) -> String {
        if total >= 1000 {
            return String(format: "%.1f / %.1f T", used / 1024, total / 1024)
        }
        return String(format: "%.0f / %.0f G", used, total)
    }

    /// Disk free: "122 G boş", "16.4 T boş".
    static func diskFree(_ free: Double) -> String {
        free >= 1000 ? String(format: "%.1f T boş", free / 1024) : String(format: "%.0f G boş", free)
    }

    /// Process RSS: "149 M", "11.2 G".
    static func procMem(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f G", mb / 1024) : String(format: "%.0f M", mb)
    }

    /// Bytes per second: "84 KB/s", "1.2 MB/s", "210 MB/s".
    static func rate(_ bps: Double) -> String {
        let kb = max(0, bps) / 1024
        if kb < 1000 { return String(format: "%.0f KB/s", kb) }
        let mb = kb / 1024
        if mb < 10 { return String(format: "%.1f MB/s", mb) }
        if mb < 1000 { return String(format: "%.0f MB/s", mb) }
        return String(format: "%.1f GB/s", mb / 1024)
    }

    /// Uptime: "23g 20s", "9s 12dk", "41dk".
    static func uptime(_ sec: UInt64) -> String {
        let d = sec / 86_400, h = (sec % 86_400) / 3_600, m = (sec % 3_600) / 60
        if d > 0 { return "\(d)g \(h)s" }
        if h > 0 { return "\(h)s \(m)dk" }
        return "\(m)dk"
    }

    /// Header data age: "2 sn önce", "3 dk önce".
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) sn önce" }
        return "\(s / 60) dk önce"
    }

    static func kind(_ k: String?) -> String? {
        switch k {
        case "internal": return "dahili"
        case "external": return "harici"
        case "removable": return "çıkarılabilir"
        case "network": return "ağ"
        default: return nil
        }
    }

    /// The disk's label-column text: "C" for Windows drives, "HD" for the Mac
    /// root, "/" for a Linux root, else the first two letters of the label.
    static func diskTag(_ d: Stats.Disk) -> String {
        let m = d.mount
        if m.count >= 2, m.dropFirst().hasPrefix(":"), let c = m.first, c.isLetter {
            return String(c).uppercased()
        }
        if m == "/" { return d.label == "HD" ? "HD" : "/" }
        let name = (d.label?.isEmpty == false ? d.label! : (m as NSString).lastPathComponent)
        return String(name.prefix(2)).uppercased()
    }

    /// Tooltip on the disk tag: "C: Windows · dahili", "HD · dahili".
    static func diskTooltip(_ d: Stats.Disk) -> String {
        var name = d.mount
        if let l = d.label, !l.isEmpty {
            if name.count == 3, name.hasSuffix(":\\") {
                name = String(name.prefix(2)) + " " + l
            } else if name == "/" && l == "HD" {
                name = "HD"
            } else {
                name = l
            }
        }
        var parts = [name]
        if let k = kind(d.kind) { parts.append(k) }
        if let f = d.fstype, !f.isEmpty { parts.append(f) }
        return parts.joined(separator: " · ")
    }

    static func shortGPUName(_ name: String) -> String {
        var n = name
        for p in ["NVIDIA GeForce ", "NVIDIA ", "AMD Radeon ", "Apple "] where n.hasPrefix(p) {
            n = String(n.dropFirst(p.count))
        }
        return n
    }

    /// A process whose name is just a version ("2.1.318": the claude CLI
    /// lives at .../claude/versions/2.1.318) is shown by its tool's name,
    /// taken from the nearest meaningful directory of its executable path.
    static func procName(_ p: Stats.Proc) -> String {
        guard isVersion(p.name), let cmd = p.command,
              let r = cmd.range(of: "/" + p.name) else { return p.name }
        let skip: Set<String> = ["versions", "version", "bin", "current", "releases", "libexec"]
        for c in cmd[..<r.lowerBound].split(separator: "/").reversed() {
            let c = String(c)
            if !skip.contains(c.lowercased()) && !isVersion(c) && !c.hasPrefix(".") { return c }
        }
        return p.name
    }

    static func isVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func osName(_ os: String?) -> String {
        switch (os ?? "").lowercased() {
        case "macos", "darwin": return "macOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        default: return os ?? "?"
        }
    }

    /// Totals read like the spec sheet: 31.84 -> "32" (within 2% of a whole
    /// number), 15.5 -> "15.5", 128.3 -> "128".
    static func trimmed(_ v: Double) -> String {
        let r = v.rounded()
        if v >= 100 || (r > 0 && abs(v - r) / r < 0.02) { return String(format: "%.0f", r) }
        return String(format: "%.1f", v)
    }
}
