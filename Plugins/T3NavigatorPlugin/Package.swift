// swift-tools-version: 5.9
import PackageDescription

/// A navigator-only native plugin used to exercise the public Swift/AppKit extension tier.
let package = Package(
    name: "T3NavigatorPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "T3NavigatorPlugin", type: .dynamic, targets: ["T3NavigatorPlugin"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ThreadingPluginKit"),
    ],
    targets: [
        .target(
            name: "T3NavigatorPlugin",
            dependencies: [
                .product(name: "ThreadingPluginKit", package: "ThreadingPluginKit"),
            ],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
        .testTarget(
            name: "T3NavigatorPluginTests",
            dependencies: ["T3NavigatorPlugin"],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
    ]
)
