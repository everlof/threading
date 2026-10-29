// swift-tools-version: 5.9
import PackageDescription

/// The first-party device feature's on-demand bundle. An external SDK copy builds its read-only
/// Simulator snapshot pane using the same PluginKit and DesignKit products.
let package = Package(
    name: "DevicesPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DevicesPlugin", type: .dynamic, targets: ["DevicesPlugin"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ThreadingPluginKit"),
        .package(path: "../../Packages/ThreadingDesignKit"),
    ],
    targets: [
        .target(
            name: "DevicesPlugin",
            dependencies: [
                .product(name: "ThreadingPluginKit", package: "ThreadingPluginKit"),
                .product(name: "ThreadingDesignKitStandalone", package: "ThreadingDesignKit"),
            ],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
    ]
)
