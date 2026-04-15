// StudioMenuBarApp.swift -- app Scene + Coordinator.
//
// The `@main` entry point lives in Sources/StudioMenuBar/App/Main.swift
// (a separate tiny executable target in Package.swift). This file is part
// of the StudioMenuBar library target so tests can link against the same
// code the GUI links against.

import AppKit
import SwiftUI

public struct StudioMenuBarScene: Scene {
    @StateObject private var appState: AppState
    @StateObject private var coordinator: Coordinator

    public init() {
        let state = AppState()
        let coord = Coordinator(appState: state)
        _appState = StateObject(wrappedValue: state)
        _coordinator = StateObject(wrappedValue: coord)
    }

    public var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(appState)
                .environmentObject(coordinator)
                .frame(width: 520, height: 640)
                .onAppear { coordinator.onPopoverOpen() }
                .onDisappear { coordinator.onPopoverClose() }
        } label: {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Coordinator wires config + client + polling service together and owns
/// them for the lifetime of the app. Using one object keeps the App struct
/// simple and gives us a single place to handle config errors.
@MainActor
public final class Coordinator: ObservableObject {
    public let appState: AppState
    private(set) var client: StudioClient?
    private var polling: PollingService?

    public init(appState: AppState) {
        self.appState = appState
        bootstrap()
    }

    private func bootstrap() {
        do {
            let cfg = try StudioConfig.load()
            appState.clientConfig = cfg
            var token: String?
            do {
                token = try StudioConfig.loadToken(cfg)
            } catch let err as StudioConfigError {
                appState.configError = err.message
                token = nil
            }
            let client = StudioClient(
                baseURL: cfg.collectorURL,
                token: token,
                timeout: cfg.timeoutSeconds
            )
            self.client = client
            let polling = PollingService(client: client, appState: appState)
            self.polling = polling
            polling.start()
        } catch let err as StudioConfigError {
            appState.configError = err.message
            appState.markError(err.message)
        } catch {
            appState.configError = error.localizedDescription
            appState.markError(error.localizedDescription)
        }
    }

    public func onPopoverOpen() {
        polling?.setPopoverOpen(true)
        polling?.pollNow()
    }

    public func onPopoverClose() {
        polling?.setPopoverOpen(false)
    }

    public func pollNow() {
        polling?.pollNow()
    }

    // MARK: - control actions

    public func killProcess(pid: Int, signal: Int = 15) async -> Result<Void, StudioClientError> {
        guard let client = client else { return .failure(.unknown("no client")) }
        do {
            _ = try await client.kill(pid: pid, signal: signal)
            polling?.pollNow()
            return .success(())
        } catch let err as StudioClientError {
            return .failure(err)
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }
    }

    public func kickSSH(pid: Int) async -> Result<Void, StudioClientError> {
        guard let client = client else { return .failure(.unknown("no client")) }
        do {
            _ = try await client.sshKick(pid: pid)
            polling?.pollNow()
            return .success(())
        } catch let err as StudioClientError {
            return .failure(err)
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }
    }

    public func newTmux(name: String) async -> Result<Void, StudioClientError> {
        guard let client = client else { return .failure(.unknown("no client")) }
        do {
            _ = try await client.tmuxNew(name: name)
            polling?.pollNow()
            return .success(())
        } catch let err as StudioClientError {
            return .failure(err)
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }
    }

    public func quit() {
        NSApplication.shared.terminate(nil)
    }
}
