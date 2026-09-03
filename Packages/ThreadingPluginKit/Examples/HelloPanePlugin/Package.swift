// swift-tools-version: 5.9
import PackageDescription

/// The smallest thing Threading will load, and the whole of what a plugin needs.
///
/// One dependency. `type: .dynamic` because the product is linked into a loadable bundle rather
/// than into an executable — `Tools/build-plugin.sh` does the rest.
let package = Package(
    name: "HelloPanePlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HelloPanePlugin", type: .dynamic, targets: ["HelloPanePlugin"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "HelloPanePlugin",
            dependencies: [.product(name: "ThreadingPluginKit", package: "ThreadingPluginKit")],
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
    ]
)
