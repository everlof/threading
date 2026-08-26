// swift-tools-version: 5.9

import PackageDescription

// The bounded wire contract shared by Threading and its embedded Simulator helper. Foundation
// only: neither side of this socket gains access to app stores, AppKit, CoreSimulator or a shell.
let package = Package(
    name: "ThreadingSimulatorKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingSimulatorKit", targets: ["ThreadingSimulatorKit"])
    ],
    targets: [
        .target(name: "ThreadingSimulatorKit"),
        .testTarget(
            name: "ThreadingSimulatorKitTests",
            dependencies: ["ThreadingSimulatorKit"]
        )
    ]
)
