// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThreadingPluginKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingPluginKit", type: .dynamic, targets: ["ThreadingPluginKit"]),
    ],
    targets: [
        .target(
            name: "ThreadingPluginKit",
            swiftSettings: [
                // A plugin links this framework and the host links the same one. Library
                // evolution is what lets the two be built at different times against different
                // versions of the package without the plugin having to be recompiled.
                .unsafeFlags(["-enable-library-evolution"]),
            ]
        ),
        .testTarget(name: "ThreadingPluginKitTests", dependencies: ["ThreadingPluginKit"]),
    ]
)
