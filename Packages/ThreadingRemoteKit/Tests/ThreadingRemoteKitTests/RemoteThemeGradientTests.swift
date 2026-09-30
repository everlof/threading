import XCTest
@testable import ThreadingRemoteKit

final class RemoteThemeGradientTests: XCTestCase {
    func testOlderThemeDecodesWithoutABackdropAndNewRecipeRoundTrips() throws {
        let old = Data(#"{"id":"old","name":"Old","mode":"dark","colors":{},"material":{"panelRadius":8,"controlRadius":4,"borderWidth":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteThemeDTO.self, from: old)
        XCTAssertNil(decoded.material.backdropGradient)
        let gradient = RemoteThemeGradient(
            stops: [.init(color: "#102030", position: 0), .init(color: "#302010", position: 1)],
            angleDegrees: 135, drift: .init()
        )
        let theme = RemoteThemeDTO(
            id: decoded.id, name: decoded.name, mode: decoded.mode, colors: decoded.colors,
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1, backdropGradient: gradient)
        )
        XCTAssertEqual(try JSONDecoder().decode(RemoteThemeDTO.self, from: JSONEncoder().encode(theme)), theme)
        XCTAssertEqual(try JSONDecoder().decode(ThemeGradientDrift.self, from: Data("{}".utf8)), .init())
    }

    func testGeometryMirrorsAcrossPlatformsAndClosesTheLoop() {
        let drift = ThemeGradientDrift(duration: 24, distance: 0.2)
        for angle in [0.0, 45, 90, 180, 270] {
            for phase in ThemeGradientDrift.phases {
                let mac = ThemeGradientGeometry.endpoints(angleDegrees: angle, flipped: false, drift: drift, phase: phase)
                let phone = ThemeGradientGeometry.endpoints(angleDegrees: angle, flipped: true, drift: drift, phase: phase)
                XCTAssertEqual(mac.start.x, phone.start.x, accuracy: 0.000001)
                XCTAssertEqual(mac.start.y, 1 - phone.start.y, accuracy: 0.000001)
                XCTAssertEqual(mac.end.y, 1 - phone.end.y, accuracy: 0.000001)
                XCTAssertEqual(hypot(mac.end.x - mac.start.x, mac.end.y - mac.start.y), 1, accuracy: 0.000001)
            }
            let first = ThemeGradientGeometry.endpoints(angleDegrees: angle, flipped: false, drift: drift)
            let last = ThemeGradientGeometry.endpoints(angleDegrees: angle, flipped: false, drift: drift, phase: 1)
            XCTAssertEqual(first.start.x, last.start.x, accuracy: 0.000001)
            XCTAssertEqual(first.end.y, last.end.y, accuracy: 0.000001)
        }
        let top = ThemeGradientGeometry.endpoints(angleDegrees: 0, flipped: true)
        XCTAssertEqual(top.start.y, 1)
        XCTAssertEqual(top.end.y, 0)
    }

    func testUntrustedRecipeBoundsAreCheckedBeforeRendering() {
        for duration in [Double.nan, .infinity, -1, 0, 7.9, 121] {
            XCTAssertFalse(ThemeGradientDrift(duration: duration).isValid)
        }
        for distance in [Double.nan, .infinity, -1, 0, 0.26] {
            XCTAssertFalse(ThemeGradientDrift(distance: distance).isValid)
        }
        let stops = Array(repeating: RemoteThemeGradient.Stop(color: "#101010", position: 0), count: 9)
        XCTAssertFalse(RemoteThemeGradient(stops: stops, angleDegrees: 0).hasValidGeometry)
        XCTAssertFalse(RemoteThemeGradient(stops: Array(stops.prefix(2)), angleDegrees: .nan).hasValidGeometry)
    }
}
