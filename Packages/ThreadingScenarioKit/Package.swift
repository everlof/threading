// swift-tools-version: 5.9

import PackageDescription

/// Test-only contracts for recording and replaying provider traffic through a deterministic
/// fixture agent. The package is deliberately Foundation-only: recorders, the mock process, and
/// UI tests must agree on one format without importing the application or a presentation toolkit.
let package = Package(
    name: "ThreadingScenarioKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingScenarioKit", targets: ["ThreadingScenarioKit"]),
        .executable(name: "threading-scenario", targets: ["ThreadingScenarioTool"]),
    ],
    targets: [
        .target(name: "ThreadingScenarioKit"),
        .executableTarget(
            name: "ThreadingScenarioTool",
            dependencies: ["ThreadingScenarioKit"]
        ),
        .testTarget(
            name: "ThreadingScenarioKitTests",
            dependencies: ["ThreadingScenarioKit"]
        ),
    ]
)
