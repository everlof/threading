// swift-tools-version: 5.9

import PackageDescription

// Native ICE/STUN/TURN transport shared by the macOS host and iOS remote client. Keep WebRTC
// pinned exactly: changes to the native binary must pass the transport matrix before shipping.
let package = Package(
    name: "ThreadingPeerTransport",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "ThreadingPeerTransport", targets: ["ThreadingPeerTransport"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "150.0.0")
    ],
    targets: [
        .target(
            name: "ThreadingPeerTransport",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ]
        ),
        .testTarget(
            name: "ThreadingPeerTransportTests",
            dependencies: ["ThreadingPeerTransport"]
        )
    ]
)
