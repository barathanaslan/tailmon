// TmuxTab.swift -- tmux sessions table plus inline "new session" creator.

import SwiftUI

struct TmuxTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: Coordinator
    @State private var newName: String = ""
    @State private var lastActionMessage: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("new session name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("New") {
                    Task { await createSession() }
                }
                .disabled(newName.isEmpty || isCreating)
                .font(.caption)
            }
            if let msg = lastActionMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary)
            }
            Table(appState.tmuxSessions) {
                TableColumn("Name") { t in
                    Text(t.name).font(.caption).lineLimit(1)
                }
                TableColumn("Windows") { t in
                    Text("\(t.windows)").font(.caption.monospacedDigit())
                }
                .width(70)
                TableColumn("State") { t in
                    Text(t.attached ? "attached" : "detached")
                        .font(.caption)
                        .foregroundStyle(t.attached ? .green : .secondary)
                }
                .width(80)
            }
        }
    }

    private func createSession() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        let result = await coordinator.newTmux(name: name)
        switch result {
        case .success:
            lastActionMessage = "created \(name)"
            newName = ""
        case .failure(let err):
            lastActionMessage = "create failed: \(err.shortLabel)"
        }
    }
}
