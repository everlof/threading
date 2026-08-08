// swift-tools-version: 5.9

import PackageDescription

// The remote-access wire contract, shared between the macOS app and any future client (an iOS
// app first). Foundation-only and cross-platform on purpose: the whole point is that both ends
// speak *one* definition of the protocol, so it cannot drift. Nothing here imports AppKit or
// references an app-internal type.
let package = Package(
    name: "ThreadingRemoteKit",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "ThreadingRemoteKit", targets: ["ThreadingRemoteKit"])
    ],
    dependencies: [
        .package(path: "../ThreadingExtensionKit")
    ],
    targets: [
        .target(
            name: "ThreadingRemoteKit",
            dependencies: ["ThreadingExtensionKit"]
        ),
        .testTarget(
            name: "ThreadingRemoteKitTests",
            dependencies: ["ThreadingRemoteKit", "ThreadingExtensionKit"]
        )
    ]
)
