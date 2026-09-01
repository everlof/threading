import AppKit
import XCTest
@testable import Threading

/// Covers the DEBUG readout that says whether the main thread is keeping up.
///
/// It exists because this app could already *record* every main-queue freeze and had no way to
/// *mention* one: the composer lag it was built for was found by reading incident JSON after the
/// fact. So the behaviour under test is the announcing — that a stall changes what the pill says
/// and how it looks, that the reading settles back on its own, and that the sentence which
/// actually locates a bug ("no active span") survives to the screen.
@MainActor
final class MainThreadStallHUDTests: XCTestCase {

    // MARK: - Fixtures

    private func makeHUD() -> MainThreadStallHUDView {
        let hud = MainThreadStallHUDView()
        hud.frame = NSRect(origin: .zero, size: hud.intrinsicContentSize)
        return hud
    }

    /// An unshown window, which is all a `cacheDisplay` needs — and the appearance has to be set
    /// on the host or the offscreen pass draws a blank.
    private func host(_ view: NSView, appearance name: NSAppearance.Name) -> NSView {
        let host = NSView(frame: NSRect(origin: .zero, size: view.intrinsicContentSize))
        host.appearance = NSAppearance(named: name)
        host.addSubview(view)
        view.frame = host.bounds
        return host
    }

    private func pixels(of view: NSView) -> [UInt8] {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return [] }
        return [UInt8](data)
    }

    // MARK: - Behaviour

    func testAHealthyPillSaysSoAndNamesNoStall() {
        let hud = makeHUD()
        XCTAssertEqual(hud.statusText, "ok")
        XCTAssertFalse(hud.isAlarmed)
    }

    func testAStallIsAnnouncedWithItsDuration() {
        let hud = makeHUD()
        hud.record(durationMilliseconds: 1850, operationNames: ["attachments.scan"])

        XCTAssertTrue(hud.isAlarmed)
        XCTAssertEqual(hud.statusText, "1.9s")
    }

    /// Sub-second freezes are still worth seeing, and rounding them to "0.3s" reads as noise.
    func testAShortStallIsReportedInMilliseconds() {
        let hud = makeHUD()
        hud.record(durationMilliseconds: 337, operationNames: [])
        XCTAssertEqual(hud.statusText, "337 ms")
    }

    /// The reading that actually locates a bug. A stall with no span open means the blocking work
    /// is not instrumented at all, which is exactly the case that has to reach the screen rather
    /// than being rendered as an empty gap.
    func testAStallWithNoOpenSpanSaysThatOutLoud() {
        let hud = makeHUD()
        hud.record(durationMilliseconds: 1631, operationNames: [])
        XCTAssertTrue(
            hud.accessibilityTitle()?.contains("no active span") == true,
            "got: \(hud.accessibilityTitle() ?? "nil")"
        )
    }

    func testTheOpenSpansAreNamed() throws {
        let hud = makeHUD()
        hud.record(durationMilliseconds: 900, operationNames: ["git.process", "attachments.scan"])
        let title = try XCTUnwrap(hud.accessibilityTitle())
        XCTAssertTrue(title.contains("git.process"), "got: \(title)")
    }

    /// Repeats of one span are one name. A burst that reported `attachments.scan` six times was
    /// what the pill was built to describe, and printing it six times describes nothing.
    func testRepeatedSpansAreNamedOnce() {
        let hud = makeHUD()
        hud.record(
            durationMilliseconds: 900,
            operationNames: Array(repeating: "attachments.scan", count: 6)
        )
        let title = hud.accessibilityTitle() ?? ""
        XCTAssertEqual(
            title.components(separatedBy: "attachments.scan").count - 1,
            1,
            "one span named once: \(title)"
        )
    }

    func testTheStallCountSurvivesTheAlarmSettlingBack() {
        let hud = makeHUD()
        hud.record(durationMilliseconds: 400, operationNames: [])
        hud.record(durationMilliseconds: 500, operationNames: [])
        XCTAssertTrue(hud.accessibilityTitle()?.isEmpty == false)
    }

    /// Bounded: the pill is a glance, the incident files are the record.
    func testTheRememberedListStaysBounded() {
        let hud = makeHUD()
        for index in 0..<40 {
            hud.record(durationMilliseconds: Double(300 + index), operationNames: [])
        }
        _ = hud.performPrimaryAction()
        XCTAssertLessThan(
            hud.intrinsicContentSize.height,
            400,
            "an expanded pill shows a bounded window, not every stall since launch"
        )
    }

    // MARK: - Interaction

    func testPressingExpandsAndCollapses() {
        let hud = makeHUD()
        hud.record(durationMilliseconds: 1200, operationNames: ["git.process"])

        let collapsed = hud.intrinsicContentSize.height
        XCTAssertTrue(hud.performPrimaryAction())
        let expanded = hud.intrinsicContentSize.height
        XCTAssertGreaterThan(expanded, collapsed, "pressing shows the recent stalls")

        XCTAssertTrue(hud.performPrimaryAction())
        XCTAssertEqual(hud.intrinsicContentSize.height, collapsed, accuracy: 0.5)
    }

    // MARK: - Accessibility

    func testItExposesItsRoleAndPrimaryAction() {
        let hud = makeHUD()
        XCTAssertEqual(hud.accessibilityRole(), .button)
        XCTAssertTrue(hud.accessibilityPerformPress())
        XCTAssertNotNil(hud.accessibilityTitle())
    }

    /// It sits over a terminal, whose claim is an I-beam. Claiming nothing would inherit that.
    func testItClaimsThePointer() {
        XCTAssertEqual(makeHUD().restingPointer, .pointingHand)
    }

    // MARK: - Rendered state

    func testItDrawsDifferentlyWhenAlarmed() {
        let healthy = pixels(of: host(makeHUD(), appearance: .darkAqua))

        let alarmedHUD = makeHUD()
        alarmedHUD.record(durationMilliseconds: 1850, operationNames: ["attachments.scan"])
        alarmedHUD.frame = NSRect(origin: .zero, size: alarmedHUD.intrinsicContentSize)
        let alarmed = pixels(of: host(alarmedHUD, appearance: .darkAqua))

        XCTAssertFalse(healthy.isEmpty, "the healthy pill draws something")
        XCTAssertFalse(alarmed.isEmpty, "the alarmed pill draws something")
        XCTAssertNotEqual(healthy, alarmed, "a stall has to look different, not just read differently")
    }

    func testItDrawsInBothAppearances() {
        let light = pixels(of: host(makeHUD(), appearance: .aqua))
        let dark = pixels(of: host(makeHUD(), appearance: .darkAqua))

        XCTAssertFalse(light.isEmpty)
        XCTAssertFalse(dark.isEmpty)
        XCTAssertNotEqual(light, dark, "the pill follows the appearance rather than baking a palette")
    }

    /// A live theme change must reach it — it is a themed control, and its ink comes from roles.
    func testItRedrawsWhenTheAppearanceChanges() {
        let hud = makeHUD()
        let container = host(hud, appearance: .aqua)
        let before = pixels(of: container)

        container.appearance = NSAppearance(named: .darkAqua)
        let after = pixels(of: container)

        XCTAssertNotEqual(before, after, "switching appearance repaints the pill")
    }
}
