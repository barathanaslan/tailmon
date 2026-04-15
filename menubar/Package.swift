// swift-tools-version:5.9
import PackageDescription

// Two targets:
//
// - `StudioMenuBar` (library): every production source file. Pulled in by
//   both the GUI executable and the test harness.
// - `StudioMenuBarApp` (executable): tiny @main that imports StudioMenuBar
//   and kicks off SwiftUI.
// - `StudioMenuBarTests` (executable): stand-alone test runner that imports
//   StudioMenuBar and runs a hand-rolled test harness. This avoids
//   XCTest / swift-testing which are not both reliably available in a
//   Command-Line-Tools-only Swift 6.2 environment.

let package = Package(
    name: "StudioMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StudioMenuBar", targets: ["StudioMenuBarApp"]),
    ],
    targets: [
        .target(
            name: "StudioMenuBar",
            path: "Sources/StudioMenuBar",
            exclude: ["App"]
        ),
        .executableTarget(
            name: "StudioMenuBarApp",
            dependencies: ["StudioMenuBar"],
            path: "Sources/StudioMenuBar/App"
        ),
        .executableTarget(
            name: "StudioMenuBarTests",
            dependencies: ["StudioMenuBar"],
            path: "Tests/StudioMenuBarTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
