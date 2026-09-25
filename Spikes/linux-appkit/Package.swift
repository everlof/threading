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
        .package(path: "../../Packages/ThreadingPTYHostKit"),
        .package(path: "../../Packages/Vendor/SwiftTerm")
    ],
    targets: [
        .target(name: "AppKit"),
        .target(name: "CoreText"),
        // The system library, declared as a module the way Apple's SDK already does.
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .systemLibrary(name: "CLinuxTerminal", path: "Sources/CLinuxTerminal"),
        .systemLibrary(name: "CSDL2", pkgConfig: "sdl2"),
        .systemLibrary(name: "CPango", pkgConfig: "pangocairo"),
        .systemLibrary(name: "CAtk", pkgConfig: "atk-bridge-2.0"),
        .target(name: "LinuxWindowBridge", dependencies: [
            .target(name: "CSDL2", condition: .when(platforms: [.linux])),
            .target(name: "CPango", condition: .when(platforms: [.linux])),
            .target(name: "CAtk", condition: .when(platforms: [.linux]))],
            linkerSettings: [.linkedLibrary("atk-1.0", .when(platforms: [.linux]))]),
        .executableTarget(name: "WindowHarness", dependencies: ["AppKit", "CoreText", "CoreSlice", "TerminalRuntime",
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit"),
            .target(name: "LinuxWindowBridge", condition: .when(platforms: [.linux]))]),
        // Apple's Compression framework, reduced to the two symbols GzipWriter uses. See its header.
        .target(name: "Compression", dependencies: ["CZlib"]),
        // Real Threading persistence, vendored byte-identical. No AppKit anywhere near it.
        // OSLog's privacy interpolation, kept so 760 real call sites need no edit. See its header.
        .target(name: "OSLog"),
        .target(
            name: "CoreSlice",
            dependencies: ["SQLite3", "OSLog", .product(name: "ThreadingDomain", package: "ThreadingDomain"),
                .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit")],
            // Swift 5 language mode on purpose. The app target is not in Swift 6 mode yet — see
            // the shipping contract in reliability-and-type-safety.md — and compiling this slice
            // in Swift 6 surfaced that migration's diagnostics rather than anything about Linux.
            // The variable under test is the platform, so the language mode is held fixed.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "CoreSliceHarness", dependencies: ["CoreSlice"]),
        .target(name: "TerminalRuntime", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "PortablePTYClientHarness", dependencies: ["CoreSlice", "TerminalRuntime",
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit")]),
        .executableTarget(name: "LinuxHost", dependencies: ["CoreSlice",
            .target(name: "CLinuxTerminal", condition: .when(platforms: [.linux])),
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit")]),
        // Symlinks to the verified CoreSlice copies keep the production wrapper and logger exact.
        // This measures SQLite behavior independently of the project graph's remote-kit dependency.
        .executableTarget(
            name: "SQLiteHarness",
            dependencies: ["SQLite3", "OSLog"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "Harness", dependencies: ["AppKit", "CoreText"])
    ]
)
