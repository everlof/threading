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
        .library(name: "ThreadingRemoteKit", type: .static, targets: ["ThreadingRemoteKit"])
    ],
    dependencies: [
        .package(path: "../ThreadingExtensionKit"),
        .package(path: "../ThreadingDomain"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0")
    ],
    targets: [
        .systemLibrary(name: "ThreadingRemoteZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .target(
            name: "ThreadingRemoteKit",
            dependencies: ["ThreadingExtensionKit", "ThreadingDomain",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .target(name: "ThreadingRemoteZlib", condition: .when(platforms: [.linux]))]
        ),
        .testTarget(
            name: "ThreadingRemoteKitTests",
            dependencies: ["ThreadingRemoteKit", "ThreadingExtensionKit", "ThreadingDomain",
                .target(name: "ThreadingRemoteZlib", condition: .when(platforms: [.linux]))]
        )
    ]
)
