// swift-tools-version: 5.9
import PackageDescription

/// First-party on-demand bundle for the portable traffic-capture helper.
let package = Package(
    name: "ProxyPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ProxyPlugin", type: .dynamic, targets: ["ProxyPlugin"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ThreadingPluginKit"),
    ],
    targets: [
        .target(
            name: "ProxyPlugin",
            dependencies: [
                .product(name: "ThreadingPluginKit", package: "ThreadingPluginKit"),
            ],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
    ]
)
