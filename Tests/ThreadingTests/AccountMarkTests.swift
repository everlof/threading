import AppKit
import XCTest
@testable import Threading

/// The mark a login wears in a menu that spans every runtime: which agent it belongs to, and how
/// much of its binding window is gone.
///
/// The composer's identity menu offers Claude, Codex, Grok and OpenCode logins in one list, so a
/// row that did not name its own runtime would be a login with no provider — and a menu row has
/// exactly one image slot to say it in. Both halves are drawn rather than laid out, which makes a
/// picture the only way to review the result; the contract around the picture is asserted here.
@MainActor
final class AccountMarkTests: XCTestCase {

    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    // MARK: - Identity

    /// Every runtime has a mark, whether or not it ships a brand icon — Grok and OpenCode fall
    /// back to an SF Symbol. A runtime that drew nothing would be a nameless row in a list whose
    /// whole job is naming which runtime a login belongs to.
    func testEveryRuntimeHasAMark() {
        for kind in AgentKind.allCases {
            XCTAssertNotNil(
                AccountMarkImage.make(for: kind),
                "\(kind.displayName) would appear in the identity menu with no mark"
            )
        }
    }

    /// The first visible sidebar rows load these marks while the launch-ready marker is still
    /// pending. Keep them in the compiled catalogue rather than falling back to synchronous PNG
    /// file decoding on the main thread.
    func testBrandMarksComeFromTheCompiledAssetCatalogue() throws {
        let claude = try XCTUnwrap(
            NSImage(named: NSImage.Name(AgentIconDefaults.claudeResource))
        )
        let codex = try XCTUnwrap(
            NSImage(named: NSImage.Name(AgentIconDefaults.codexResource))
        )

        XCTAssertFalse(claude.isTemplate)
        XCTAssertTrue(codex.isTemplate)
    }

    /// Claude's immutable colour mark is the only built-in provider image that needs pixel
    /// contrast analysis. Keep that result at the brand boundary so a viewport of Claude rows
    /// does not rasterize the same artwork once per cell and background-style pass.
    func testOnlyTheNonTemplateBrandMarkPublishesAKnownTone() throws {
        let claude = try XCTUnwrap(AgentKind.claude.brandIcon)
        let measured = try XCTUnwrap(IconBackplate.tone(of: claude))

        XCTAssertEqual(try XCTUnwrap(AgentKind.claude.brandIconTone), measured, accuracy: 0.001)
        XCTAssertNil(AgentKind.codex.brandIconTone)
        XCTAssertNil(AgentKind.grok.brandIconTone)
        XCTAssertNil(AgentKind.openCode.brandIconTone)
    }

    /// A login whose usage has not landed keeps its runtime. The meter is what goes missing —
    /// losing the mark instead would make the row's identity depend on a network round trip.
    func testAMarkSurvivesAnAccountWithNoReading() {
        let unread = AccountMarkImage.make(for: .claude, usage: nil)
        let empty = AccountMarkImage.make(
            for: .claude,
            usage: AccountUsage(windows: [], planLabel: nil, observedAt: Date(), source: .api)
        )

        XCTAssertNotNil(unread)
        XCTAssertNotNil(empty)
    }

    // MARK: - Geometry

    /// The image column a themed menu row reserves is 14–16pt. A mark taller than its slot is
    /// scaled by the row and stops lining up with the checkmark beside it.
    func testMarksAreDrawnAtMenuItemSize() throws {
        let mark = try XCTUnwrap(AccountMarkImage.make(for: .claude))

        XCTAssertEqual(mark.size.width, mark.size.height, "the mark is not square")
        XCTAssertLessThanOrEqual(mark.size.height, 16, "too tall to sit on a menu item")
    }

    /// The metered mark occupies the same slot as the plain one, so a reading arriving does not
    /// resize the row it lands in.
    func testAMeterDoesNotChangeTheSlot() throws {
        let plain = try XCTUnwrap(AccountMarkImage.make(for: .claude))
        let metered = try XCTUnwrap(
            AccountMarkImage.make(for: .claude, usage: usage(fraction: 0.9))
        )

        XCTAssertEqual(plain.size, metered.size)
    }

    // MARK: - Image

    /// The review this exists for: a Claude row and a Codex row must be told apart at 14pt, and
    /// a full window must be told from an empty one. Both were traded against a ring drawn around
    /// the mark, which at this size identified neither.
    func testRendersAMarkStrip() throws {
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fractions: [Double?] = [nil, 0.0, 0.09, 0.25, 0.5, 0.76, 0.9, 0.97, 1.0]
        let spacing: CGFloat = 10
        let cell: CGFloat = 14
        let kinds = AgentKind.allCases

        let strip = NSImage(
            size: NSSize(
                width: (cell + spacing) * CGFloat(fractions.count) + spacing,
                height: (cell + spacing) * CGFloat(kinds.count) + spacing
            )
        )

        strip.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: strip.size).fill()

        for (row, kind) in kinds.enumerated() {
            for (column, fraction) in fractions.enumerated() {
                let mark = fraction.map { AccountMarkImage.make(for: kind, usage: usage(fraction: $0)) }
                    ?? AccountMarkImage.make(for: kind)
                mark?.draw(
                    at: NSPoint(
                        x: spacing + (cell + spacing) * CGFloat(column),
                        y: strip.size.height - spacing - (cell + spacing) * CGFloat(row + 1)
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
        }
        strip.unlockFocus()

        let data = try XCTUnwrap(
            strip.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
        )
        let url = directory.appendingPathComponent("account-marks.png")
        try data.write(to: url)
        print("Rendered account marks to \(url.path)")
    }

    // MARK: - Helpers

    private func usage(fraction: Double) -> AccountUsage {
        AccountUsage(
            windows: [
                AccountUsage.Window(
                    id: "7d",
                    label: "7d",
                    fraction: fraction,
                    resetsAt: Date().addingTimeInterval(86_400),
                    windowDuration: nil
                )
            ],
            planLabel: nil,
            observedAt: Date(),
            source: .api
        )
    }
}
