import AppKit
import XCTest
@testable import Threading

@MainActor
final class ThemedAlertInputTests: XCTestCase {
    func testAttachedDialogBlocksParentDispatchWithoutMakingItClickThrough() throws {
        let parent = recordingWindow()
        let other = recordingWindow()
        let alert = ThemedAlert()
        alert.messageText = "Pending question"
        alert.beginSheetModal(for: parent)
        defer { alert.dismiss(); parent.orderOut(nil); other.orderOut(nil) }

        XCTAssertFalse(parent.ignoresMouseEvents)
        XCTAssertTrue(alert.presentedWindow?.parent === parent)

        let blockedTypes: [NSEvent.EventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved
        ]
        for type in blockedTypes {
            NSApp.sendEvent(try mouseEvent(type, in: parent))
        }
        XCTAssertTrue(parent.receivedEvents.isEmpty, "blocked content received input")

        NSApp.sendEvent(try mouseEvent(.leftMouseDown, in: other))
        XCTAssertEqual(other.receivedEvents, [.leftMouseDown], "a sheet blocked another window")

        alert.dismiss()
        XCTAssertFalse(parent.ignoresMouseEvents)
        NSApp.sendEvent(try mouseEvent(.leftMouseDown, in: parent))
        XCTAssertEqual(parent.receivedEvents, [.leftMouseDown])
    }

    func testClosingParentRemovesInputBlockBeforeCompletionAndAllowsReuse() throws {
        let parent = recordingWindow()
        let alert = ThemedAlert()
        var completions = 0
        defer { alert.dismiss(); parent.orderOut(nil) }

        for iteration in 1...2 {
            alert.beginSheetModal(for: parent) { response in
                XCTAssertEqual(response, .abort)
                XCTAssertNil(alert.presentedWindow)
                completions += 1
            }
            NSApp.sendEvent(try mouseEvent(.leftMouseDown, in: parent))
            XCTAssertTrue(parent.receivedEvents.isEmpty)
            // Exercise the close observer without releasing a fixture inside AppKit dispatch.
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parent)
            XCTAssertEqual(completions, iteration)
            XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
            NSApp.sendEvent(try mouseEvent(.leftMouseDown, in: parent))
            XCTAssertEqual(parent.receivedEvents, [.leftMouseDown])
            parent.receivedEvents.removeAll()
        }
    }

    private func recordingWindow() -> RecordingAlertParent {
        let window = RecordingAlertParent(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

}

@MainActor
private final class RecordingAlertParent: NSWindow {
    var receivedEvents: [NSEvent.EventType] = []

    override func sendEvent(_ event: NSEvent) {
        receivedEvents.append(event.type)
    }
}
