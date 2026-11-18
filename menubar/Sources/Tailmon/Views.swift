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
        VStack(alignment: .leading, spacing: CardLayout.spacing) {
            if model.editing { editHeader } else { header }
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
            if model.editing { EditList() } else { deviceList }
        }
        .padding(10)
        .frame(width: 340, alignment: .topLeading)
        .monospacedDigit()
        // Layout changes (a host appearing, processes toggled) apply in one
        // step: an animated content height would fight the window resize.
        .transaction { $0.animation = nil }
        .fitWindowHeight(enabled: !snapshotMode) { model.setRoom($0) }
        .onAppear { model.menuOpen = true }
        .onDisappear { model.menuOpen = false }
    }

    /// The devices, in the user's order. Cards that do not fit the screen are
    /// drawn as one line (CardLayout.plan); if even that is too tall, the
    /// list scrolls inside a window that stays on the screen.
    @ViewBuilder private var deviceList: some View {
        let plan = model.cardPlan
        let list = VStack(alignment: .leading, spacing: CardLayout.spacing) {
            ForEach(model.shownHosts) { h in
                if !model.isCard(h) {
                    OfflineRow(result: h)
                } else if plan.open.contains(HostKey.of(h)) {
                    HostCard(result: h)
                } else {
                    LineCard(result: h)
                }
            }
        }
        if plan.scrolls && !snapshotMode {
            ScrollView(.vertical) { list }
                .frame(height: max(model.listRoom, CardLayout.lineHeight))
        } else {
            list
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Tailmon").font(.system(size: 13, weight: .semibold))
            if !model.hosts.isEmpty {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
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

    /// "4/5 canlı", plus "· 1 gizli" so a hidden device is not forgotten.
    private var summary: String {
        let shown = model.shownHosts
        var text = "\(shown.filter(model.isCard).count)/\(shown.count) canlı"
        if model.hiddenCount > 0 { text += " · \(model.hiddenCount) gizli" }
        return text
    }

    private var editHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Cihazlar").font(.system(size: 13, weight: .semibold))
            Text("sırala ve gizle").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Bitti") { model.editing = false }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
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
            Button("Cihazları düzenle…") { model.editing = true }
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

    static let maxProcs = 6

    var body: some View {
        let s = model.displayStats(result)!
        VStack(alignment: .leading, spacing: 9) {
            // The header line is the switch between the card and its one-line form.
            Button(action: { model.toggleCard(result) }) {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            MetricsGrid(stats: s, disks: model.disks(for: result))
            RatesLine(rates: model.rates[HostKey.of(result)])
            ProcessList(
                procs: Array((s.topProcs ?? []).prefix(Self.maxProcs)),
                expanded: model.isExpanded(result),
                toggle: { model.toggleExpanded(result) })
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)))
    }

    /// The OS only: the owner knows their hardware (chip/GPU names are in
    /// the tooltips).
    private func subtitle(_ s: Stats) -> String {
        Fmt.osName(result.os ?? s.os)
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
                      left: Fmt.pct(stats.cpu.percent), right: nil)
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
                        .help(g.name)
                }
            }
            ForEach(disks, id: \.mount) { d in
                GridRow {
                    RowLabel(Fmt.diskTag(d)).help(Fmt.diskTooltip(d))
                    InBar(fills: [(d.totalGb > 0 ? d.used / d.totalGb : 0, Palette.disk)],
                          left: Fmt.diskPair(used: d.used, total: d.totalGb),
                          right: Fmt.diskName(d))
                        .help(Fmt.diskTooltip(d))
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

    /// "71°C · 548 W" — no GPU name (it is the tooltip); nil on Macs.
    private var utilDetail: String? {
        var parts: [String] = []
        if let t = gpu.tempC { parts.append(String(format: "%.0f°C", t)) }
        if let w = gpu.powerW { parts.append(String(format: "%.0f W", w)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

/// "ağ ↓ 6.00 KB/s ↑ 4.00 KB/s   disk ↓ 880 KB/s ↑ 386 KB/s". Every value
/// sits in a fixed-width slot right after its arrow, so nothing after it
/// moves when digits change.
struct RatesLine: View {
    let rates: Rates?

    /// Fits the widest value, "88.8 MB/s" (50.4pt at 10pt medium); the
    /// whole line is 296pt of the card's 300.
    static let slot: CGFloat = 52

    var body: some View {
        if let r = rates {
            HStack(spacing: 0) {
                group("ağ", r.netRx, r.netTx)
                if let rd = r.diskRead, let wr = r.diskWrite {
                    group("disk", rd, wr) // ↓ read, ↑ write
                        .padding(.leading, 8)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .lineLimit(1)
        }
    }

    private func group(_ title: String, _ down: Double, _ up: Double) -> some View {
        HStack(spacing: 0) {
            Text(title).foregroundStyle(.secondary).fixedSize()
                .frame(width: title.count > 2 ? 24 : 16, alignment: .leading)
            arrow("↓")
            value(down)
            arrow("↑").padding(.leading, 4)
            value(up)
        }
    }

    private func arrow(_ a: String) -> some View {
        Text(a).foregroundStyle(.secondary)
    }

    private func value(_ v: Double) -> some View {
        Text(Fmt.rate(v)).fontWeight(.medium)
            .frame(width: Self.slot, alignment: .leading)
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

// MARK: - One-line card

/// A live device in one line: name and the three numbers that say whether it
/// is busy. Drawn for a card the user closed, and for the last cards when the
/// dropdown would not fit the screen. A click opens it.
struct LineCard: View {
    @EnvironmentObject var model: FleetModel
    let result: HostResult

    var body: some View {
        let s = model.displayStats(result)!
        Button(action: { model.toggleCard(result) }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Palette.live).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(result.host).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                // Whole percents: the line is a glance, and the name needs the width.
                HStack(spacing: 7) {
                    metric("CPU", s.cpu.percent)
                    metric("RAM", ramPct(s))
                    if let g = s.gpu?.first?.utilPct { metric("GPU", g) }
                }
                .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ramPct(_ s: Stats) -> Double {
        s.mem.totalMb > 0 ? 100 * Double(s.mem.usedMb) / Double(s.mem.totalMb) : 0
    }

    private func metric(_ label: String, _ percent: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", percent)).fontWeight(.medium)
        }
        .font(.system(size: 10))
    }
}

// MARK: - Edit list (order and hiding)

/// "Cihazları düzenle…" in the ⋯ menu turns the dropdown into this list:
/// every fleet device in the user's order, arrows to move it and an eye to
/// hide it. The controls exist only here; the normal view gains nothing.
struct EditList: View {
    @EnvironmentObject var model: FleetModel
    @Environment(\.snapshotMode) private var snapshotMode

    static let rowHeight: CGFloat = 34
    static let spacing: CGFloat = 6

    var body: some View {
        let hosts = model.arrangedHosts
        let list = VStack(spacing: Self.spacing) {
            ForEach(Array(hosts.enumerated()), id: \.element.id) { i, h in
                EditRow(result: h, isFirst: i == 0, isLast: i == hosts.count - 1)
            }
        }
        let height = CGFloat(hosts.count) * Self.rowHeight + CGFloat(max(hosts.count - 1, 0)) * Self.spacing
        if height > model.listRoom && !snapshotMode {
            ScrollView(.vertical) { list }.frame(height: max(model.listRoom, Self.rowHeight))
        } else {
            list
        }
    }
}

struct EditRow: View {
    @EnvironmentObject var model: FleetModel
    let result: HostResult
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let hidden = model.isHidden(result)
        HStack(spacing: 2) {
            iconButton("chevron.up", "Yukarı taşı", disabled: isFirst) { model.move(result, by: -1) }
            iconButton("chevron.down", "Aşağı taşı", disabled: isLast) { model.move(result, by: 1) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(result.host).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hidden ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(Fmt.osName(result.os ?? result.stats?.os)).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1)
                if hidden {
                    Text("· gizli").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            iconButton(hidden ? "eye.slash" : "eye", hidden ? "Göster" : "Gizle", disabled: false) {
                model.toggleHidden(result)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: EditList.rowHeight)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)))
    }

    private func iconButton(_ symbol: String, _ label: String, disabled: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .tertiary : .secondary)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Offline / no-agent row

/// An offline / agent-less host: the same card as a live host, header only.
struct OfflineRow: View {
    let result: HostResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(result.status == "offline" ? Color.secondary.opacity(0.6) : .orange)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(result.host).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(Fmt.osName(result.os ?? result.stats?.os)).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        .help(result.status == "offline" ? "çevrimdışı" : "açık · ajan yanıt vermiyor")
    }
}

// MARK: - Window sizing

extension View {
    /// Keeps the MenuBarExtra window exactly as tall as the content, top edge
    /// fixed under the menu bar, and reports how much room there is below
    /// that edge on the window's screen. See WindowHeightFitter.
    func fitWindowHeight(enabled: Bool = true, onRoom: @escaping (CGFloat) -> Void = { _ in }) -> some View {
        modifier(FitWindowHeight(enabled: enabled, onRoom: onRoom))
    }
}

private struct FitWindowHeight: ViewModifier {
    let enabled: Bool
    let onRoom: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background { if enabled { WindowHeightFitter(onRoom: onRoom) } }
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
//
// The window has no upper bound of its own: content taller than the screen
// ran off its bottom edge. The content now limits itself to the room it is
// told (FleetModel.room), and this view is where that figure comes from: the
// distance from the window's top edge down to the bottom of the screen's
// visible area.
private struct WindowHeightFitter: NSViewRepresentable {
    let onRoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> FitterView { FitterView() }
    func updateNSView(_ view: FitterView, context: Context) { view.onRoom = onRoom }

    final class FitterView: NSView {
        var onRoom: ((CGFloat) -> Void)?
        private var reported: CGFloat?
        private var moves: NSObjectProtocol?

        /// Kept free under the window, so it never touches the screen's edge.
        static let bottomGap: CGFloat = 8

        deinit {
            if let moves { NotificationCenter.default.removeObserver(moves) }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            fit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let moves { NotificationCenter.default.removeObserver(moves) }
            moves = nil
            if let window {
                moves = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportRoom() }
                }
            }
            fit()
        }

        private func reportRoom() {
            guard let window, window.isVisible, let screen = window.screen else { return }
            let top = window.contentRect(forFrameRect: window.frame).maxY
            guard top <= screen.frame.maxY else { return } // not placed yet
            let room = floor(top - screen.visibleFrame.minY - Self.bottomGap)
            guard room > 0, room != reported else { return }
            reported = room
            // Layout is running: hand the figure over after it.
            DispatchQueue.main.async { [weak self] in self?.onRoom?(room) }
        }

        private func fit() {
            guard let window, frame.height > 0 else { return }
            reportRoom()
            let height = ceil(frame.height)
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - height) >= 1 else { return }
            let target = NSRect(x: content.minX, y: content.maxY - height,
                                width: content.width, height: height)
            window.setFrame(window.frameRect(forContentRect: target), display: false, animate: false)
        }
    }
}
