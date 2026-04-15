// ProcessesTab.swift -- top-10 processes table with kill button.

import SwiftUI

struct ProcessesTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: Coordinator
    @State private var pendingKill: StudioProcess?
    @State private var lastActionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let msg = lastActionMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary)
            }
            Table(appState.processes) {
                TableColumn("PID") { p in
                    Text("\(p.pid)").font(.caption.monospacedDigit())
                }
                .width(50)
                TableColumn("Name") { p in
                    Text(p.name).font(.caption).lineLimit(1)
                }
                TableColumn("User") { p in
                    Text(p.user).font(.caption).lineLimit(1)
                }
                .width(80)
                TableColumn("CPU%") { p in
                    Text(String(format: "%.1f", p.cpuPercent))
                        .font(.caption.monospacedDigit())
                }
                .width(50)
                TableColumn("MEM%") { p in
                    Text(String(format: "%.1f", p.memoryPercent))
                        .font(.caption.monospacedDigit())
                }
                .width(50)
                TableColumn("") { p in
                    Button("Kill") { pendingKill = p }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
                .width(40)
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingKill != nil },
                set: { if !$0 { pendingKill = nil } }
            ),
            presenting: pendingKill
        ) { proc in
            Button("Kill PID \(proc.pid)", role: .destructive) {
                Task { await performKill(proc) }
            }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: { proc in
            Text("This will send SIGTERM (15) to pid \(proc.pid) (\(proc.name), \(proc.user)).")
        }
    }

    private var confirmationTitle: String {
        if let p = pendingKill { return "Kill \(p.name)?" }
        return "Kill?"
    }

    private func performKill(_ proc: StudioProcess) async {
        let result = await coordinator.killProcess(pid: proc.pid)
        switch result {
        case .success:
            lastActionMessage = "killed \(proc.name) (pid \(proc.pid))"
        case .failure(let err):
            lastActionMessage = "kill failed: \(err.shortLabel)"
        }
        pendingKill = nil
    }
}
