// The dropdown: the Stats replacement. Per-host cards with full stats AND the
// top-processes list ("what is actually running") — the insight the TUI lacks.
// Read-only by design: no power controls, no kill. Owner rule (2026-07-10).
import SwiftUI

struct FleetView: View {
    @EnvironmentObject var model: FleetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let note = model.report?.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let err = model.fleetError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            if let hosts = model.report?.hosts {
                ForEach(hosts) { HostCard(result: $0) }
            } else if model.fleetError == nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { model.menuOpen = true }
        .onDisappear { model.menuOpen = false }
    }

    private var header: some View {
        HStack {
            Text("Tailmon").font(.headline)
            Text("tailnet monitor").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            // Launch-at-login is on by default (registered on first launch);
            // manage it in System Settings > General > Login Items if needed.
            Text("starts at login").foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct HostCard: View {
    let result: HostResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                statusDot
                Text(result.host).font(.system(.body, weight: .semibold))
                Text(osBadge).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let up = result.stats?.uptimeSec {
                    Text("up " + humanDuration(up))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let s = result.stats, result.isLive {
                // aggregate marks the machine we're running on as source=local.
                StatsRows(stats: s, isLocal: result.source == "local")
            } else {
                Text(placeholder).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var statusDot: some View {
        Circle().frame(width: 7, height: 7).foregroundStyle(
            result.isLive ? .green : (result.status == "offline" ? .gray : .yellow))
    }

    private var osBadge: String {
        switch (result.os ?? result.stats?.os ?? "").lowercased() {
        case "macos", "darwin": return "macOS"
        case "windows": return "win"
        case "linux": return "linux"
        default: return "?"
        }
    }

    private var placeholder: String {
        switch result.status {
        case "offline": return "offline"
        case "no-agent": return "online — no tailmon agent on :7020"
        default: return result.error ?? result.status
        }
    }
}

struct StatsRows: View {
    let stats: Stats
    let isLocal: Bool
    @State private var procsExpanded: Bool

    init(stats: Stats, isLocal: Bool) {
        self.stats = stats
        self.isLocal = isLocal
        _procsExpanded = State(initialValue: isLocal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            meter("CPU", stats.cpu.percent, detail: cpuDetail, tint: .blue)
            meter("RAM", ramPct, detail: ramDetail, tint: ramTint)
            ForEach(Array((stats.gpu ?? []).enumerated()), id: \.offset) { _, g in
                gpuRow(g)
            }
            miscRow
            procsSection
        }
        .font(.caption)
    }

    private func meter(_ label: String, _ pct: Double, detail: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 30, alignment: .leading).foregroundStyle(.secondary)
            ProgressView(value: min(max(pct, 0), 100), total: 100)
                .tint(tint).frame(width: 110)
            Text(detail).monospacedDigit()
            Spacer()
        }
    }

    private var cpuDetail: String {
        var d = String(format: "%.1f%%", stats.cpu.percent)
        if let l = stats.cpu.load1 { d += String(format: " · load %.1f", l) }
        return d
    }

    private var ramPct: Double {
        stats.mem.totalMb > 0 ? 100 * Double(stats.mem.usedMb) / Double(stats.mem.totalMb) : 0
    }

    private var ramDetail: String {
        var d = String(format: "%.1f/%.0fG", Double(stats.mem.usedMb) / 1024, Double(stats.mem.totalMb) / 1024)
        if let p = stats.mem.pressure, p != "normal" { d += " · \(p)" }
        return d
    }

    private var ramTint: Color {
        switch stats.mem.pressure {
        case "critical": return .red
        case "warn": return .orange
        default: return .green
        }
    }

    private func gpuRow(_ g: Stats.GPU) -> some View {
        HStack(spacing: 6) {
            Text("GPU").frame(width: 30, alignment: .leading).foregroundStyle(.secondary)
            Text(gpuDetail(g)).monospacedDigit()
            Spacer()
        }
    }

    private func gpuDetail(_ g: Stats.GPU) -> String {
        var d = g.name
        if let u = g.utilPct { d += String(format: " %.0f%%", u) }
        if let used = g.vramUsedMb, let total = g.vramTotalMb {
            d += String(format: " · VRAM %.1f/%.1fG", Double(used) / 1024, Double(total) / 1024)
        }
        if let t = g.tempC { d += String(format: " · %.0f°C", t) }
        return d
    }

    private var miscRow: some View {
        HStack(spacing: 6) {
            if let disk = stats.disks?.first {
                Text(String(format: "Disk %@ %.0fG free", disk.mount, disk.freeGb))
            }
            Spacer()
            if let rss = stats.agent?.rssMb {
                Text(String(format: "agent %.0fMB", rss))
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var procsSection: some View {
        if let procs = stats.topProcs, !procs.isEmpty {
            DisclosureGroup(isExpanded: $procsExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(procs.prefix(isLocal ? 8 : 10)) { p in
                        HStack(spacing: 6) {
                            Text(p.name).lineLimit(1).frame(width: 150, alignment: .leading)
                                .help(p.command ?? p.name)
                            Text(String(format: "%.1f%%", p.cpuPct))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                            Text(String(format: "%.0fMB", p.memMb))
                                .monospacedDigit().frame(width: 60, alignment: .trailing)
                            Spacer()
                        }
                        .font(.system(.caption2, design: .monospaced))
                    }
                }
                .padding(.top, 2)
            } label: {
                Text("processes").foregroundStyle(.secondary)
            }
        }
    }
}

func humanDuration(_ sec: UInt64) -> String {
    let d = sec / 86_400, h = (sec % 86_400) / 3_600, m = (sec % 3_600) / 60
    if d > 0 { return "\(d)d\(h)h" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}
