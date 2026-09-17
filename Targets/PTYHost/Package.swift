// swift-tools-version: 5.9

import PackageDescription

// The Linux build of `threading-ptyd`, and a second way to run its tests.
//
// **The Xcode project remains the build of the app and of the macOS daemon it embeds.** This
// manifest exists because a Linux machine has no Xcode: it compiles the same sources in this
// directory, against the same `ThreadingPTYHostKit`, into the static binary a remote execution
// host runs (`docs/feature-drafts/remote-execution-hosts.md`). `scripts/test-ptyd-linux.sh` is its
// entry point. It also builds and tests on macOS with `swift test`, which is how a change to the
// Linux half is checked without a container, but that is a convenience and not a gate.
//
// Nothing here is referenced by `Threading.xcodeproj`, and the daemon's import boundary in
// `scripts/check_architecture_boundaries.sh` holds for the sources either build compiles.
let package = Package(
    name: "ThreadingPTYHost",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "threading-ptyd", targets: ["ThreadingPTYHost"])
    ],
    dependencies: [
        .package(path: "../../Packages/ThreadingPTYHostKit"),
        .package(path: "../../Packages/ThreadingDomain")
    ],
    targets: [
        // The few forwards Swift cannot make portably on Linux. Compiles to nothing elsewhere.
        .target(
            name: "CPTYHostPlatform",
            path: "Linux/CPTYHostPlatform"
        ),
        .executableTarget(
            name: "ThreadingPTYHost",
            dependencies: [
                .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit"),
                .target(name: "CPTYHostPlatform", condition: .when(platforms: [.linux]))
            ],
            path: ".",
            exclude: [
                "Info.plist",
                "codes.threading.ptyd.plist",
                "threading-ptyd.entitlements",
                "Linux",
                "Tests"
            ],
            swiftSettings: [
                // The Xcode target's `SWIFT_STRICT_CONCURRENCY = complete`, so the two builds
                // refuse the same code.
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ThreadingPTYHostTests",
            dependencies: [
                "ThreadingPTYHost",
                .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit"),
                .product(name: "ThreadingDomain", package: "ThreadingDomain")
            ],
            path: "Tests/ThreadingPTYHostTests"
        )
    ]
)
