// PopoverView.swift -- top-level popover layout.
//
// Vertical stack:
//   [header: connection state + last-poll age + collector URL]
//   [config-error banner, if any]
//   [system overview: CPU/GPU/MEM bars + PWR line]
//   [charts: 4 sparklines]
//   [tab picker: Processes | Ports | SSH | Tmux]
//   [selected tab body]

import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case ports = "Ports"
    case ssh = "SSH"
    case tmux = "Tmux"

    var id: String { rawValue }
}

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: Coordinator
    @State private var selectedTab: PopoverTab = .processes
    @State private var isPresented = false

    var body: some View {
        // The heavy view tree (Table, Picker, Charts, GeometryReaders) is only
        // built while the popover is actually visible. Without this gate,
        // MenuBarExtra(.window) keeps the content view attached and re-evaluates
        // its body on every @Published change, leaking AppKit Auto Layout
        // constraints over time.
        Group {
            if isPresented {
                content
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerView
            if let msg = appState.configError {
                configBanner(msg)
            }
            if case .error(let msg) = appState.connection {
                errorBanner(msg)
            }
            SystemOverviewView()
            ChartsView()
            Divider()
            Picker("", selection: $selectedTab) {
                ForEach(PopoverTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch selectedTab {
                case .processes:
                    ProcessesTab()
                case .ports:
                    PortsTab()
                case .ssh:
                    SSHTab()
                case .tmux:
                    TmuxTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            footerView
        }
        .padding(12)
    }

    // MARK: - header

    private var headerView: some View {
        HStack {
            connectionDot
            Text(headerLabel)
                .font(.headline)
            Spacer()
            if let last = appState.lastPollAt {
                Text(relativeTime(last))
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private var connectionDot: some View {
        Group {
            switch appState.connection {
            case .connected:
                Circle().fill(Color.green)
            case .error:
                Circle().fill(Color.red)
            case .idle:
                Circle().fill(Color.gray)
            }
        }
        .frame(width: 10, height: 10)
    }

    private var headerLabel: String {
        if let cfg = appState.clientConfig {
            return cfg.collectorURL.host ?? cfg.collectorURL.absoluteString
        }
        return "Studio"
    }

    private func configBanner(_ msg: String) -> some View {
        Text("Config error: " + msg)
            .font(.caption)
            .foregroundColor(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.8))
            .cornerRadius(6)
    }

    private func errorBanner(_ msg: String) -> some View {
        Text(msg)
            .font(.caption)
            .foregroundColor(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.8))
            .cornerRadius(6)
    }

    // MARK: - footer

    private var footerView: some View {
        HStack {
            Button("Refresh") { coordinator.pollNow() }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { coordinator.quit() }
                .buttonStyle(.borderless)
        }
        .font(.caption)
    }

    private func relativeTime(_ date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 1 { return "just now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        return "\(Int(delta/60))m ago"
    }
}
