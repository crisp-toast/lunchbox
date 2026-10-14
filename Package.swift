// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tessel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tessel", targets: ["Tessel"]),
    ],
    targets: [
        // Pure layout logic: no AppKit, no Accessibility. Fully unit-tested.
        .target(name: "TesselCore"),
        // The menu bar app: hotkeys, window tracking, animation.
        .executableTarget(name: "Tessel", dependencies: ["TesselCore"]),
        .testTarget(name: "TesselCoreTests", dependencies: ["TesselCore"]),
    ],
    swiftLanguageModes: [.v5]
)
