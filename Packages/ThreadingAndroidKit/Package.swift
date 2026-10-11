// swift-tools-version: 5.9

import PackageDescription

// The Android control planes Threading speaks without a third-party runtime: a cleartext HTTP/2
// and gRPC client for the emulator's own control service, the handful of protobuf messages it
// needs, its JWT authorization, and the bounded parsers for adb and uiautomator output.
// Foundation, Network and CryptoKit only — no AppKit, no app state.
let package = Package(
    name: "ThreadingAndroidKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingAndroidKit", targets: ["ThreadingAndroidKit"])
    ],
    targets: [
        .target(name: "ThreadingAndroidKit"),
        .testTarget(
            name: "ThreadingAndroidKitTests",
            dependencies: ["ThreadingAndroidKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
