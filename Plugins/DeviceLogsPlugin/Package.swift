// swift-tools-version: 5.9
import PackageDescription

/// The first native plugin: a live log stream in a pane of its own.
///
/// It links the contract dynamically — the host has the same framework loaded, and two copies of
/// an `@objc` protocol are two protocols — and the design system statically, so the bundle is
/// self-contained and looks like the window it sits in.
let package = Package(
    name: "DeviceLogsPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DeviceLogsPlugin", type: .dynamic, targets: ["DeviceLogsPlugin"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ThreadingPluginKit"),
        .package(path: "../../Packages/ThreadingDesignKit"),
        // Timestamp and level detection for app log files whose shape we do not know in advance.
        .package(path: "../../Packages/Vendor/TimberLineParser"),
    ],
    targets: [
        .target(
            name: "DeviceLogsPlugin",
            dependencies: [
                .product(name: "ThreadingPluginKit", package: "ThreadingPluginKit"),
                .product(name: "ThreadingDesignKit", package: "ThreadingDesignKit"),
                .product(name: "TimberLineParser", package: "TimberLineParser"),
            ],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
        .testTarget(
            name: "DeviceLogsPluginTests",
            dependencies: ["DeviceLogsPlugin"],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
    ]
)
