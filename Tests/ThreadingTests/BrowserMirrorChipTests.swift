import AppKit
import ThreadingRemoteKit
import XCTest

@testable import Threading

/// The Mirror chip in the browser strip: absent until a page is mirrored, a glyph at the narrow
/// widths the address field needs, and the device and status once there is room.
@MainActor
final class BrowserMirrorChipTests: XCTestCase {
    func testTheChipAppearsOnlyWhileMirroredAndYieldsItsTitleAtNarrowWidths() {
        let bar = BrowserChromeBar(contextKind: .shared)
        XCTAssertTrue(bar.mirrorButton.isHidden)

        bar.setMirror(symbol: "iphone.radiowaves.left.and.right", title: "Davids iPhone · Showing", toolTip: "Mirror")
        bar.frame = NSRect(x: 0, y: 0, width: 720, height: 36)
        bar.updateResponsiveLayout()
        XCTAssertFalse(bar.mirrorButton.isHidden)
        XCTAssertEqual(bar.mirrorButton.title, "Davids iPhone · Showing")

        bar.frame = NSRect(x: 0, y: 0, width: 320, height: 36)
        bar.updateResponsiveLayout()
        XCTAssertFalse(bar.mirrorButton.isHidden, "the glyph stays: the mirror is still running")
        XCTAssertEqual(bar.mirrorButton.title, "")

        bar.setMirror(symbol: nil, title: "", toolTip: "")
        XCTAssertTrue(bar.mirrorButton.isHidden)
    }

    func testEveryStatusSaysSomething() {
        let statuses: [PhoneMirrorStatus] = [
            .connecting, .showing, .interacting, .away, .notified, .inUse, .waiting,
            .openOnPhone, .disabledOnPhone,
            .ended(.endedOnPhone), .ended(.expired), .ended(.disabled), .ended(.revoked),
            .ended(.sourceClosed), .ended(.stoppedOnMac), .ended(.replaced), .ended(.unknown("new")),
        ]
        for status in statuses {
            XCTAssertFalse(BrowserViewController.phoneMirrorStatusText(status).isEmpty, "\(status)")
        }
    }
}
