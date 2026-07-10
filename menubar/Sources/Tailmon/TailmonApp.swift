// Tailmon.app — menu bar monitor for the tailnet fleet. LSUIElement (no Dock
// icon). The label shows the LOCAL machine's live CPU% and memory; the
// dropdown shows every tailnet host with per-host top processes.
import SwiftUI

@main
struct TailmonApp: App {
    @StateObject private var model = FleetModel()

    var body: some Scene {
        MenuBarExtra {
            FleetView().environmentObject(model)
        } label: {
            Text(model.iconText).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
