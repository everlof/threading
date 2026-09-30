import Foundation
import XCTest
@testable import Threading

final class PhysicalDeviceCatalogTests: XCTestCase {
    func testDecodesOnlyReachablePairedIPhonesAndPrefersUSB() throws {
        let devices = try PhysicalDeviceCatalog.decodeAvailableIPhones(
            from: Data(Self.catalogJSON.utf8)
        )

        XCTAssertEqual(devices.map(\.name), ["Cable iPhone", "Wi-Fi iPhone"])
        XCTAssertEqual(devices.map(\.connection), [.usb, .localNetwork])
        XCTAssertEqual(devices[0].runtimeName, "iOS 26.5")
        XCTAssertTrue(devices[0].developerModeEnabled)
        XCTAssertTrue(devices[0].developerServicesAvailable)
        XCTAssertEqual(devices[1].id.rawValue, "00008140-000C208C1108801C")
    }

    func testRejectsAnUnboundedCoreDeviceCatalogue() {
        XCTAssertThrowsError(
            try PhysicalDeviceCatalog.decodeAvailableIPhones(
                from: Data(Self.catalogJSON.utf8),
                maximumDevices: 3
            )
        ) { error in
            XCTAssertEqual(error as? PhysicalDeviceControlError, .tooManyDevices(maximum: 3))
        }
    }

    func testRejectsMalformedHardwareIdentityInsteadOfTargetingByName() {
        let malformed = Self.catalogJSON.replacingOccurrences(
            of: "00008101-00065C583C0A001E",
            with: "../../not-a-device"
        )

        XCTAssertThrowsError(
            try PhysicalDeviceCatalog.decodeAvailableIPhones(from: Data(malformed.utf8))
        ) { error in
            guard case .invalidResponse = error as? PhysicalDeviceControlError else {
                return XCTFail("Expected an invalid CoreDevice response, got \(error)")
            }
        }
    }

    private static let catalogJSON = """
    {
      "result": {
        "devices": [
          {
            "identifier": "3FBD1A79-6BFC-5976-B98A-DEAA0030355D",
            "connectionProperties": {
              "pairingState": "paired",
              "transportType": "usb",
              "tunnelState": "connected"
            },
            "deviceProperties": {
              "name": "Cable iPhone",
              "osVersionNumber": "26.5",
              "developerModeStatus": "enabled",
              "ddiServicesAvailable": true
            },
            "hardwareProperties": {
              "deviceType": "iPhone",
              "platform": "iOS",
              "productType": "iPhone14,2",
              "udid": "00008101-00065C583C0A001E"
            }
          },
          {
            "identifier": "ECE91967-105E-5BAE-9110-E49CBB0DEBD3",
            "connectionProperties": {
              "pairingState": "paired",
              "transportType": "localNetwork",
              "tunnelState": "disconnected"
            },
            "deviceProperties": {
              "name": "Wi-Fi iPhone",
              "osVersionNumber": "26.6.2",
              "developerModeStatus": "enabled",
              "ddiServicesAvailable": true
            },
            "hardwareProperties": {
              "deviceType": "iPhone",
              "platform": "iOS",
              "productType": "iPhone17,1",
              "udid": "00008140-000C208C1108801C"
            }
          },
          {
            "identifier": "5196BC13-217D-5C4D-B88C-60F427B697D1",
            "connectionProperties": {
              "pairingState": "paired",
              "transportType": "localNetwork",
              "tunnelState": "unavailable"
            },
            "deviceProperties": { "name": "Offline iPhone" },
            "hardwareProperties": {
              "deviceType": "iPhone",
              "platform": "iOS",
              "udid": "00008120-001C24D23420201E"
            }
          },
          {
            "identifier": "8EA1A1E4-8F09-41FD-9AD5-3FC343BD4961",
            "connectionProperties": {
              "pairingState": "paired",
              "transportType": "localNetwork",
              "tunnelState": "connected"
            },
            "deviceProperties": { "name": "Watch" },
            "hardwareProperties": {
              "deviceType": "watch",
              "platform": "watchOS",
              "udid": "00008130-001A2B3C4D5E601E"
            }
          }
        ]
      }
    }
    """
}
