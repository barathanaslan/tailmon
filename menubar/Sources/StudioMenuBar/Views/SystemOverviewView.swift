// SystemOverviewView.swift -- bars + cached line + power line.

import SwiftUI

struct SystemOverviewView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar(label: "CPU", value: appState.stats?.cpu.percentTotal, color: .blue)
            bar(label: "GPU", value: appState.stats?.gpu?.percent, color: .purple)
            bar(label: "MEM", value: appState.stats?.memory.percent, color: .green)
            if let cached = appState.stats?.memory.cachedFilesBytes {
                Text("Cached files: " + ByteFormatter.format(Int64(cached)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            powerLine
        }
    }

    private func bar(label: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(min(max((value ?? 0) / 100.0, 0), 1)))
                }
            }
            .frame(height: 10)
            Text(value.map { String(format: "%.0f%%", $0) } ?? "--")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var powerLine: some View {
        HStack(spacing: 12) {
            Text("PWR")
                .font(.caption.monospaced())
                .frame(width: 36, alignment: .leading)
            if let p = appState.stats?.power {
                Text(String(format: "CPU %.1fW", p.cpuPackageWatts))
                Text(String(format: "GPU %.1fW", p.gpuWatts))
                Text(String(format: "Total %.1fW", p.totalWatts))
            } else {
                Text("--").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption.monospacedDigit())
    }
}

enum ByteFormatter {
    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: bytes)
    }
}
