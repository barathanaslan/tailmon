// Main.swift -- GUI executable entry point.
//
// The library target `StudioMenuBar` contains everything except `@main`;
// that way the same code can be linked by the test runner without creating
// two competing entry points.

import StudioMenuBar
import SwiftUI

@main
struct StudioMenuBarApp: App {
    var body: some Scene {
        StudioMenuBarScene()
    }
}
