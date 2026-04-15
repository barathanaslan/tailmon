// ChartsView.swift -- 4 sparklines (CPU / GPU / MEM / Total power).

import Charts
import SwiftUI

struct ChartsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                sparkline(title: "CPU", ring: appState.cpuHistory, color: .blue, maxValue: 100)
                sparkline(title: "GPU", ring: appState.gpuHistory, color: .purple, maxValue: 100)
            }
            HStack(spacing: 8) {
                sparkline(title: "MEM", ring: appState.memHistory, color: .green, maxValue: 100)
                sparkline(title: "PWR", ring: appState.powerHistory, color: .orange, maxValue: nil)
            }
        }
    }

    @ViewBuilder
    private func sparkline(title: String, ring: HistoryRing, color: Color, maxValue: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let latest = ring.latest {
                    Text(formatValue(latest, isPower: title == "PWR"))
                        .font(.caption2.monospacedDigit())
                }
            }
            Chart {
                ForEach(Array(ring.samples.enumerated()), id: \.offset) { (idx, v) in
                    LineMark(
                        x: .value("t", idx),
                        y: .value("v", v)
                    )
                    .foregroundStyle(color)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: chartDomain(maxValue: maxValue, ring: ring))
            .frame(height: 40)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(4)
        }
    }

    private func formatValue(_ v: Double, isPower: Bool) -> String {
        if isPower { return String(format: "%.1fW", v) }
        return String(format: "%.0f%%", v)
    }

    private func chartDomain(maxValue: Double?, ring: HistoryRing) -> ClosedRange<Double> {
        if let m = maxValue { return 0...m }
        let peak = max(ring.samples.max() ?? 1, 1)
        return 0...(peak * 1.1)
    }
}
