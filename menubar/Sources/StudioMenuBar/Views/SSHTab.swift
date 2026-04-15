// SSHTab.swift -- SSH sessions table with kick button.

import SwiftUI

struct SSHTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: Coordinator
    @State private var pendingKick: SSHSession?
    @State private var lastActionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let msg = lastActionMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary)
            }
            Table(appState.sshSessions) {
                TableColumn("PID") { s in
                    Text("\(s.pid)").font(.caption.monospacedDigit())
                }
                .width(50)
                TableColumn("User") { s in
                    Text(s.user).font(.caption).lineLimit(1)
                }
                .width(80)
                TableColumn("From") { s in
                    Text(s.tailscalePeer?.hostname ?? s.sourceIp)
                        .font(.caption).lineLimit(1)
                }
                TableColumn("TTY") { s in
                    Text(s.tty ?? "-").font(.caption).lineLimit(1)
                }
                .width(60)
                TableColumn("Idle") { s in
                    Text(formatIdle(s.idleSeconds)).font(.caption.monospacedDigit())
                }
                .width(60)
                TableColumn("") { s in
                    Button("Kick") { pendingKick = s }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
                .width(50)
            }
        }
        .confirmationDialog(
            "Kick SSH session?",
            isPresented: Binding(
                get: { pendingKick != nil },
                set: { if !$0 { pendingKick = nil } }
            ),
            presenting: pendingKick
        ) { s in
            Button("Kick pid \(s.pid)", role: .destructive) {
                Task { await performKick(s) }
            }
            Button("Cancel", role: .cancel) { pendingKick = nil }
        } message: { s in
            Text("This will send SIGHUP to sshd pid \(s.pid) (\(s.user) from \(s.sourceIp)).")
        }
    }

    private func formatIdle(_ seconds: Double?) -> String {
        guard let s = seconds else { return "-" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s/60))m" }
        return "\(Int(s/3600))h"
    }

    private func performKick(_ s: SSHSession) async {
        let result = await coordinator.kickSSH(pid: s.pid)
        switch result {
        case .success:
            lastActionMessage = "kicked pid \(s.pid)"
        case .failure(let err):
            lastActionMessage = "kick failed: \(err.shortLabel)"
        }
        pendingKick = nil
    }
}
