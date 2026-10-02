// swift-tools-version:6.0
import PackageDescription

// Maintained Linux preview package. The AppKit-named module lets selected unchanged Threading
// sources compile on Linux; see README.md for the current host and compatibility boundaries.
let package = Package(
    name: "LinuxAppKitSpike",
    dependencies: [
        // The real package, unmodified. Its manifest says it has no dependencies and its boundary
        // check keeps it Foundation-only, so building it here is the cheapest available test of
        // that claim on a platform it has never been compiled for.
        .package(path: "../../Packages/ThreadingDomain"),
        .package(path: "../../Packages/ThreadingPTYHostKit"),
        .package(path: "../../Packages/ThreadingPTYClient"),
        .package(path: "../../Packages/Vendor/SwiftTerm")
    ],
    targets: [
        .target(name: "AppKit", dependencies: [
            .target(name: "AppKitTextBridge", condition: .when(platforms: [.linux]))]),
        .target(name: "CoreText"),
        // The system library, declared as a module the way Apple's SDK already does.
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .systemLibrary(name: "CLinuxTerminal", path: "Sources/CLinuxTerminal"),
        .systemLibrary(name: "CSDL2", pkgConfig: "sdl2"),
        .systemLibrary(name: "CPango", pkgConfig: "pangocairo"),
        .target(name: "AppKitTextBridge", dependencies: [
            .target(name: "CPango", condition: .when(platforms: [.linux]))]),
        .systemLibrary(name: "CAtk", pkgConfig: "atk-bridge-2.0"),
        .target(name: "LinuxWindowBridge", dependencies: [
            .target(name: "CSDL2", condition: .when(platforms: [.linux])),
            .target(name: "CPango", condition: .when(platforms: [.linux])),
            .target(name: "CAtk", condition: .when(platforms: [.linux]))],
            linkerSettings: [.linkedLibrary("atk-1.0", .when(platforms: [.linux]))]),
        .executableTarget(name: "WindowHarness", dependencies: ["AppKit", "CoreText", "CoreSlice", "TerminalRuntime",
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit"),
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient"),
            .target(name: "LinuxWindowBridge", condition: .when(platforms: [.linux]))],
            resources: [.copy("Resources/ProviderMarks")],
            swiftSettings: [.define("THREADING_WINDOW_HARNESS")]),
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
        .executableTarget(name: "CoreSliceHarness", dependencies: ["CoreSlice",
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient")]),
        .target(name: "TerminalRuntime", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "PortablePTYClientHarness", dependencies: ["CoreSlice", "TerminalRuntime",
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient"),
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit")]),
        .executableTarget(name: "LinuxHost", dependencies: ["CoreSlice",
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient"),
            .target(name: "CLinuxTerminal", condition: .when(platforms: [.linux])),
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit")]),
        // Symlinks to the verified CoreSlice copies keep the production wrapper and logger exact.
        // This measures SQLite behavior independently of the project graph's remote-kit dependency.
        .executableTarget(
            name: "SQLiteHarness",
            dependencies: ["SQLite3", "OSLog"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "Harness", dependencies: ["AppKit", "CoreText"]),
        .executableTarget(name: "TextLabelHarness", dependencies: ["AppKit",
            .target(name: "AppKitTextBridge", condition: .when(platforms: [.linux]))],
            path: "tests/text_label", exclude: ["run.sh"],
            sources: ["ControlRow.swift", "ThemedMultilineTitleLabel.swift",
                      "CompoundValueLabel.swift", "SimulatorRecordingBadge.swift",
                      "StorageProposalOutlineView.swift", "ThemedBarSparklineView.swift",
                      "NativePluginPresentationBoundaryView.swift", "KeyEquivalentScopeView.swift",
                      "Fixture.swift"]),
        .executableTarget(name: "SearchMatchHarness", dependencies: ["AppKit"],
            path: "tests/search_match", exclude: ["run.sh"],
            sources: ["SearchMatchLabel.swift", "ShimDependencies.swift", "Fixture.swift"]),
        // The exact control files plus the same fixed-palette boundary linked into WindowHarness.
        // The fixture's Specimen facts are the native shell's measured fixed grounds.
        .executableTarget(name: "IconButtonHarness", dependencies: ["AppKit"],
            path: "tests/icon_button", exclude: ["run.sh"],
            sources: ["ThemedControl.swift", "ThemedIconButton.swift", "PointerClaims.swift",
                      "SurfaceDrawing.swift", "GlyphView.swift", "TemplateImageDrawing.swift",
                      "AppKitLifetime.swift", "GlyphThemeBoundary.swift", "IconButtonBoundary.swift",
                      "NeutralInk.swift", "TextLegibilityPolicy.swift", "SpecimenBoundary.swift",
                      "Fixture.swift"]),
        // Compile the production selectable child row against the fixed diagnostic palette.
        // Its model prelude is checked byte-for-byte against the production source by run.sh.
        .executableTarget(name: "SubagentRowHarness", dependencies: ["AppKit"],
            path: "tests/subagent_row", exclude: ["run.sh"],
            sources: ["SubagentNavigatorRowView.swift", "SubagentSummaryItem.swift",
                      "ThemedControl.swift", "ThemedIconButton.swift", "PointerClaims.swift",
                      "SurfaceDrawing.swift", "GlyphView.swift", "TemplateImageDrawing.swift",
                      "AppKitLifetime.swift", "GlyphThemeBoundary.swift", "IconButtonBoundary.swift",
                      "NeutralInk.swift", "TextLegibilityPolicy.swift", "SpecimenBoundary.swift",
                      "RowBoundary.swift", "Fixture.swift"]),
        // Exact production glyph drawing with test-only theme vocabulary. Its Linux bitmap
        // contract exercises the shim's image and backing-pixel behavior, not symbol lookup.
        .executableTarget(name: "GlyphViewHarness", dependencies: ["AppKit"],
            path: "tests/glyph_view",
            exclude: ["typecheck.sh", "render.sh"],
            sources: ["ShimDependencies.swift", "TemplateImageDrawing.swift", "GlyphView.swift", "GlyphViewFixture.swift"]),
        .executableTarget(name: "FloatingGlyphHarness", dependencies: ["AppKit"],
            path: "tests/floating_glyph", exclude: ["run.sh"],
            sources: ["ShimDependencies.swift", "TemplateImageDrawing.swift",
                      "ThemedFloatingGlyphView.swift", "Fixture.swift"]),
        .executableTarget(name: "ImageHarness", dependencies: ["AppKit",
            .target(name: "LinuxWindowBridge", condition: .when(platforms: [.linux]))])
    ]
)
