// swift-tools-version: 5.9

import PackageDescription

/// Stable domain identities shared by every higher Threading layer.
///
/// This package intentionally has no dependencies. Application, persistence, runtime, and UI
/// types cannot become visible here, so dependency direction is enforced by the compiler.
let package = Package(
    name: "ThreadingDomain",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "ThreadingDomain", targets: ["ThreadingDomain"])
    ],
    targets: [
        .target(name: "ThreadingDomain"),
        .testTarget(name: "ThreadingDomainTests", dependencies: ["ThreadingDomain"]),
    ]
)
