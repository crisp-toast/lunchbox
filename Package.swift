// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunchboxWM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LunchboxWM", targets: ["LunchboxWM"]),
    ],
    targets: [
        // Pure layout logic: no AppKit, no Accessibility. Fully unit-tested.
        .target(name: "LunchboxCore"),
        // The menu bar app: hotkeys, window tracking, animation.
        // Auto-updates for copies sold from the website. scripts/fetch-sparkle.sh puts it in Vendor/.
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework"),
        .executableTarget(
            name: "LunchboxWM",
            dependencies: ["LunchboxCore", "Sparkle"],
            // Sparkle.framework ships inside the app, in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "LunchboxCoreTests", dependencies: ["LunchboxCore"]),
    ],
    swiftLanguageModes: [.v5]
)
