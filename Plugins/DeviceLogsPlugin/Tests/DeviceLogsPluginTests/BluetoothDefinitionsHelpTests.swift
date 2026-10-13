import AppKit
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

/// The "?" panel for packet definitions: its states, its width, and a picture of each state.
@MainActor
final class BluetoothDefinitionsHelpTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/Users/someone/app/.threading/bluetooth.yaml")

    func testEachFileStateSaysWhatToDoNext() throws {
        let cases: [(BluetoothDefinitionStatus, String, String, Bool)] = [
            (.noCheckout, "not attached to a project checkout", "Create File", false),
            (.missing(expected: file), "Not created yet. Threading looks for \(file.path)", "Create File", true),
            (.loaded(file, characteristics: 2, types: 3), "2 characteristics, 3 types", "Open File", true),
            (.failed(file, message: "line 7: unknown type 'u17'"), "line 7: unknown type 'u17'", "Open File", true),
        ]
        for (status, text, action, enabled) in cases {
            let help = BluetoothDefinitionsHelpViewController(status: status)
            _ = laidOut(help.view)
            let label = try XCTUnwrap(find(BluetoothDefinitionsHelpViewController.Identifiers.status, in: help.view) as? NSTextField)
            XCTAssertTrue(label.stringValue.contains(text), label.stringValue)
            let button = try XCTUnwrap(find(BluetoothDefinitionsHelpViewController.Identifiers.primary, in: help.view) as? ThemedButton)
            XCTAssertEqual(button.title, action)
            XCTAssertEqual(button.isEnabled, enabled)
        }
    }

    func testStatusUpdatesWhileThePanelIsOpen() throws {
        let help = BluetoothDefinitionsHelpViewController(status: .missing(expected: file))
        _ = laidOut(help.view)
        help.apply(.failed(file, message: "line 3: x"))
        let label = try XCTUnwrap(find(BluetoothDefinitionsHelpViewController.Identifiers.status, in: help.view) as? NSTextField)
        XCTAssertTrue(label.stringValue.hasSuffix("line 3: x"))
    }

    /// A vertical stack aligned .leading gives each view its fitting width; the prose, the
    /// reference and the example must span the panel rather than sit in a third of it.
    func testTheExampleAndProseSpanThePanel() throws {
        let help = BluetoothDefinitionsHelpViewController(status: .missing(expected: file))
        _ = laidOut(help.view)
        let example = try XCTUnwrap(descendants(of: help.view).compactMap { $0 as? ThemedTextScrollView }.first)
        XCTAssertEqual(example.frame.width, BluetoothDefinitionsHelpViewController.Metrics.contentWidth, accuracy: 1)
        XCTAssertEqual(example.textView.string, BluetoothDefinitionsGuide.example)
        XCTAssertFalse(example.textView.isEditable)
    }

    func testRendersEachStateToImages() throws {
        let states: [(String, BluetoothDefinitionStatus)] = [
            ("missing", .missing(expected: file)),
            ("failed", .failed(file, message: "line 7: Frame.kind: unknown type 'u17' — use u8…u64, …")),
        ]
        for (name, status) in states {
            let help = BluetoothDefinitionsHelpViewController(status: status)
            let host = laidOut(help.view)
            host.wantsLayer = true
            host.layer?.backgroundColor = Design.Surface.ground.cgColor
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 2_000, "\(name) render came out blank")
            if let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !directory.isEmpty {
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("bluetooth-definitions-help-\(name).png"))
            }
        }
    }

    // MARK: App packets only

    func testAppPacketsOnlyShowsExactlyTheDecodedRowsAndExplainsAnEmptyView() async throws {
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .bluetooth)
        pane.loadView()
        let phone = DeviceLogSourceOption.Machine(id: "phone", title: "Test iPhone", isSimulator: false)
        pane.acceptSources([DeviceLogSourceOption(machine: phone, title: "Bluetooth (USB)",
            kind: .bluetooth(udid: phone.id, overNetwork: false, toolPath: nil))])
        pane.installRowsForTesting([
            DeviceLogRow(time: "", level: "Info", process: "Bluetooth", subsystem: "ATT",
                message: "RX ACL handle=0x0040 ATT Handle Value Notification attribute=0x0040"),
            DeviceLogRow(time: "", level: "Info", process: "Bluetooth", subsystem: "App",
                message: "RX Example Watch → iPhone · Messages notify · LOCATION #1"),
            DeviceLogRow(time: "", level: "Warning", process: "Bluetooth", subsystem: "App",
                message: "RX Example Watch → iPhone · Messages notify · kind=LOCATION seq=2 ⚠ body.lat: needs 4 bytes, 2 left"),
            // Mentions "app" in its text but was not decoded: a substring filter would keep it.
            DeviceLogRow(time: "", level: "Info", process: "Bluetooth", subsystem: "HCI",
                message: "TX HCI Command 0x2008 LE Set Advertising Data app"),
        ])
        pane.setPacketFilter(.app)
        try await settled(pane)
        XCTAssertEqual(pane.packetFilter, .app)
        XCTAssertEqual(pane.visibleRowsForTools(limit: 20).map(\.level), ["Info", "Warning"])

        pane.setPacketFilter(.complete)
        try await settled(pane)
        XCTAssertEqual(pane.visibleRowsForTools(limit: 20).map(\.level), ["Info"], "a misfit is left out")

        pane.setPacketFilter(.all)
        try await settled(pane)
        XCTAssertEqual(pane.visibleRowsForTools(limit: 20).count, 4, "the filter hides; it never discards")

        pane.installRowsForTesting([
            DeviceLogRow(time: "", level: "Info", process: "Bluetooth", subsystem: "ATT", message: "raw"),
        ])
        pane.setPacketFilter(.app)
        try await settled(pane)
        XCTAssertTrue(pane.statusTextForTesting.contains("no packet definitions loaded"), pane.statusTextForTesting)
    }

    // MARK: Helpers

    /// User filtering projects off the main actor; wait for the published result.
    private func settled(_ pane: DeviceLogPaneViewController) async throws {
        for _ in 0..<200 where pane.isProjectingForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(pane.isProjectingForTesting)
    }

    /// Sized exactly as `ThemedPopover.reposition()` sizes it: the detached view's own fitting
    /// size, measured before it has ever been laid out at its final width. The panel shipped
    /// clipped because that first measurement was short; a host that laid out first and measured
    /// second hid it.
    private func laidOut(_ content: NSView) -> NSView {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = host.bounds
        host.addSubview(content)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testThePopoversFirstMeasurementHoldsEverythingWithItsPadding() throws {
        for status in [BluetoothDefinitionStatus.noCheckout, .missing(expected: file),
                       .failed(file, message: String(repeating: "line 7: a long compile error ", count: 6))] {
            let help = BluetoothDefinitionsHelpViewController(status: status)
            let host = laidOut(help.view)
            let padding = BluetoothDefinitionsHelpViewController.Metrics.padding
            // A text field draws its glyphs 2 pt inside its frame, so the frame may reach 2 pt further.
            let content = host.bounds.insetBy(dx: padding - 3, dy: padding - 3)
            for view in descendants(of: help.view) where view is NSTextField || view is ThemedButton {
                let frame = view.convert(view.bounds, to: host)
                XCTAssertTrue(content.contains(frame), "\(view) at \(frame) is outside \(content)")
                if let label = view as? NSTextField, label.cell?.wraps == true, !label.stringValue.isEmpty {
                    let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                    XCTAssertGreaterThanOrEqual(label.bounds.height + 1, needed, "\(label.stringValue.prefix(40)) is cut off")
                }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        descendants(of: view).first { $0.accessibilityIdentifier() == identifier }
    }
}
