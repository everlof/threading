// swift-tools-version:6.0
import PackageDescription

// A spike, not a product. See README.md: this exists to measure how much of Threading's real
// drawing code compiles and renders on Linux against a module we simply name `AppKit`.
let package = Package(
    name: "LinuxAppKitSpike",
    targets: [
        .target(name: "AppKit"),
        .target(name: "CoreText"),
        .executableTarget(name: "Harness", dependencies: ["AppKit", "CoreText"])
    ]
)
