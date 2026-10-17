// swift-tools-version:6.0
import PackageDescription

// Maintained Linux preview package, including the shared native stream transports. The AppKit-named module lets selected unchanged Threading
// sources compile on Linux; see README.md for the current host and compatibility boundaries.
let package = Package(
    name: "LinuxAppKitSpike",
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
        // The exact NativeDiffCore revision resolved by the shipping Xcode project.
        .package(url: "https://github.com/everlof/NativeDiffKit.git",
                 revision: "363c6197d8e334fa0aaf30550fb0a0bcac540e71"),
        // The real package, unmodified. Its manifest says it has no dependencies and its boundary
        // check keeps it Foundation-only, so building it here is the cheapest available test of
        // that claim on a platform it has never been compiled for.
        .package(path: "../../Packages/ThreadingDomain"),
        .package(path: "../../Packages/ThreadingRemoteKit"),
        .package(path: "../../Packages/ThreadingUsage"),
        .package(path: "../../Packages/ThreadingPTYHostKit"),
        .package(path: "../../Packages/ThreadingPTYClient"),
        .package(path: "../../Packages/Vendor/SwiftTerm")
    ],
    targets: [
        .target(name: "AppKit", dependencies: [
            .target(name: "AppKitTextBridge", condition: .when(platforms: [.linux]))],
            resources: [.copy("Resources/Fonts")]),
        .target(name: "CoreText"),
        .target(name: "CNativeAgentProcess"),
        // Exact shared Markdown package sources, compiled against this host AppKit module.
        .target(name: "ThreadingMarkdownKit", dependencies: ["AppKit"]),
        // Exact upstream renderer, with the AppKit shim made an explicit dependency. The
        // upstream package cannot name a host-provided AppKit module in its own manifest.
        .target(name: "LinuxNativeDiffAppKit", dependencies: ["AppKit",
            .product(name: "NativeDiffCore", package: "NativeDiffKit")],
            exclude: ["LICENSE"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The system library, declared as a module the way Apple's SDK already does.
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .systemLibrary(name: "CLinuxTerminal", path: "Sources/CLinuxTerminal"),
        .systemLibrary(name: "CSDL2", pkgConfig: "sdl2"),
        .systemLibrary(name: "CPango", pkgConfig: "pangocairo"),
        .systemLibrary(name: "CGIO", pkgConfig: "gio-2.0"),
        .systemLibrary(name: "CGdkPixbuf", pkgConfig: "gdk-pixbuf-2.0"),
        .target(name: "AppKitTextBridge", dependencies: [
            .target(name: "CPango", condition: .when(platforms: [.linux]))],
            linkerSettings: [.linkedLibrary("fontconfig", .when(platforms: [.linux])),
                             .linkedLibrary("pangoft2-1.0", .when(platforms: [.linux]))]),
        .systemLibrary(name: "CAtk", pkgConfig: "atk-bridge-2.0"),
        .target(name: "LinuxWindowBridge", dependencies: [
            .target(name: "CSDL2", condition: .when(platforms: [.linux])),
            .target(name: "CPango", condition: .when(platforms: [.linux])),
            .target(name: "CGIO", condition: .when(platforms: [.linux])),
            .target(name: "CGdkPixbuf", condition: .when(platforms: [.linux])),
            .target(name: "CAtk", condition: .when(platforms: [.linux]))],
            linkerSettings: [.linkedLibrary("atk-1.0", .when(platforms: [.linux]))]),
        .executableTarget(name: "WindowHarness", dependencies: ["AppKit", "CoreText", "CoreSlice", "TerminalRuntime", "LinuxNativeDiffAppKit", "ThreadingMarkdownKit",
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit"),
            .product(name: "ThreadingRemoteKit", package: "ThreadingRemoteKit"),
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient"),
            .target(name: "LinuxWindowBridge", condition: .when(platforms: [.linux]))],
            resources: [.copy("Resources/ProviderMarks"), .copy("Resources/Theme")],
            swiftSettings: [.define("THREADING_WINDOW_HARNESS"),
                .unsafeFlags(["-module-alias", "NativeDiffAppKit=LinuxNativeDiffAppKit"])]),
        // Keep the legacy GzipWriter probe's narrow shim out of optional framework discovery:
        // SwiftTerm's canImport(Compression) must not mistake it for Apple's complete framework.
        .target(name: "LinuxCompression", dependencies: ["CZlib"], path: "Sources/Compression"),
        // Real Threading persistence, vendored byte-identical. No AppKit anywhere near it.
        // OSLog's privacy interpolation, kept so 760 real call sites need no edit. See its header.
        .target(name: "OSLog"),
        .target(
            name: "CoreSlice",
            dependencies: ["SQLite3", "OSLog",
                .target(name: "CNativeAgentProcess", condition: .when(platforms: [.linux])),
                .product(name: "ThreadingDomain", package: "ThreadingDomain"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient"),
                .product(name: "ThreadingRemoteKit", package: "ThreadingRemoteKit"),
                .product(name: "ThreadingUsage", package: "ThreadingUsage"),
                .product(name: "NativeDiffCore", package: "NativeDiffKit"),
                .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit")],
            // Swift 5 language mode on purpose. The app target is not in Swift 6 mode yet — see
            // the shipping contract in reliability-and-type-safety.md — and compiling this slice
            // in Swift 6 surfaced that migration's diagnostics rather than anything about Linux.
            // The variable under test is the platform, so the language mode is held fixed.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "CoreSliceHarness", dependencies: ["CoreSlice",
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient")]),
        .executableTarget(name: "NativeRemoteContractHarness", dependencies: ["CoreSlice",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "ThreadingRemoteKit", package: "ThreadingRemoteKit")],
            path: "tests/native_remote_contract"),
        .executableTarget(name: "NativeConversationHarness", dependencies: ["CoreSlice",
            .product(name: "ThreadingPTYClient", package: "ThreadingPTYClient"),
            .product(name: "ThreadingPTYHostKit", package: "ThreadingPTYHostKit")],
            path: "tests/native_conversation", exclude: ["providers.py"]),
        .executableTarget(name: "NativeAgentProcessHarness", dependencies: ["CoreSlice"],
            path: "tests/native_agent_process", exclude: ["pipe_write_contract.c"]),
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
        .executableTarget(name: "ViewClippingHarness", dependencies: ["AppKit"],
            path: "tests/view_clipping"),
        .executableTarget(name: "PriorityLayoutHarness", dependencies: ["AppKit"],
            path: "tests/priority_layout"),
        .executableTarget(name: "ParagraphWrappingHarness", dependencies: ["AppKitTextBridge"],
            path: "tests/paragraph_wrapping", linkerSettings: [.linkedLibrary("m")]),
        .executableTarget(name: "OutlineViewHarness", dependencies: ["AppKit"],
            path: "tests/outline_view", exclude: ["run.sh", "README.md"]),
        .executableTarget(name: "SidebarVisibleRowsHarness", dependencies: ["AppKit"],
            path: "tests/sidebar_visible_rows", exclude: ["run.sh"]),
        .executableTarget(name: "TableHeightHarness", dependencies: ["AppKit"],
            path: "tests/table_heights",
            sources: ["Fixture.swift", "AutomaticRows.swift", "StructuralRows.swift",
                      "ThemeBoundary.swift", "ConversationVirtualRowHost.swift"]),
        .executableTarget(name: "TextLabelHarness", dependencies: ["AppKit",
            .target(name: "AppKitTextBridge", condition: .when(platforms: [.linux]))],
            path: "tests/text_label", exclude: ["run.sh"],
            sources: ["ControlRow.swift", "ThemedMultilineTitleLabel.swift",
                      "CompoundValueLabel.swift", "SimulatorRecordingBadge.swift",
                      "StorageProposalOutlineView.swift", "ThemedBarSparklineView.swift",
                      "NativePluginPresentationBoundaryView.swift", "KeyEquivalentScopeView.swift",
                      "Fixture.swift"]),
        .executableTarget(name: "CompleteLabelHarness", dependencies: ["AppKit"],
            path: "tests/complete_label"),
        .executableTarget(name: "SearchMatchHarness", dependencies: ["AppKit"],
            path: "tests/search_match", exclude: ["run.sh"],
            sources: ["SearchMatchLabel.swift", "ShimDependencies.swift", "Fixture.swift"]),
        .executableTarget(name: "TextEditorHarness", dependencies: ["AppKit"],
            path: "tests/text_editor", exclude: ["run.sh"],
            sources: ["ThemedTextView.swift", "PromptTextView.swift", "ThemeBoundary.swift", "Fixture.swift"]),
        // Compile the exact production Markdown grammar against the shim. This is the text
        // compatibility prerequisite; it does not claim the transcript controller is mounted.
        .executableTarget(name: "MarkdownHarness", dependencies: ["AppKit", "ThreadingMarkdownKit"],
            path: "tests/markdown", exclude: ["run.sh"],
            sources: ["Markdown.swift", "MarkdownInline.swift", "AgentAuthoredURLPolicy.swift",
                      "ThemeBoundary.swift", "Fixture.swift"]),
        // The exact control files plus the same fixed-palette boundary linked into WindowHarness.
        // The fixture's Specimen facts are the native shell's measured fixed grounds.
        .executableTarget(name: "IconButtonHarness", dependencies: ["AppKit"],
            path: "tests/icon_button", exclude: ["run.sh"],
            sources: ["ThemedControl.swift", "ThemedIconButton.swift", "PointerClaims.swift",
                      "SurfaceDrawing.swift", "GlyphView.swift", "TemplateImageDrawing.swift",
                      "AppKitLifetime.swift", "GlyphThemeBoundary.swift", "IconButtonBoundary.swift", "AppEvent.swift",
                      "LinuxTheme.swift", "LinuxThemeSnapshot.swift",
                      "NeutralInk.swift", "TextLegibilityPolicy.swift", "LabelLegibilityInk.swift",
                      "NSColor+Terminal.swift", "ThemeContrast.swift", "PerceptualColor.swift", "SpecimenBoundary.swift",
                      "Fixture.swift"]),
        // Compile the production selectable child row against the fixed diagnostic palette.
        // Its model prelude is checked byte-for-byte against the production source by run.sh.
        .executableTarget(name: "SubagentRowHarness", dependencies: ["AppKit"],
            path: "tests/subagent_row", exclude: ["run.sh"],
            sources: ["SubagentNavigatorRowView.swift", "SubagentSummaryItem.swift",
                      "ThemedControl.swift", "ThemedIconButton.swift", "PointerClaims.swift",
                      "SurfaceDrawing.swift", "GlyphView.swift", "TemplateImageDrawing.swift",
                      "AppKitLifetime.swift", "GlyphThemeBoundary.swift", "IconButtonBoundary.swift", "AppEvent.swift",
                      "LinuxTheme.swift", "LinuxThemeSnapshot.swift",
                      "NeutralInk.swift", "TextLegibilityPolicy.swift", "LabelLegibilityInk.swift",
                      "NSColor+Terminal.swift", "ThemeContrast.swift", "PerceptualColor.swift", "SpecimenBoundary.swift",
                      "RowBoundary.swift", "Fixture.swift"]),
        .executableTarget(name: "PaneHeaderHarness", dependencies: ["AppKit"],
            path: "tests/pane_header", exclude: ["run.sh"],
            sources: ["PaneHeader.swift", "PaneFooter.swift", "OpticalInsets.swift",
                      "SeparatorView.swift", "ThemedControl.swift", "ThemedIconButton.swift",
                      "PointerClaims.swift", "SurfaceDrawing.swift", "GlyphView.swift",
                      "TemplateImageDrawing.swift", "AppKitLifetime.swift",
                      "GlyphThemeBoundary.swift", "IconButtonBoundary.swift", "AppEvent.swift",
                      "LinuxTheme.swift", "LinuxThemeSnapshot.swift",
                      "NeutralInk.swift", "TextLegibilityPolicy.swift", "LabelLegibilityInk.swift",
                      "NSColor+Terminal.swift", "ThemeContrast.swift", "PerceptualColor.swift", "SpecimenBoundary.swift",
                      "Fixture.swift"],
            swiftSettings: [.define("THREADING_PANE_HEADER_HARNESS")]),
        // Compile the unchanged page-title component with the retained icon-control leaves.
        // LabelMorph is Apple-only; the fixture provides a bounded Pango label adapter.
        .executableTarget(name: "PageTitleHarness", dependencies: ["AppKit"],
            path: "tests/page_title", exclude: ["run.sh"],
            sources: ["PageTitleView.swift", "MorphingTitleLabel.swift", "PageTitleBoundary.swift", "Fixture.swift",
                      "ThemedControl.swift", "ThemedIconButton.swift", "PointerClaims.swift",
                      "SurfaceDrawing.swift", "GlyphView.swift", "TemplateImageDrawing.swift",
                      "AppKitLifetime.swift", "GlyphThemeBoundary.swift", "IconButtonBoundary.swift", "AppEvent.swift",
                      "LinuxTheme.swift", "LinuxThemeSnapshot.swift",
                      "NeutralInk.swift", "TextLegibilityPolicy.swift", "LabelLegibilityInk.swift",
                      "NSColor+Terminal.swift", "ThemeContrast.swift", "PerceptualColor.swift", "SpecimenBoundary.swift"]),
        // Exact production glyph drawing with test-only theme vocabulary. Its Linux bitmap
        // contract exercises the shim's image and backing-pixel behavior, not symbol lookup.
        .executableTarget(name: "GlyphViewHarness", dependencies: ["AppKit"],
            path: "tests/glyph_view",
            exclude: ["typecheck.sh", "render.sh"],
            sources: ["ShimDependencies.swift", "TemplateImageDrawing.swift", "GlyphView.swift", "GlyphViewFixture.swift",
                      "LabelLegibilityInk.swift", "NSColor+Terminal.swift", "ThemeContrast.swift",
                      "PerceptualColor.swift", "TextLegibilityPolicy.swift"]),
        .executableTarget(name: "FloatingGlyphHarness", dependencies: ["AppKit"],
            path: "tests/floating_glyph", exclude: ["run.sh"],
            sources: ["ShimDependencies.swift", "TemplateImageDrawing.swift",
                      "ThemedFloatingGlyphView.swift", "Fixture.swift"]),
        .executableTarget(name: "ImageHarness", dependencies: ["AppKit",
            .target(name: "LinuxWindowBridge", condition: .when(platforms: [.linux]))])
    ]
)
