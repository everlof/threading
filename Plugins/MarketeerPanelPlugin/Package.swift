// swift-tools-version: 5.9
import PackageDescription

/// Marketeer's pane, as a native plugin.
///
/// Not an Xcode bundle target and deliberately **not** built into the app: Marketeer is a
/// marketing tool, not something every Threading user should carry. It installs the ordinary
/// third-party way, through `Packages/ThreadingPluginKit/Tools/build-plugin.sh --install`, and is
/// refused until the user approves it — the same path anyone else's plugin takes.
let package = Package(
    name: "MarketeerPanelPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MarketeerPanelPlugin", type: .dynamic, targets: ["MarketeerPanelPlugin"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ThreadingPluginKit"),
        .package(path: "../../Packages/ThreadingDesignKit"),
    ],
    targets: [
        .target(
            name: "MarketeerPanelPlugin",
            dependencies: [
                .product(name: "ThreadingPluginKit", package: "ThreadingPluginKit"),
                .product(name: "ThreadingDesignKit", package: "ThreadingDesignKit"),
            ],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
        .testTarget(
            name: "MarketeerPanelPluginTests",
            dependencies: ["MarketeerPanelPlugin"],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
    ]
)
