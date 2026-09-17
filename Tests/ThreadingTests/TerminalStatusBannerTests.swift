import AppKit
import XCTest
@testable import Threading

/// The plate that states what a terminal cannot: its iPhone owns the size, or its remote host is
/// out of reach. Hidden until asked, read as one element, inked from the terminal it floats on.
@MainActor
final class TerminalStatusBannerTests: XCTestCase {

    private enum Fixture {
        static let identifier = "test.banner"
        static let paneSize = NSSize(width: 480, height: 120)
        static let longTitle = String(repeating: "Reconnecting to a very long host name ", count: 8)
    }

    func testHiddenUntilShownAndReadAsOneElement() {
        let banner = TerminalStatusBanner(symbol: "server.rack", identifier: Fixture.identifier)
        XCTAssertTrue(banner.isHidden)
        XCTAssertEqual(banner.accessibilityIdentifier(), Fixture.identifier)
        XCTAssertTrue(banner.isAccessibilityElement())
        XCTAssertEqual(banner.accessibilityRole(), .group)

        banner.show(title: "Reconnecting to pi…", detail: "The session is still running there.", toolTip: "tip")
        XCTAssertFalse(banner.isHidden)
        XCTAssertEqual(banner.title, "Reconnecting to pi…")
        XCTAssertEqual(banner.detail, "The session is still running there.")
        XCTAssertEqual(banner.toolTip, "tip")
        XCTAssertEqual(banner.accessibilityLabel(), "Reconnecting to pi…, The session is still running there.")

        banner.show(title: "Only a title", detail: "")
        XCTAssertEqual(banner.accessibilityLabel(), "Only a title", "an empty detail adds no separator")
        XCTAssertNil(banner.toolTip, "a later statement does not keep an earlier one's tooltip")

        banner.hide()
        XCTAssertTrue(banner.isHidden)
    }

    /// A long host name truncates inside the cap rather than stretching across the terminal.
    func testALongTitleStaysWithinTheMaximumWidth() {
        let (pane, banner) = hostedBanner()
        banner.show(title: Fixture.longTitle, detail: "The session is still running there.")
        pane.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(banner.frame.width, TerminalStatusBannerDefaults.maximumWidth)
        XCTAssertGreaterThan(banner.frame.height, 0)
    }

    /// Every ink comes from the backdrop: a dark terminal gets light ink and the reverse.
    func testTheInkFollowsTheBackdropItFloatsOn() throws {
        let banner = TerminalStatusBanner(symbol: "server.rack", identifier: Fixture.identifier)
        banner.show(title: "Reconnecting to pi…", detail: "Detail")
        for ground in [NSColor.black, NSColor.white] {
            let ink = Design.Text.on(ground)
            banner.applyInk(ink)
            let labels = descendants(of: banner).compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.map(\.textColor), [ink.label, ink.secondary])
            XCTAssertNotNil(banner.layer?.borderColor)
        }
    }

    func testRendersToImages() throws {
        let directory = renderDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, ground) in [("dark", NSColor.black), ("light", NSColor.white)] {
            let (pane, banner) = hostedBanner()
            banner.show(title: "Reconnecting to lima-ptyd-spike…", detail: "Couldn’t reach it. Trying again in 5 s.")
            banner.applyInk(Design.Text.on(ground))
            pane.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            pane.wantsLayer = true
            pane.layer?.backgroundColor = ground.cgColor
            pane.cacheDisplay(in: pane.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("terminal-status-banner-\(name).png"))
        }
    }

    // MARK: - Helpers

    /// A pane with a stated size, the banner pinned bottom-trailing as the session view pins it.
    private func hostedBanner() -> (pane: NSView, banner: TerminalStatusBanner) {
        let pane = NSView(frame: NSRect(origin: .zero, size: Fixture.paneSize))
        let banner = TerminalStatusBanner(symbol: "server.rack", identifier: Fixture.identifier)
        pane.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Design.Spacing.inset),
            banner.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -Design.Spacing.inset),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: pane.leadingAnchor, constant: Design.Spacing.inset)
        ])
        return (pane, banner)
    }

    private func renderDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
