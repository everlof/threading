// swift-tools-version: 5.9
import PackageDescription

/// The design system, compiled a second time so a native plugin can draw with the real
/// components instead of approximating them.
///
/// `Sources/ThreadingDesignKit/Shared` holds **symlinks to the application's own files**. There is
/// one copy of each component in the repository; this package chooses which of them a plugin gets,
/// and the compiler — not a hand-written list — decides when that choice is complete.
let package = Package(
    name: "ThreadingDesignKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThreadingDesignKit", type: .dynamic, targets: ["ThreadingDesignKit"]),
    ],
    dependencies: [
        // TerminalTheme maps a scheme onto SwiftTerm's colour table, so the model the design
        // system reads brings the emulator's types with it.
        .package(path: "../Vendor/SwiftTerm"),
        // UsageFormat is shared with the phone, which is where the one implementation lives.
        .package(path: "../ThreadingRemoteKit"),
        // StoredPathComponent: the shared rule for a name that becomes a path component.
        .package(path: "../ThreadingDomain"),
        // The three forks the components draw with: the activity ring, the working orb, and the
        // label that morphs a name character by character.
        .package(path: "../Vendor/BorderBeamKit"),
        .package(path: "../Vendor/ThinkingOrbs"),
        .package(path: "../Vendor/LabelMorph"),
        // The diff/syntax model the app links the same way; Design's syntax roles come from it.
        .package(path: "../../../NativeDiffKit"),
    ],
    targets: [
        .target(
            name: "ThreadingDesignKit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ThreadingRemoteKit", package: "ThreadingRemoteKit"),
                .product(name: "ThreadingDomain", package: "ThreadingDomain"),
                .product(name: "BorderBeamKit", package: "BorderBeamKit"),
                .product(name: "ThinkingOrbs", package: "ThinkingOrbs"),
                .product(name: "LabelMorph", package: "LabelMorph"),
                .product(name: "NativeDiffCore", package: "NativeDiffKit"),
            ],
            path: "Sources/ThreadingDesignKit",
            swiftSettings: [
                // The application builds these same files with complete checking, and the
                // isolation a component inherits from its AppKit superclass is inferred only
                // under it. Anything weaker rejects source the app compiles.
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .testTarget(
            name: "ThreadingDesignKitTests",
            dependencies: ["ThreadingDesignKit"],
            path: "Tests/ThreadingDesignKitTests"
        ),
    ]
)
