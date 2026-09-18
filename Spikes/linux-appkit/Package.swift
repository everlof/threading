// swift-tools-version:6.0
import PackageDescription

// A spike, not a product. See README.md: this exists to measure how much of Threading's real
// drawing code compiles and renders on Linux against a module we simply name `AppKit`.
let package = Package(
    name: "LinuxAppKitSpike",
    dependencies: [
        // The real package, unmodified. Its manifest says it has no dependencies and its boundary
        // check keeps it Foundation-only, so building it here is the cheapest available test of
        // that claim on a platform it has never been compiled for.
        .package(path: "../../Packages/ThreadingDomain"),
        .package(path: "../../Packages/ThreadingRemoteKit")
    ],
    targets: [
        .target(name: "AppKit"),
        .target(name: "CoreText"),
        // The system library, declared as a module the way Apple's SDK already does.
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        // Apple's Compression framework, reduced to the two symbols GzipWriter uses. See its header.
        .target(name: "Compression", dependencies: ["CZlib"]),
        // Real Threading persistence, vendored byte-identical. No AppKit anywhere near it.
        // OSLog's privacy interpolation, kept so 760 real call sites need no edit. See its header.
        .target(name: "OSLog"),
        .target(
            name: "CoreSlice",
            dependencies: ["SQLite3", "OSLog", .product(name: "ThreadingDomain", package: "ThreadingDomain"), .product(name: "ThreadingRemoteKit", package: "ThreadingRemoteKit")],
            // Swift 5 language mode on purpose. The app target is not in Swift 6 mode yet — see
            // the shipping contract in reliability-and-type-safety.md — and compiling this slice
            // in Swift 6 surfaced that migration's diagnostics rather than anything about Linux.
            // The variable under test is the platform, so the language mode is held fixed.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "CoreSliceHarness", dependencies: ["CoreSlice"]),
        .executableTarget(name: "Harness", dependencies: ["AppKit", "CoreText"])
    ]
)
