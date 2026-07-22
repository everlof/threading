import AppKit
import XCTest
@testable import Skalman

/// The ring that makes an account's pressure readable at a glance.
///
/// `5h 0% · 7d 90%` is four numbers and two window names per account; comparing three accounts
/// means reading twelve of them. The ring is the comparison — and because it is drawn rather
/// than laid out, the only way to review it is to look at one.
@MainActor
final class UsageRingTests: XCTestCase {

    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkalmanRenders", isDirectory: true)
    }

    // MARK: - Reading

    /// The ring shows the window closest to its limit, which is the one worth a glance — an
    /// account at `5h 0% · 7d 90%` is nearly out, and a ring showing the 5-hour window would
    /// say the opposite.
    func testTheRingFollowsThePeakWindow() throws {
        let usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.0, resetsIn: 3600),
            window(id: "7d", fraction: 0.9, resetsIn: 86_400)
        ])

        let peak = try XCTUnwrap(usage.peakWindow())
        XCTAssertEqual(peak.id, "7d")
        XCTAssertNotNil(UsageRingImage.make(for: usage))
    }

    /// An account with no usage source draws nothing, the same silence the toolbar pill keeps
    /// — a ring at zero would read as "plenty left" rather than "unknown".
    func testNoReadingDrawsNoRing() {
        let usage = makeUsage(windows: [])
        XCTAssertNil(UsageRingImage.make(for: usage))
    }

    func testRingsAreDrawnAtMenuItemSize() {
        let image = UsageRingImage.make(fraction: 0.5, tint: .systemOrange)
        XCTAssertEqual(image.size.width, image.size.height, "the ring is not square")
        XCTAssertLessThanOrEqual(image.size.height, 16, "too tall to sit on a menu item")
    }

    // MARK: - Helpers

    private func window(id: String, fraction: Double?, resetsIn: TimeInterval) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id,
            label: id,
            fraction: fraction,
            resetsAt: Date().addingTimeInterval(resetsIn),
            windowDuration: nil
        )
    }

    private func makeUsage(windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(windows: windows, planLabel: nil, observedAt: Date(), source: .api)
    }

    // MARK: - Image

    func testRendersARingStrip() throws {
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fractions = [0.0, 0.09, 0.25, 0.5, 0.76, 0.9, 0.97, 1.0]
        let spacing: CGFloat = 8
        let cell: CGFloat = 14

        let strip = NSImage(
            size: NSSize(
                width: (cell + spacing) * CGFloat(fractions.count) + spacing,
                height: cell + spacing * 2
            )
        )

        strip.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: strip.size).fill()

        for (index, fraction) in fractions.enumerated() {
            let ring = UsageRingImage.make(
                fraction: fraction,
                tint: UsageSeverity.from(fraction: fraction).glyphColor
            )
            ring.draw(at: NSPoint(x: spacing + (cell + spacing) * CGFloat(index), y: spacing),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
        strip.unlockFocus()

        let data = try XCTUnwrap(
            strip.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
        )
        let url = directory.appendingPathComponent("usage-rings.png")
        try data.write(to: url)
        print("Rendered usage rings to \(url.path)")
    }
}
