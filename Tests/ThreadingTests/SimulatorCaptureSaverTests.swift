import AppKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorCaptureSaverTests: XCTestCase {
    private let device = SimulatorDevice(
        id: SimulatorDeviceID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        name: "iPhone 17 Pro",
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        runtimeName: "iOS 26.5",
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        family: .iPhone,
        state: .booted,
        lastBootedAt: nil
    )

    func testSuggestedNameCarriesTheDeviceAndExtension() {
        let name = SimulatorCaptureSaver.suggestedName(device: device, fileExtension: "png")
        XCTAssertTrue(name.hasPrefix("iPhone 17 Pro "), name)
        XCTAssertTrue(name.hasSuffix(".png"), name)
    }

    func testSuggestedNameSanitizesSlashesInTheDeviceName() {
        let slashed = SimulatorDevice(
            id: SimulatorDeviceID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            name: "iPad Pro 11/13",
            runtimeIdentifier: "r", runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "t", family: .iPad, state: .booted, lastBootedAt: nil
        )
        let name = SimulatorCaptureSaver.suggestedName(device: slashed, fileExtension: "mov")
        XCTAssertFalse(name.contains("/"), name)
        XCTAssertTrue(name.hasSuffix(".mov"))
    }

    func testWriteDataRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-saver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("frame.png")
        let bytes = Data([1, 2, 3, 4])
        XCTAssertTrue(SimulatorCaptureSaver.writeData(bytes, to: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
