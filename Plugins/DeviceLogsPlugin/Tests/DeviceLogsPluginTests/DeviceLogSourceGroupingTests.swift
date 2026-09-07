import Foundation
import XCTest
@testable import DeviceLogsPlugin

/// One flat list put a simulator, a phone and twenty-six of that phone's apps side by side as
/// equals, and recents hoisted two of the apps above the machines they are installed on. It read
/// as a jumble because it was one.
///
/// These pin the two properties that stop it being one: a source knows its machine, and a source's
/// title is what it is called *within* that machine rather than a sentence carrying the device's
/// name along with it.
final class DeviceLogSourceGroupingTests: XCTestCase {

    private let phone = DeviceLogSourceOption.Machine(
        id: "00008140-000C208C1108801C", title: "David's 16 Pro", isSimulator: false
    )
    private let simulator = DeviceLogSourceOption.Machine(
        id: "4111208A-4B29-40E1-8C66-1B8AE2A1BF1F", title: "iPhone 17 Pro", isSimulator: true
    )

    func testEverySourceOfADeviceSharesThatDevicesMachine() {
        let sources = [
            DeviceLogSourceOption(machine: phone, title: "System log (USB)",
                                  kind: .device(udid: phone.id, overNetwork: false)),
            DeviceLogSourceOption(machine: phone, title: "Kronaby",
                                  kind: .app(deviceID: phone.id, bundleID: "com.a.k", appName: "Kronaby")),
            DeviceLogSourceOption(machine: phone, title: "Lotus",
                                  kind: .app(deviceID: phone.id, bundleID: "com.l.w", appName: "Lotus")),
        ]
        XCTAssertEqual(Set(sources.map(\.machine)), [phone], "an app must belong to its phone")
    }

    /// The device's name belongs to the machine and is stated once. It used to be spliced into
    /// every system-log title — "David's 16 Pro — system log (USB)" — and into an app's title as a
    /// suffix whenever a second device appeared, which is a name repeated twenty-seven times and a
    /// menu whose rows all start with the same words.
    func testASourceTitleNamesTheSourceRatherThanTheDevice() {
        let log = DeviceLogSourceOption(
            machine: phone, title: "System log (USB)",
            kind: .device(udid: phone.id, overNetwork: false)
        )
        XCTAssertFalse(log.title.contains(phone.title), "the device's name is the machine's, not the source's")
        XCTAssertTrue(log.title.contains("USB"), "the transport describes this reader, so it stays")
        XCTAssertEqual(log.machine.title, "David's 16 Pro")
    }

    /// Two machines both offer a "System log". Only the machine tells them apart, which is why the
    /// pane's identity is scoped to it: a bare title would make switching phones look like staying
    /// put, and the reader would never restart.
    func testTwoMachinesOfferingTheSameSourceTitleAreStillDistinct() {
        let a = DeviceLogSourceOption(machine: phone, title: "System log (USB)",
                                      kind: .device(udid: phone.id, overNetwork: false))
        let b = DeviceLogSourceOption(machine: simulator, title: "System log (USB)",
                                      kind: .simulator(udid: simulator.id))
        XCTAssertEqual(a.title, b.title)
        XCTAssertNotEqual(a.machine, b.machine)
        XCTAssertNotEqual("\(a.machine.id)/\(a.title)", "\(b.machine.id)/\(b.title)")
    }

    func testASimulatorIsItsOwnMachineAndSaysSo() {
        let sim = DeviceLogSourceOption(machine: simulator, title: "System log",
                                        kind: .simulator(udid: simulator.id))
        XCTAssertTrue(sim.machine.isSimulator)
        XCTAssertEqual(sim.machine.title, "iPhone 17 Pro")
    }
}

import AppKit
import ThreadingDesignKit

/// The control bar, drawn, because the complaint that started this was about how the list looked
/// rather than about what it contained.
@MainActor
final class DeviceLogControlBarRenderTests: XCTestCase {

    /// Found by rendering: "App log" stood beside a simulator, which has one log and no choice to
    /// make. Route visibility used to be set only when a reader started, so the bar could describe
    /// a decision that did not exist.
    func testTheRouteControlAppearsOnlyForAnAppWhichIsTheOnlyThingWithTwoLogs() throws {
        let phone = DeviceLogSourceOption.Machine(id: "P", title: "Phone", isSimulator: false)
        let simulator = DeviceLogSourceOption.Machine(id: "S", title: "Sim", isSimulator: true)
        let controller = DeviceLogPaneViewController(owningSessionID: UUID().uuidString)
        controller.loadView()

        controller.installSourcesForTesting([
            DeviceLogSourceOption(machine: simulator, title: "System log",
                                  kind: .simulator(udid: simulator.id)),
        ])
        XCTAssertTrue(controller.isRouteControlHiddenForTesting, "a simulator has one log")

        controller.installSourcesForTesting([
            DeviceLogSourceOption(machine: phone, title: "Kronaby",
                                  kind: .app(deviceID: phone.id, bundleID: "c.k", appName: "Kronaby")),
        ])
        XCTAssertFalse(controller.isRouteControlHiddenForTesting, "an app has two, so it gets a choice")
    }

    func testRendersTheDeviceAndSourceControls() throws {
        let phone = DeviceLogSourceOption.Machine(
            id: "00008140", title: "David's 16 Pro", isSimulator: false
        )
        let simulator = DeviceLogSourceOption.Machine(
            id: "4111208A", title: "iPhone 17 Pro", isSimulator: true
        )
        var fixture = [
            DeviceLogSourceOption(machine: simulator, title: "System log",
                                  kind: .simulator(udid: simulator.id)),
            DeviceLogSourceOption(machine: phone, title: "System log (USB)",
                                  kind: .device(udid: phone.id, overNetwork: false)),
        ]
        for app in ["Kronaby", "Lotus", "Barney", "Calendarly", "Festina", "Inrista", "Threading"] {
            fixture.append(DeviceLogSourceOption(
                machine: phone, title: app,
                kind: .app(deviceID: phone.id, bundleID: "com.x.\(app)", appName: app)
            ))
        }

        let controller = DeviceLogPaneViewController(owningSessionID: UUID().uuidString)
        controller.loadView()
        controller.installSourcesForTesting(fixture)
        controller.installRowsForTesting([
            DeviceLogRow(time: "11:01:02.493", level: "Debug", process: "Kronaby",
                         subsystem: "bluetooth", message: "WatchProviderStub.swift:121 handle(event:)"),
        ])

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            host.widthAnchor.constraint(equalToConstant: 900),
            host.heightAnchor.constraint(equalToConstant: 200),
        ])
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
              !directory.isEmpty else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("device-log-control-bar.png"))
        print("rendered \(directory)/device-log-control-bar.png")
    }
}
