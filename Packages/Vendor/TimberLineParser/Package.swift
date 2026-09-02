// swift-tools-version: 5.9
//
// Vendored from Timber (~/mjukis/projects/timber), which is not released and not going to be.
// Taken rather than depended on for the same reason SwiftTerm is: one build system, and the source
// is ours to change. The platform floor was 14 and carried no `@available(macOS 14)` anywhere, so
// it is 13 here to match Threading; the package builds and its 68 tests pass there.

import PackageDescription

let package = Package(
    name: "TimberLineParser",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TimberLineParser", targets: ["TimberLineParser"])
    ],
    targets: [
        .target(
            name: "TimberLineParser",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "TimberLineParserTests",
            dependencies: ["TimberLineParser"],
            resources: [.copy("Resources/")]
        )
    ]
)
