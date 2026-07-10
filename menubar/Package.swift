// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tailmon",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Tailmon", path: "Sources/Tailmon"),
        .testTarget(
            name: "TailmonTests",
            dependencies: ["Tailmon"],
            path: "Tests/TailmonTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
