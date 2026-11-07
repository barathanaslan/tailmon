// The dropdown (v0.3.0 design, docs/plans/v3-mockup.html "Yeni"): per-host
// cards with labelled bars that carry their numbers inside, a rates line and
// a processes list. Read-only by design: no power controls, no kill. Owner
// rule (2026-07-10). UI strings are Turkish.
import SwiftUI

// Muted fills so the white in-bar text stays readable at any fill level.
enum Palette {
    static let track = Color(red: 0x3a / 255, green: 0x3b / 255, blue: 0x41 / 255)
    static let cpu = Color(red: 0x3f / 255, green: 0x6f / 255, blue: 0xc4 / 255)
    static let ram = Color(red: 0x2e / 255, green: 0x8a / 255, blue: 0x52 / 255)
    static let swap = Color(red: 0x55 / 255, green: 0x70 / 255, blue: 0x5f / 255)
    static let ramWarn = Color(red: 0xa8 / 255, green: 0x66 / 255, blue: 0x1a / 255)
    static let ramCritical = Color(red: 0xa8 / 255, green: 0x3a / 255, blue: 0x32 / 255)
    static let gpu = Color(red: 0x7d / 255, green: 0x4c / 255, blue: 0xc0 / 255)
    static let vram = Color(red: 0x5b / 255, green: 0x42 / 255, blue: 0x82 / 255)
    static let disk = Color(red: 0x2f / 255, green: 0x7f / 255, blue: 0x8b / 255)
    static let proc = Color(red: 0x4a / 255, green: 0x4c / 255, blue: 0x55 / 255)
    static let text = Color(red: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf6 / 255)
    static let live = Color(red: 0x3f / 255, green: 0xbf / 255, blue: 0x6a / 255)
}

/// Set by snapshot tests: ImageRenderer cannot draw AppKit-backed views
/// (the window fitter, the ⋯ menu), so they are replaced by plain stand-ins.
private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

struct FleetView: View {
    @EnvironmentObject var model: FleetModel
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let note = model.report?.note {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = model.fleetError {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.report == nil && model.fleetError == nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            ForEach(liveHosts) { HostCard(result: $0) }
            if !otherHosts.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(otherHosts) { OfflineRow(result: $0) }
                }
                .padding(.horizontal, 10).padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(width: 340, alignment: .topLeading)
        .monospacedDigit()
        // Layout changes (a host appearing, processes toggled) apply in one
        // step: an animated content height would fight the window resize.
        .transaction { $0.animation = nil }
        .fitWindowHeight(enabled: !snapshotMode)
        .onAppear { model.menuOpen = true }
        .onDisappear { model.menuOpen = false }
    }

    private var liveHosts: [HostResult] { model.hosts.filter { $0.isLive && $0.stats != nil } }
    private var otherHosts: [HostResult] { model.hosts.filter { !($0.isLive && $0.stats != nil) } }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Tailmon").font(.system(size: 13, weight: .semibold))
            if !model.hosts.isEmpty {
                Text("\(liveHosts.count)/\(model.hosts.count) canlı")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let at = model.receivedAt {
                // Only worth a glance when the data is stale (polls run every 2s).
                TimelineView(.periodic(from: at, by: 1)) { ctx in
                    let age = ctx.date.timeIntervalSince(at)
                    if age > 5 {
                        Text(Fmt.age(age)).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            moreMenu
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private var moreMenu: some View {
        if snapshotMode {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            realMenu
        }
    }

    private var realMenu: some View {
        Menu {
            Toggle("Girişte başlat", isOn: Binding(
                get: { model.loginItemEnabled },
                set: { model.setLoginItem($0) }))
            Button("Logu göster") { model.showLog() }
            Divider()
            Button("Tailmon'dan çık") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Menü")
    }
}

// MARK: - Host card

struct HostCard: View {
    @EnvironmentObject var model: FleetModel
    let result: HostResult

    var body: some View {
        let s = result.stats!
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Palette.live).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(result.host).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .help(agentTooltip(s))
                Text(subtitle(s)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let up = s.uptimeSec {
                    Text(Fmt.uptime(up)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            MetricsGrid(stats: s, disks: model.disks(for: result))
            RatesLine(rates: model.rates[HostKey.of(result)])
            ProcessList(
                procs: Array((s.topProcs ?? []).prefix(6)),
                expanded: model.isExpanded(result),
                toggle: { model.toggleExpanded(result) })
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)))
    }

    /// "macOS · M6" for Macs (the GPU is the SoC); the OS alone elsewhere —
    /// discrete GPUs are named in their own bar.
    private func subtitle(_ s: Stats) -> String {
        let os = Fmt.osName(result.os ?? s.os)
        if os == "macOS", let g = s.gpu?.first, g.unified ?? true {
            return "\(os) · \(Fmt.shortGPUName(g.name))"
        }
        return os
    }

    private func agentTooltip(_ s: Stats) -> String {
        var parts = ["tailmon ajanı"]
        if let v = s.agent?.version { parts.append(v) }
        if let rss = s.agent?.rssMb { parts.append(String(format: "%.0f MB", rss)) }
        return parts.joined(separator: " · ")
    }
}

struct MetricsGrid: View {
    let stats: Stats
    let disks: [Stats.Disk]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                RowLabel("CPU")
                InBar(fills: [(stats.cpu.percent / 100, Palette.cpu)],
                      left: Fmt.pct(stats.cpu.percent),
                      right: stats.cpu.load1.map { String(format: "yük %.1f", $0) })
            }
            GridRow {
                RowLabel("RAM")
                InBar(fills: ramFills, left: Fmt.memPair(usedMb: stats.mem.usedMb, totalMb: stats.mem.totalMb),
                      right: swapText)
            }
            ForEach(Array((stats.gpu ?? []).enumerated()), id: \.offset) { _, g in
                GridRow {
                    RowLabel("GPU")
                    GPUPair(gpu: g, memTotalMb: stats.mem.totalMb)
                        .padding(.vertical, 2) // a little air around the joined pair
                }
            }
            ForEach(disks, id: \.mount) { d in
                GridRow {
                    RowLabel(Fmt.diskTag(d)).help(Fmt.diskTooltip(d))
                    InBar(fills: [(d.totalGb > 0 ? d.used / d.totalGb : 0, Palette.disk)],
                          left: Fmt.diskPair(used: d.used, total: d.totalGb),
                          right: Fmt.diskFree(d.freeGb))
                }
            }
        }
    }

    private var ramFills: [(Double, Color)] {
        let total = Double(max(stats.mem.totalMb, 1))
        let used = Double(stats.mem.usedMb) / total
        let tint: Color
        switch stats.mem.pressure {
        case "critical": tint = Palette.ramCritical
        case "warn": tint = Palette.ramWarn
        default: tint = Palette.ram
        }
        var fills = [(used, tint)]
        if let sw = stats.mem.swapUsedMb, sw > 0 {
            fills.append((Double(sw) / total, Palette.swap)) // lighter segment after RAM
        }
        return fills
    }

    private var swapText: String? {
        guard let sw = stats.mem.swapUsedMb, sw >= 100 else { return nil }
        return "swap " + Fmt.mem(sw)
    }
}

private struct RowLabel: View {
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: 24, alignment: .leading)
    }
}

/// GPU = joined pair: utilization bar on top, memory bar 1pt below.
struct GPUPair: View {
    let gpu: Stats.GPU
    let memTotalMb: UInt64

    var body: some View {
        VStack(spacing: 1) {
            InBar(fills: [((gpu.utilPct ?? 0) / 100, Palette.gpu)],
                  left: gpu.utilPct.map(Fmt.pct) ?? "–",
                  right: utilDetail,
                  corners: memBar == nil ? .all : .top)
            if let m = memBar {
                InBar(fills: [(m.frac, Palette.vram)], left: m.left, right: m.right,
                      height: 11, fontSize: 9.5, corners: .bottom)
            }
        }
    }

    private var isUnified: Bool { gpu.unified ?? (gpu.vramTotalMb == nil) }

    /// "RTX 5090 · 71°C · 548 W"; Macs: the chip name.
    private var utilDetail: String {
        var parts = [Fmt.shortGPUName(gpu.name)]
        if let t = gpu.tempC { parts.append(String(format: "%.0f°C", t)) }
        if let w = gpu.powerW { parts.append(String(format: "%.0f W", w)) }
        return parts.joined(separator: " · ")
    }

    private var memBar: (frac: Double, left: String, right: String?)? {
        if let used = gpu.vramUsedMb, let total = gpu.vramTotalMb, total > 0 {
            return (Double(used) / Double(total), Fmt.memPair(usedMb: used, totalMb: total),
                    gpu.fanPct.map { String(format: "fan %%%.0f", $0) })
        }
        if isUnified, let used = gpu.vramUsedMb {
            let frac = memTotalMb > 0 ? Double(used) / Double(memTotalMb) : 0
            return (frac, Fmt.mem(used), "paylaşımlı bellek")
        }
        return nil
    }
}

/// A bar with its numbers inside: primary value left (white), secondary
/// right (dimmed). fills are (fraction, color) segments laid end to end.
struct InBar: View {
    enum Corners { case all, top, bottom }

    var fills: [(Double, Color)]
    var left: String
    var right: String?
    var height: CGFloat = 14
    var fontSize: CGFloat = 10
    var corners: Corners = .all
    var track: Color = Palette.track
    var leftWeight: Font.Weight = .medium

    var body: some View {
        ZStack(alignment: .leading) {
            track
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        seg.1.frame(width: g.size.width * seg.0)
                    }
                }
            }
            HStack(spacing: 6) {
                Text(left).fontWeight(leftWeight).foregroundStyle(Palette.text)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                if let right {
                    Text(right).foregroundStyle(Palette.text.opacity(0.62))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(size: fontSize))
            .padding(.horizontal, 6)
        }
        .frame(height: height)
        .clipShape(shape)
    }

    /// Segments clamped so they never overflow the bar.
    private var segments: [(Double, Color)] {
        var left = 1.0
        return fills.map { f in
            let w = min(max(f.0, 0), left)
            left -= w
            return (w, f.1)
        }
    }

    private var shape: UnevenRoundedRectangle {
        let big: CGFloat = 4, small: CGFloat = 1
        switch corners {
        case .all:
            return UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big,
                                          bottomTrailingRadius: big, topTrailingRadius: big)
        case .top:
            return UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: small,
                                          bottomTrailingRadius: small, topTrailingRadius: big)
        case .bottom:
            return UnevenRoundedRectangle(topLeadingRadius: small, bottomLeadingRadius: big,
                                          bottomTrailingRadius: big, topTrailingRadius: small)
        }
    }
}

struct RatesLine: View {
    let rates: Rates?

    var body: some View {
        if let r = rates {
            HStack(spacing: 14) {
                pair("ağ", r.netRx, r.netTx)
                if let rd = r.diskRead, let wr = r.diskWrite {
                    pair("disk", rd, wr) // ↓ read, ↑ write
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
        }
    }

    /// "ağ ↓ 1.2 MB/s  ↑ 84 KB/s" — thin spaces between arrow and number.
    private func pair(_ title: String, _ down: Double, _ up: Double) -> some View {
        (Text("\(title)  ↓\u{2009}").foregroundColor(.secondary)
            + Text(Fmt.rate(down)).fontWeight(.medium)
            + Text("  ↑\u{2009}").foregroundColor(.secondary)
            + Text(Fmt.rate(up)).fontWeight(.medium))
    }
}

/// "Süreçler" disclosure. Collapsed: a one-line peek at the busiest process.
/// Expanded: one bar per process whose fill is its CPU share. Toggling is
/// instant (no animation): the window resizes to the new height in one step.
struct ProcessList: View {
    let procs: [Stats.Proc]
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        if !procs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 9)
                        Text("Süreçler")
                        if !expanded, let p = procs.first {
                            Text("· \(Fmt.procName(p)) \(Fmt.pct(p.cpuPct))")
                                .foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(spacing: 2) {
                        ForEach(procs) { p in
                            InBar(fills: [(min(p.cpuPct, 100) / 100, Palette.proc)],
                                  left: Fmt.procName(p),
                                  right: "\(Fmt.pct(p.cpuPct)) · \(Fmt.procMem(p.memMb))",
                                  height: 14, track: .clear, leftWeight: .regular)
                                .help(p.command ?? p.name)
                        }
                    }
                    .padding(.top, 5)
                }
            }
        }
    }
}

// MARK: - Offline / no-agent row

struct OfflineRow: View {
    let result: HostResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(result.status == "offline" ? Color.secondary.opacity(0.5) : .orange)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(result.host).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(Fmt.osName(result.os ?? result.stats?.os)).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .help(result.status == "offline" ? "çevrimdışı" : "açık · ajan yanıt vermiyor")
    }
}

// MARK: - Window sizing

extension View {
    /// Keeps the MenuBarExtra window exactly as tall as the content, top edge
    /// fixed under the menu bar. See WindowHeightFitter.
    func fitWindowHeight(enabled: Bool = true) -> some View { modifier(FitWindowHeight(enabled: enabled)) }
}

private struct FitWindowHeight: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background { if enabled { WindowHeightFitter() } }
            // While the window and the content disagree for a moment, keep
            // the content pinned to the top instead of centered: no jump.
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MenuBarExtra(.window) grows its window when the content grows but never
// shrinks it. The previous fix measured the content with a preference and
// resized the window on the NEXT main-queue turn, after SwiftUI had already
// drawn the new content inside the old-sized (centered) window: every
// processes toggle drew one wrong frame and then jumped — the flicker. Here
// the fitter's NSView is laid out by SwiftUI at exactly the content's size,
// and resizes the window synchronously in that same layout pass, before
// anything is drawn.
private struct WindowHeightFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> FitterView { FitterView() }
    func updateNSView(_ view: FitterView, context: Context) {}

    final class FitterView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fit()
        }

        private func fit() {
            guard let window, frame.height > 0 else { return }
            let height = ceil(frame.height)
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - height) >= 1 else { return }
            let target = NSRect(x: content.minX, y: content.maxY - height,
                                width: content.width, height: height)
            window.setFrame(window.frameRect(forContentRect: target), display: false, animate: false)
        }
    }
}
