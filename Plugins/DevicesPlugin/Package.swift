// swift-tools-version: 5.9
import PackageDescription

/// The first-party device feature's on-demand bundle. Its first payload is the signed
/// Simulator helper; the host keeps device admission, consent and session ownership.
let package = Package(
    name: "DevicesPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DevicesPlugin", type: .dynamic, targets: ["DevicesPlugin"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ThreadingPluginKit"),
    ],
    targets: [
        .target(
            name: "DevicesPlugin",
            dependencies: [
                .product(name: "ThreadingPluginKit", package: "ThreadingPluginKit"),
            ],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
    ]
)
