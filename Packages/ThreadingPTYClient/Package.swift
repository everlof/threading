// swift-tools-version: 5.9

import PackageDescription

// The bounded, cross-platform client for threading-ptyd. The daemon's wire values live in
// ThreadingPTYHostKit; app logging, registration, and product policy stay with each host.
let package = Package(
    name: "ThreadingPTYClient",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingPTYClient", targets: ["ThreadingPTYClient"])
    ],
    dependencies: [
        .package(path: "../ThreadingPTYHostKit"),
        .package(path: "../ThreadingDomain")
    ],
    targets: [
        .target(name: "ThreadingPTYClient", dependencies: ["ThreadingPTYHostKit", "ThreadingDomain"])
    ],
    swiftLanguageVersions: [.v5]
)
