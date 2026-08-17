import AppKit
import XCTest
@testable import Threading

/// The drawn outline the cleanup proposal sheet puts its paths in.
///
/// Rendered as well as asserted on, because this component exists for a reason no assertion
/// states: the sheet it replaced listed absolute paths as bullets, and what was wrong with that
/// was visible in a picture and in nothing else.
@MainActor
final class StorageProposalOutlineRenderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private enum Render {
        static let width = StorageProposalDefaults.width

        static var directory: URL {
            // Non-empty, deliberately: an override set to "" resolves to `/`, and the failure
            // that produces is a read-only-volume error rather than anything that names the
            // environment.
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - Behaviour

    /// Every line is drawn: headings, the branches paths share, and the directories themselves.
    func testItDrawsALineForEveryHeadingBranchAndDirectory() {
        let view = StorageProposalOutlineView(
            outline: fixture(),
            accessibilityLabel: "3 directories"
        )
        let single = StorageProposalOutlineView(
            outline: StorageCleanupOutline.make(from: [group()], at: now),
            accessibilityLabel: "1 directory"
        )

        XCTAssertGreaterThan(
            view.fittingHeight(),
            single.fittingHeight(),
            "a proposal naming more directories was not taller"
        )
        XCTAssertGreaterThan(single.fittingHeight(), 0)
    }

    /// The accessory is bounded and scrolls. A sheet that pushed its buttons off the screen is
    /// not a sheet anybody can answer, and one that dropped rows would be hiding a delete.
    func testAProposalTooTallToShowScrollsRatherThanLosingRows() {
        let many = (0..<40).map {
            artifact("/repo/app/pkg/module-\($0)/.build", bytes: Int64(1_000 + $0))
        }
        let outline = StorageCleanupOutline.make(from: [group(many)], at: now)
        let accessory = StorageCleanupProposalSheet.accessory(
            for: outline,
            accessibilityLabel: "40 directories"
        )

        let scroll = try? XCTUnwrap(accessory as? NSScrollView)
        let document = try? XCTUnwrap(scroll?.documentView as? StorageProposalOutlineView)

        XCTAssertEqual(accessory.frame.height, StorageProposalDefaults.maximumHeight)
        XCTAssertGreaterThan(
            document?.fittingHeight() ?? 0,
            StorageProposalDefaults.maximumHeight,
            "the fixture is not tall enough to prove anything about scrolling"
        )
        XCTAssertEqual(scroll?.hasVerticalScroller, true)
        XCTAssertEqual(outline.directoryCount, 40, "rows were dropped from what is being removed")
    }

    // MARK: - Accessibility

    /// What it amounts to, and then what it drew: a view that draws instead of stacking has to
    /// say both, since there are no child elements to read.
    func testItReadsAsItsSummaryAndThenItsLines() {
        let view = StorageProposalOutlineView(
            outline: fixture(),
            accessibilityLabel: "3 build directories, 3.5 kB"
        )

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(view.accessibilityLabel(), "3 build directories, 3.5 kB")

        let value = view.accessibilityValue() as? String ?? ""
        XCTAssertTrue(value.contains("node_modules"), "a directory being removed is unreadable")
        XCTAssertTrue(value.contains("web"), "the shared segment is unreadable")
    }

    // MARK: - Theme

    /// A theme states sizes as well as colours, so following one is a remeasure and a redraw.
    func testALiveThemeSwitchRedrawsIt() {
        let view = StorageProposalOutlineView(outline: fixture(), accessibilityLabel: "outline")
        // In a window, unshown: `needsDisplay` is only recorded for a view that has one, so a
        // detached fixture would assert nothing here.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Render.width, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let content = window.contentView ?? NSView()
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.layoutIfNeeded()
        view.needsDisplay = false

        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeID.system))

        XCTAssertTrue(view.needsDisplay, "the outline ignored a live theme switch")
    }

    // MARK: - Rendering

    /// Draws the outline in both appearances, which is how this sheet's readability is reviewed.
    func testRendersTheOutlineToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let view = StorageProposalOutlineView(
                outline: fixture(),
                accessibilityLabel: "outline"
            )
            let host = NSView(frame: NSRect(
                x: 0,
                y: 0,
                width: Render.width,
                height: view.fittingHeight()
            ))
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            // Without this the offscreen draw resolves every colour against the process's
            // appearance and both images come out the same.
            host.appearance = appearance
            view.appearance = appearance

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.layoutSubtreeIfNeeded()
                // Resolved here, inside the appearance: an `NSImage`'s locked-focus context does
                // not inherit the current *drawing* appearance, so a dynamic role filled in there
                // comes back light and the dark image is white ink on white.
                // The window's own backdrop, not `Design.Surface.panel`: the panel role is
                // transparent under the system theme, so filling with it composites nothing and
                // the dark image is white ink on a white page again.
                data = png(
                    of: host,
                    on: NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
                )
            }

            try XCTUnwrap(data, "Failed to render the proposal outline in \(name)")
                .write(to: directory.appendingPathComponent("storage-proposal-\(name).png"))
            written += 1
        }

        XCTAssertEqual(written, 2)
    }

    // MARK: - Fixtures

    /// A checkout holding one directory of its own and two under a segment they share, plus a
    /// temporary cache built for a workspace — the two shapes the fold exists for.
    private func fixture() -> StorageCleanupOutline {
        StorageCleanupOutline.make(
            from: [
                group([
                    artifact("/repo/app/.build", bytes: 2_147_483_648),
                    artifact("/repo/app/web/node_modules", bytes: 412_000_000),
                    artifact("/repo/app/web/.next", bytes: 96_000_000)
                ])
            ] + ReclaimableFindings.scratchGroups(
                [
                    ReclaimableArtifact(
                        url: URL(fileURLWithPath: "/private/tmp/claude-501/8f3c/dd"),
                        kind: .xcodeDerivedData,
                        byteCount: 8_100_000_000,
                        modifiedAt: now.addingTimeInterval(-86_400),
                        checkoutPath: "/private/tmp",
                        workspacePath: "/repo/app/App.xcodeproj"
                    ),
                    ReclaimableArtifact(
                        url: URL(fileURLWithPath: "/private/tmp/claude-501/9c31/dd"),
                        kind: .xcodeDerivedData,
                        byteCount: 12_000_000_000,
                        modifiedAt: now.addingTimeInterval(-86_400 * 9),
                        checkoutPath: "/private/tmp",
                        workspacePath: "/private/tmp/gone/App.xcodeproj"
                    )
                ],
                among: [Project(name: "app", folderURL: URL(fileURLWithPath: "/repo/app"))],
                workspaceExists: { $0 == "/repo/app/App.xcodeproj" }
            ),
            at: now
        )
    }

    private func group(
        _ artifacts: [ReclaimableArtifact] = []
    ) -> ReclaimableFindings.Group {
        ReclaimableFindings.Group(
            attribution: .checkout(
                Project(name: "app", folderURL: URL(fileURLWithPath: "/repo/app"))
            ),
            title: "app · main",
            subtitle: "~/repo/app",
            identity: "/repo/app",
            artifacts: artifacts.isEmpty
                ? [artifact("/repo/app/.build", bytes: 2_000)]
                : artifacts
        )
    }

    private func artifact(_ path: String, bytes: Int64) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .swiftPackage,
            byteCount: bytes,
            modifiedAt: now.addingTimeInterval(-86_400),
            checkoutPath: "/repo/app"
        )
    }

    /// The drawn outline over the surface it sits on.
    ///
    /// The background is painted into the same bitmap *before* the view draws into it, through
    /// `displayIgnoringOpacity(_:in:)` — which composites rather than clearing, unlike
    /// `cacheDisplay`. This component draws ink and no background, so a straight cache writes
    /// white glyphs onto transparency and the dark image opens as a blank page in any viewer
    /// that composites on white. The contrast being reviewed is the one against the sheet.
    private func png(of host: NSView, on background: NSColor) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: host.bounds.size)).fill()
        host.displayIgnoringOpacity(host.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
