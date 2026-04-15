// MenuBarView.swift -- compact label rendered into the menubar.

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            dotView
            Text(labelText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private var dotView: some View {
        switch appState.connection {
        case .connected:
            return Circle().fill(Color.green).frame(width: 6, height: 6)
        case .error:
            return Circle().fill(Color.red).frame(width: 6, height: 6)
        case .idle:
            return Circle().fill(Color.gray).frame(width: 6, height: 6)
        }
    }

    private var labelText: String {
        guard let stats = appState.stats else {
            if case .error = appState.connection { return "!" }
            return "..."
        }
        let cpu = Int(stats.cpu.percentTotal.rounded())
        let sshCount = appState.sshSessions.count
        return "\(cpu)%  \(sshCount)"
    }
}
