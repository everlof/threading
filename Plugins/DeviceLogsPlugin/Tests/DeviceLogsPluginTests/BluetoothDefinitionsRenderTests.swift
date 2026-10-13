import AppKit
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

/// The Bluetooth tab with app definitions loaded, drawn from a capture the shipping decoder reads:
/// discovery, a read, a notification, a fragmented frame and a value the definitions do not fit.
@MainActor
final class BluetoothDefinitionsRenderTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/Users/someone/app/.threading/bluetooth.yaml")

    func testRendersTheDecodedCaptureAndAppPacketsOnly() async throws {
        let rows = try Self.capture()
        XCTAssertEqual(rows.filter { $0.subsystem == BluetoothATTSession.appProtocolName }.count, 4)
        XCTAssertTrue(rows.contains { $0.message.hasPrefix("RX Pulse 4F2A → iPhone · Messages notify · LOCATION #412") })

        for (name, filter) in [("all-packets", BluetoothPacketFilter.all), ("app-packets-only", .app), ("fully-decoded-only", .complete)] {
            let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .bluetooth)
            pane.loadView()
            let phone = DeviceLogSourceOption.Machine(id: "phone", title: "iPhone", isSimulator: false)
            pane.acceptSources([DeviceLogSourceOption(machine: phone, title: "Bluetooth (USB)",
                kind: .bluetooth(udid: phone.id, overNetwork: false, toolPath: nil))])
            pane.installRowsForTesting(rows)
            pane.setPacketFilter(filter)
            for _ in 0..<200 where pane.isProjectingForTesting {
                try await Task.sleep(for: .milliseconds(10))
            }
            // The fixture has no checkout, so the pane's own off-main load reports that; let it
            // land, then show what a project with the guide's example would read.
            try await Task.sleep(for: .milliseconds(200))
            pane.applyDefinitionStatusForTesting(.loaded(file, characteristics: 2, types: 3),
                highlights: try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example).highlights)
            try render(pane.view, width: 1_180, height: 400, name: "bluetooth-\(name)")
        }
    }

    /// A device that teaches its own command table, decoded through the advanced example: every
    /// command name keeps one colour of its own.
    func testRendersLearnedCommandsInTheirOwnColours() async throws {
        var decoder = BluetoothPacketDecoder()
        let definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.advancedExample
            .replacingOccurrences(of: "message: CommandMessage", with: "handle: 0x002e\n        message: CommandMessage"))
        decoder.definitions = definitions
        func att(_ pdu: [UInt8]) -> [UInt8] {
            let l2cap = [UInt8(pdu.count), 0, 0x04, 0x00] + pdu
            return [0x40, 0x20, UInt8(l2cap.count), 0] + l2cap
        }
        func text(_ value: String) -> [UInt8] { [0xa0 | UInt8(value.utf8.count)] + Array(value.utf8) }
        let table: [(UInt8, String)] = [(0, "map_cmd"), (8, "fastmode"), (17, "map_settings"), (19, "error"), (20, "datetime"), (73, "steps_target")]
        let page: [UInt8] = [0x81, 0x00, 0x80 | UInt8(table.count)] + table.flatMap { [$0.0] + text($0.1) }
        // The page is read as the phone would: one response, then 22-byte Read Blobs.
        var read: [([UInt8], Bool)] = [([0x0a, 0x2e, 0x00], false), ([0x0b] + page.prefix(22), true)]
        for offset in stride(from: 22, to: page.count, by: 22) {
            read.append(([0x0c, 0x2e, 0x00, UInt8(offset), 0], false))
            read.append(([0x0d] + page[offset..<min(offset + 22, page.count)], true))
        }
        let packets: [([UInt8], Bool)] = [([0x12, 0x2e, 0x00, 0x92, 0x00, 0x00], false)] + read + [
            ([0x12, 0x2e, 0x00, 0x81, 0x08, 0xc3], false),
            ([0x1b, 0x2e, 0x00, 0x81, 0x13, 0x16], true),
            ([0x12, 0x2e, 0x00, 0x81, 0x14, 0x96, 0xcd, 0x07, 0xea, 0x0a, 0x0d, 0x0f, 0x06, 0x27], false),
            ([0x12, 0x2e, 0x00, 0x81, 0x49, 0xcd, 0x27, 0x10], false),
            ([0x12, 0x2e, 0x00, 0x92, 0x11, 0x02], false),
            ([0x12, 0x2e, 0x00, 0x81, 0x08, 0xc3], false),
        ]
        var data = BluetoothPacketTests.header()
        for (index, packet) in packets.enumerated() {
            data.append(Self.record([2] + att(packet.0), incoming: packet.1, seconds: 54_399 + index, microseconds: 0))
        }
        let rows = try decoder.append(data)
        XCTAssertTrue(rows.contains { $0.message.contains("datetime {year=2026 month=10 date=13 hour=15 minute=6 second=39}") }, rows.map(\.message).joined(separator: "\n"))
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .bluetooth)
        pane.loadView()
        let phone = DeviceLogSourceOption.Machine(id: "phone", title: "iPhone", isSimulator: false)
        pane.acceptSources([DeviceLogSourceOption(machine: phone, title: "Bluetooth (USB)",
            kind: .bluetooth(udid: phone.id, overNetwork: false, toolPath: nil))])
        pane.installRowsForTesting(rows)
        pane.setPacketFilter(.app)
        for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        pane.applyDefinitionStatusForTesting(.loaded(file, characteristics: 2, types: 1),
            learned: decoder.learned.summary(enums: definitions.learnedEnumNames),
            names: decoder.learned.names(definitions: definitions))
        try render(pane.view, width: 1_180, height: 330, name: "bluetooth-learned-commands")
    }

    func testRendersTheHelpPanelWithALoadedFile() throws {
        let help = BluetoothDefinitionsHelpViewController(status: .loaded(file, characteristics: 2, types: 3))
        help.loadView()
        // Measured as the popover measures it, before any layout at its final width.
        help.view.layoutSubtreeIfNeeded()
        let size = help.view.fittingSize
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        help.view.frame = host.bounds
        host.addSubview(help.view)
        try render(host, width: size.width, height: size.height, name: "bluetooth-definitions-help-loaded", hosted: true)
    }

    // MARK: Fixture

    /// A short session against the guide's example definitions, with the watch's characteristic
    /// pinned by handle as a capture started after discovery would need.
    static func capture() throws -> [DeviceLogRow] {
        var decoder = BluetoothPacketDecoder()
        decoder.definitions = try BluetoothPacketDefinitions.compile(
            BluetoothDefinitionsGuide.example.replacingOccurrences(of: "# handle: 0x0025", with: "handle: 0x0025")
        )
        let location = [0x01, 0x9c, 0x01] + s32(593_293_000) + s32(180_686_000) + [45, 0, 0x01]
        let status = [0x02, 0x9d, 0x01, 5] + Array("strap".utf8) + s16(2_150) + s16(-340) + s16(1_875)
        let notifyStatus = [0x1b, 0x25, 0x00] + status
        let l2cap = le16(notifyStatus.count) + [0x04, 0x00] + notifyStatus
        // The watch advertises its name, then the phone connects to it as handle 0x0040.
        let address: [UInt8] = [0x2a, 0x4f, 0x6a, 0x8d, 0x7c, 0xc4]
        let ad: [UInt8] = [0x02, 0x01, 0x06, 0x0b, 0x09] + Array("Pulse 4F2A".utf8)
        let report: [UInt8] = [0x3e, 0x02, 0x01, 0x00, 0x01] + address + [UInt8(ad.count)] + ad + [0xc0]
        let connected: [UInt8] = [0x3e, 0x01, 0x00] + le16(0x40) + [0x01, 0x01] + address + [UInt8](repeating: 0, count: 7)
        let packets: [(UInt8, [UInt8], Bool)] = [
            (1, [0x0c, 0x20, 0x02, 0x01, 0x00], false),
            (4, [0x0e, 0x04, 0x01, 0x0c, 0x20, 0x00], true),
            (4, [report[0], UInt8(report.count - 1)] + report.dropFirst(), true),
            (4, [connected[0], UInt8(connected.count - 1)] + connected.dropFirst(), true),
            (2, att([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28]), false),
            (2, att([0x09, 0x07, 0x2f, 0x00, 0x02, 0x30, 0x00, 0x19, 0x2a]), true),
            (2, att([0x0a, 0x30, 0x00]), false),
            (2, att([0x0b, 87]), true),
            (2, att([0x1b, 0x25, 0x00] + location), true),
            (2, acl(Array(l2cap.prefix(12)), boundary: 2), true),
            (2, acl(Array(l2cap.dropFirst(12)), boundary: 1), true),
            (2, att([0x1b, 0x25, 0x00, 0x01, 0x9e, 0x01, 0x00, 0x00]), true),
            (2, att([0x52, 0x40, 0x00, 0x10, 0x20]), false),
        ]
        var data = BluetoothPacketTests.header()
        for (index, packet) in packets.enumerated() {
            data.append(record([packet.0] + packet.1, incoming: packet.2, seconds: 47_160 + index, microseconds: 120_000 + index * 31_337))
        }
        return try decoder.append(data)
    }

    private static func att(_ pdu: [UInt8]) -> [UInt8] {
        acl(le16(pdu.count) + [0x04, 0x00] + pdu, boundary: 2)
    }

    private static func acl(_ data: [UInt8], boundary: Int) -> [UInt8] {
        le16(0x0040 | boundary << 12) + le16(data.count) + data
    }

    private static func record(_ h4: [UInt8], incoming: Bool, seconds: Int, microseconds: Int) -> Data {
        var data = Data()
        for value in [seconds, microseconds, h4.count + 4, h4.count + 4] {
            data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
        }
        data.append(contentsOf: [0, 0, 0, incoming ? 1 : 0])
        data.append(contentsOf: h4)
        return data
    }

    private static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
    private static func s16(_ value: Int) -> [UInt8] { le16(value & 0xffff) }
    private static func s32(_ value: Int) -> [UInt8] {
        [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    // MARK: Rendering

    private func render(_ view: NSView, width: CGFloat, height: CGFloat, name: String, hosted: Bool = false) throws {
        let host: NSView
        if hosted {
            host = view
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        } else {
            host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
        host.layoutSubtreeIfNeeded()
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.ground.cgColor
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000, "\(name) render came out blank")
        if let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !directory.isEmpty {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
