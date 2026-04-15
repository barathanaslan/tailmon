// PortsTab.swift -- read-only table of listening ports.

import SwiftUI

struct PortsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Table(appState.ports) {
            TableColumn("Proto") { p in
                Text(protoLabel(p)).font(.caption.monospaced())
            }
            .width(50)
            TableColumn("Port") { p in
                Text("\(p.port)").font(.caption.monospacedDigit())
            }
            .width(60)
            TableColumn("Process") { p in
                Text(p.processName ?? "-").font(.caption).lineLimit(1)
            }
            TableColumn("User") { p in
                Text(p.user ?? "-").font(.caption).lineLimit(1)
            }
            .width(80)
            TableColumn("PID") { p in
                Text(p.pid.map { "\($0)" } ?? "-").font(.caption.monospacedDigit())
            }
            .width(60)
        }
    }

    private func protoLabel(_ p: PortInfo) -> String {
        if let fams = p.addressFamilies, fams.count > 1 {
            return "\(p.protocolName)*"
        }
        return p.protocolName
    }
}
