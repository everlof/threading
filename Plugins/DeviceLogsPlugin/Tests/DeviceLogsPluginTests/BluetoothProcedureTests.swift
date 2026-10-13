import AppKit
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

/// A Nordic Secure DFU told as one story: the device reboots into its bootloader one address up,
/// the image goes over with checksum reports, and the device comes back on a new firmware — or
/// does not. Uses only the shipped `nordic-dfu` profile; the project file pins handles and names
/// the firmware characteristic, as a capture without discovery needs.
final class BluetoothProcedureTests: XCTestCase {
    static let app: [UInt8] = [0x2a, 0x4f, 0x6a, 0x8d, 0x7c, 0xc4]       // C4:7C:8D:6A:4F:2A
    static let bootloader: [UInt8] = [0x2b, 0x4f, 0x6a, 0x8d, 0x7c, 0xc4] // …:2B

    static let yaml = """
        include: [nordic-dfu, gatt]
        firmware: Firmware Revision
        services:
          - name: Pins
            characteristics:
              - { name: Buttonless DFU, handle: 0x10, tx: NordicButtonlessRequest, rx: NordicButtonlessResponse }
              - { name: Secure DFU Control Point, handle: 0x20, tx: NordicDfuRequest, rx: NordicDfuResponse }
              - name: Secure DFU Packet
                handle: 0x22
                message:
                  switch-on: Secure DFU Control Point.type
                  cases:
                    COMMAND: { summary: "init packet {init}", seq: [{ id: init, type: bytes }] }
                    _: NordicDfuPacket
              - { name: Firmware Revision, handle: 0x30, message: GattText }
        """

    private var session = BluetoothATTSession()
    private var connection = 0x40
    private var rows: [BluetoothFlowState.Row] = []
    private let image = (0..<40).map { UInt8(($0 * 13) % 256) }
    private let initPacket: [UInt8] = [0x12, 0x34, 0x56, 0x78]

    override func setUp() async throws {
        session = BluetoothATTSession()
        session.definitions = try BluetoothPacketDefinitions.compile(Self.yaml)
        rows = []
    }

    // MARK: Fixtures

    private func at(_ time: Double) { session.time = 1_760_000_000 + time }

    @discardableResult
    private func write(_ handle: UInt8, _ value: [UInt8]) -> BluetoothATTSession.Summary {
        defer { rows += session.takeFlowRows() }
        return session.acl(BluetoothFlowTests.att([0x12, handle, 0x00] + value, connection: connection), incoming: false)
    }

    @discardableResult
    private func receive(_ opcode: UInt8, _ handle: UInt8, _ value: [UInt8]) -> BluetoothATTSession.Summary {
        defer { rows += session.takeFlowRows() }
        return session.acl(BluetoothFlowTests.att([opcode, handle, 0x00] + value, connection: connection), incoming: true)
    }

    private func readFirmware(_ text: String) {
        _ = session.acl(BluetoothFlowTests.att([0x0a, 0x30, 0x00], connection: connection), incoming: false)
        _ = session.acl(BluetoothFlowTests.att([0x0b] + Array(text.utf8), connection: connection), incoming: true)
        rows += session.takeFlowRows()
    }

    @discardableResult
    private func event(_ code: UInt8, _ parameters: [UInt8]) -> BluetoothATTSession.EventSummary? {
        defer { rows += session.takeFlowRows() }
        return session.event([code, UInt8(parameters.count)] + parameters)
    }

    private func connect(_ handle: Int, _ address: [UInt8]) -> BluetoothATTSession.EventSummary? {
        connection = handle
        return event(0x3e, [0x01, 0x00, UInt8(handle), 0x00, 0x00, 0x00] + address + [0x06, 0x00, 0x00, 0x00, 0x90, 0x01, 0x00])
    }

    private func disconnect(_ reason: UInt8) { event(0x05, [0x00, UInt8(connection), 0x00, reason]) }

    private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) } }

    /// The app connection, the firmware read, buttonless entry, the bootloader one address up,
    /// the init packet, then the image in two writes — the shape every Secure DFU has.
    private func dfuUpToTheImage(imageCRC: UInt32? = nil) {
        at(0); _ = connect(0x40, Self.app)
        at(0.1); readFirmware("1.0.0")
        at(1); write(0x10, [0x01])
        at(1.05); receive(0x1d, 0x10, [0x20, 0x01, 0x01])
        at(1.2); disconnect(0x13)
        let ad: [UInt8] = [0x03, 0x03, 0x59, 0xfe, 0x08, 0x09] + Array("DfuTarg".utf8)
        at(2); event(0x3e, [0x02, 0x01, 0x00, 0x01] + Self.bootloader + [UInt8(ad.count)] + ad + [0xc0])
        at(2.5); _ = connect(0x41, Self.bootloader)
        at(3); write(0x20, [0x06, 0x01])
        receive(0x1b, 0x20, [0x60, 0x06, 0x01] + le32(512) + le32(0) + le32(0))
        write(0x20, [0x01, 0x01] + le32(4))
        receive(0x1b, 0x20, [0x60, 0x01, 0x01])
        write(0x22, initPacket)
        write(0x20, [0x03])
        receive(0x1b, 0x20, [0x60, 0x03, 0x01] + le32(4) + le32(~CRC.crc32(initPacket, CRC.crc32Seed)))
        write(0x20, [0x04])
        receive(0x1b, 0x20, [0x60, 0x04, 0x01])
        at(4); write(0x20, [0x06, 0x02])
        receive(0x1b, 0x20, [0x60, 0x06, 0x01] + le32(4096) + le32(0) + le32(0))
        write(0x20, [0x01, 0x02] + le32(40))
        receive(0x1b, 0x20, [0x60, 0x01, 0x01])
        write(0x22, Array(image[0..<20]))
        write(0x22, Array(image[20..<40]))
        write(0x20, [0x03])
    }

    // MARK: Tests

    func testACompleteUpdateIsOneStoryAcrossThreeConnections() throws {
        dfuUpToTheImage()
        let crc = ~CRC.crc32(image, CRC.crc32Seed)
        let verified = receive(0x1b, 0x20, [0x60, 0x03, 0x01] + le32(40) + le32(crc))
        XCTAssertTrue(verified.text.contains("✓ device has all 40 B sent, crc32 matches"), verified.text)
        XCTAssertTrue(verified.text.hasPrefix("Kronaby") == false && verified.text.contains("C4:7C:8D:6A:4F:2A (bootloader) → iPhone"),
                      "the bootloader is named as the device it came from: \(verified.text)")
        write(0x20, [0x04])
        at(5); receive(0x1b, 0x20, [0x60, 0x04, 0x01])
        at(6); disconnect(0x13)
        at(8)
        let back = connect(0x42, Self.app)
        XCTAssertFalse(back?.text.contains("bootloader") ?? true)
        at(8.5); readFirmware("1.1.0")
        at(40); write(0x10, [0x02, 0x00])   // any later packet closes the settled attempt

        XCTAssertEqual(rows.first?.text, "DFU #1 started · C4:7C:8D:6A:4F:2A")
        let end = try XCTUnwrap(rows.last { $0.text.hasPrefix("DFU #1 ·") })
        XCTAssertEqual(end.level, .info)
        XCTAssertTrue(end.text.contains("completed in") && end.text.hasSuffix("firmware 1.0.0 → 1.1.0"), end.text)

        let attempt = try XCTUnwrap(session.procedures.history.attempts.last)
        XCTAssertEqual(attempt.outcome, .completed)
        XCTAssertEqual(attempt.steps, ["bootloader", "init packet", "image", "executed"])
        let timeline = BluetoothProcedureFormatting.timeline(attempt)
        for expected in ["started: Buttonless DFU write · ENTER_BOOTLOADER\n", "Disconnected C4:7C:8D:6A:4F:2A: Remote User Terminated",
                         "bootloader: Connected C4:7C:8D:6A:4F:2A (bootloader)", "the same device at C4:7C:8D:6A:4F:2B (was C4:7C:8D:6A:4F:2A)",
                         "image: Secure DFU Control Point write", "success: Connected C4:7C:8D:6A:4F:2A",
                         "firmware changed to 1.1.0", "WARNING: no GATT discovery after the firmware changed"] {
            XCTAssertTrue(timeline.contains(expected), "\(expected)\n---\n\(timeline)")
        }
    }

    func testCorruptedImageIsCaughtAndTheAbandonedTryNamesWhereAndWhy() throws {
        dfuUpToTheImage()
        receive(0x1b, 0x20, [0x60, 0x03, 0x01] + le32(40) + le32(0xdead_beef))
        XCTAssertTrue(rows.contains { $0.level == .error && $0.text.contains("✗ the device crc32 0xDEADBEEF but what was sent is") }, "\(rows)")
        at(6); disconnect(0x08)
        at(200); _ = connect(0x43, Self.app)
        let end = try XCTUnwrap(rows.last { $0.text.hasPrefix("DFU #1 ·") })
        XCTAssertEqual(end.level, .warning)
        XCTAssertTrue(end.text.contains("abandoned after") && end.text.contains("stopped at image: Secure DFU Control Point write · CREATE DATA 40 B, nothing for 2 min")
                      && end.text.contains("last error: C4:7C:8D:6A:4F:2A (bootloader) · Secure DFU image ✗ the device crc32"), end.text)
        let timeline = try BluetoothProcedureFormatting.timeline(XCTUnwrap(session.procedures.history.attempts.last))
        XCTAssertTrue(timeline.contains("WARNING: Disconnected C4:7C:8D:6A:4F:2A (bootloader): Connection Timeout"), timeline)
    }

    func testARefusedObjectFailsTheTryAndTheNextIsNumberedOn() throws {
        dfuUpToTheImage()
        receive(0x1b, 0x20, [0x60, 0x03, 0x01] + le32(40) + le32(~CRC.crc32(image, CRC.crc32Seed)))
        write(0x20, [0x04])
        receive(0x1b, 0x20, [0x60, 0x04, 0x05])
        let failed = try XCTUnwrap(rows.last { $0.text.hasPrefix("DFU #1 ·") })
        XCTAssertEqual(failed.level, .error)
        XCTAssertTrue(failed.text.contains("failed after") && failed.text.contains("EXECUTE INVALID_OBJECT"), failed.text)
        at(30); connection = 0x41; write(0x20, [0x06, 0x01])
        XCTAssertEqual(rows.last?.text.hasPrefix("DFU #2 started"), true)
    }

    func testHistoryRoundTripsAndAnInterruptedTryReadsAsAbandoned() throws {
        dfuUpToTheImage()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try session.procedures.history.save(to: url)
        let loaded = BluetoothProcedureHistory.load(from: url)
        let attempt = try XCTUnwrap(loaded.attempts.first)
        XCTAssertEqual(attempt.outcome, .abandoned)
        XCTAssertEqual(attempt.reason, "the capture ended during this try")
        XCTAssertEqual(attempt.entries.count, session.procedures.history.attempts.first?.entries.count)
        let text = BluetoothProcedureFormatting.all(loaded)
        XCTAssertTrue(text.hasPrefix("DFU #1 · C4:7C:8D:6A:4F:2A · abandoned after"), text)
        XCTAssertTrue(text.contains("firmware 1.0.0 → not read after"), text)
    }

    func testIdentityRulesNeedTheirAddressAndAdvertising() throws {
        XCTAssertEqual(BluetoothATTSession.incremented("C4:7C:8D:6A:4F:FF"), "C4:7C:8D:6A:4F:00", "Nordic adds without carry")
        at(0); _ = connect(0x40, Self.app)
        at(1); write(0x10, [0x01]); receive(0x1d, 0x10, [0x20, 0x01, 0x01])
        // Another device two addresses up is not the bootloader…
        at(2); XCTAssertFalse(connect(0x45, [0x2c, 0x4f, 0x6a, 0x8d, 0x7c, 0xc4])?.text.contains("bootloader") ?? true)
        // …nor is the right address after the window.
        at(120); XCTAssertFalse(connect(0x41, Self.bootloader)?.text.contains("bootloader") ?? true)
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile("""
            services: [{ name: S, characteristics: [{ name: C, handle: 1, message: bytes }] }]
            identities: [{ name: twin, after: { event: disconnected }, address: any }]
            """), "an identity with any address must say what it advertises")
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile("""
            services: [{ name: S, characteristics: [{ name: C, handle: 1, message: bytes }] }]
            procedures: [{ name: P, start: { characteristic: C }, success: { event: connected, after: nope } }]
            """), "after: must name a step")
    }

    /// The Timelines panel with a completed, a failed and an abandoned try, as the reader sees it.
    @MainActor
    func testRendersTheTimelinesPanel() throws {
        var history = BluetoothProcedureHistory()
        for (run, finish) in [(0, "complete"), (1, "refused"), (2, "corrupt")] {
            session = BluetoothATTSession()
            session.definitions = try BluetoothPacketDefinitions.compile(Self.yaml)
            session.procedures.history = history
            rows = []
            dfuUpToTheImage()
            let crc = ~CRC.crc32(image, CRC.crc32Seed)
            switch finish {
            case "complete":
                receive(0x1b, 0x20, [0x60, 0x03, 0x01] + le32(40) + le32(crc))
                write(0x20, [0x04]); at(5); receive(0x1b, 0x20, [0x60, 0x04, 0x01])
                at(6); disconnect(0x13); at(8); _ = connect(0x42, Self.app); at(8.5); readFirmware("1.1.0")
                at(40); write(0x10, [0x02, 0x00])
            case "refused":
                receive(0x1b, 0x20, [0x60, 0x03, 0x01] + le32(40) + le32(crc))
                write(0x20, [0x04]); receive(0x1b, 0x20, [0x60, 0x04, 0x05])
            default:
                receive(0x1b, 0x20, [0x60, 0x03, 0x01] + le32(40) + le32(0xdead_beef))
                at(6); disconnect(0x08); at(200); _ = connect(0x43, Self.app)
            }
            history = session.procedures.history
            _ = run
        }
        XCTAssertEqual(history.attempts.map(\.outcome), [.completed, .failed, .abandoned])
        let panel = BluetoothTimelineViewController(history: history)
        panel.loadView()
        panel.view.layoutSubtreeIfNeeded()
        let size = panel.view.fittingSize
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        panel.view.frame = host.bounds
        host.addSubview(panel.view)
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        guard let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] else { return }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            host.appearance = NSAppearance(named: appearance)
            // The popover's own surface, so the panel's text is judged against what it sits on.
            host.appearance?.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = Design.Surface.ground.cgColor }
            host.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("bluetooth-timelines-\(name).png"))
        }
    }
}
