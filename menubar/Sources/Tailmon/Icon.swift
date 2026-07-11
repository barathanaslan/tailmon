// Menu bar label rendering: Stats-style stacked CPU/GPU/RAM columns for the
// LOCAL machine (tightly packed — owner preference), followed by one letter
// per OTHER tailnet device colored by status (green live, orange no-agent,
// dim offline). Letters come from hostnames with the owner-name prefix
// stripped: "barathans-5070" -> 5, "barathan's macbook" -> M.
import AppKit

struct PeerBadge: Equatable {
    enum Status { case live, noAgent, offline, unknown }
    var letter: String
    var status: Status
}

struct IconInfo: Equatable {
    var cpu: Int?
    var gpu: Int?
    var ram: Int?
    var pressure: String?
    var peers: [PeerBadge]

    static func make(stats: Stats?, peers: [PeerBadge]) -> IconInfo {
        guard let s = stats else {
            return IconInfo(cpu: nil, gpu: nil, ram: nil, pressure: nil, peers: peers)
        }
        let ram = s.mem.totalMb > 0
            ? Int((100 * Double(s.mem.usedMb) / Double(s.mem.totalMb)).rounded()) : nil
        return IconInfo(
            cpu: Int(s.cpu.percent.rounded()),
            gpu: s.gpu?.first?.utilPct.map { Int($0.rounded()) },
            ram: ram,
            pressure: s.mem.pressure,
            peers: peers)
    }

    static func badgeLetter(for host: String) -> String {
        var h = host.lowercased()
        for p in ["barathans-", "barathan's ", "barathan\u{2019}s "] where h.hasPrefix(p) {
            h = String(h.dropFirst(p.count))
        }
        let first = h.first(where: { $0.isLetter || $0.isNumber }).map(String.init) ?? "?"
        return first.uppercased()
    }
}

enum IconRenderer {
    // Menu bar content height; columns are vertically centered by the system.
    private static let height: CGFloat = 22
    private static let columnGap: CGFloat = 6
    private static let peerGap: CGFloat = 3
    private static let sectionGap: CGFloat = 9

    static func render(_ info: IconInfo) -> NSImage {
        var columns: [(String, String, NSColor?)] = []
        columns.append(("CPU", pct(info.cpu), nil))
        if let g = info.gpu { columns.append(("GPU", pct(g), nil)) }
        columns.append(("RAM", pct(info.ram), ramColor(info.pressure)))

        let titleFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let letterFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .heavy)

        // Measure. Dynamic colors are applied at draw time (appearance-aware).
        func width(_ s: String, _ f: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: f]).width
        }
        let colWidths = columns.map { max(width($0.0, titleFont), width($0.1, valueFont)) }
        var total = colWidths.reduce(0, +) + columnGap * CGFloat(max(0, columns.count - 1))
        if !info.peers.isEmpty {
            total += sectionGap
            total += info.peers.map { width($0.letter, letterFont) }.reduce(0, +)
            total += peerGap * CGFloat(max(0, info.peers.count - 1))
        }
        total = ceil(total) + 2

        let img = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for (i, col) in columns.enumerated() {
                let w = colWidths[i]
                let (title, value, tint) = col
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: titleFont, .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let valueAttrs: [NSAttributedString.Key: Any] = [
                    .font: valueFont, .foregroundColor: tint ?? NSColor.labelColor,
                ]
                draw(title, titleAttrs, centerIn: w, x: x, y: 12.5)
                draw(value, valueAttrs, centerIn: w, x: x, y: 1.5)
                x += w + columnGap
            }
            if !info.peers.isEmpty {
                x += sectionGap - columnGap
                for p in info.peers {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: letterFont, .foregroundColor: color(for: p.status),
                    ]
                    let w = (p.letter as NSString).size(withAttributes: attrs).width
                    (p.letter as NSString).draw(
                        at: NSPoint(x: x, y: (height - 13) / 2), withAttributes: attrs)
                    x += w + peerGap
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func pct(_ v: Int?) -> String {
        v.map { "\($0)%" } ?? "–"
    }

    private static func ramColor(_ pressure: String?) -> NSColor? {
        switch pressure {
        case "critical": return .systemRed
        case "warn": return .systemOrange
        default: return nil
        }
    }

    private static func color(for s: PeerBadge.Status) -> NSColor {
        switch s {
        case .live: return .systemGreen
        case .noAgent: return .systemOrange
        case .offline, .unknown: return .tertiaryLabelColor
        }
    }

    private static func draw(
        _ s: String, _ attrs: [NSAttributedString.Key: Any],
        centerIn w: CGFloat, x: CGFloat, y: CGFloat
    ) {
        let sw = (s as NSString).size(withAttributes: attrs).width
        (s as NSString).draw(at: NSPoint(x: x + (w - sw) / 2, y: y), withAttributes: attrs)
    }
}
