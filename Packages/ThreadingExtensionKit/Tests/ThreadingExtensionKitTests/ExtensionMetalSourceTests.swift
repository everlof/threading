import XCTest
@testable import ThreadingExtensionKit

/// The uniform ABI every host renderer binds: the struct the shader is compiled against and the
/// float layout the Mac and the phone upload are the same numbers. A reflection test in the app
/// (`ExtensionSurfaceFocusTests`) compiles the source and checks Metal agrees.
final class ExtensionMetalSourceTests: XCTestCase {
    private typealias Layout = ExtensionMetalSource.UniformLayout

    func testUniformLayoutPlacesFocusAfterTheValuesOnAFloat4Boundary() {
        XCTAssertEqual(Layout.maximumInputs, 8)
        XCTAssertEqual(Layout.valuesOffset, 4)
        XCTAssertEqual(Layout.focusOffset, 12)
        XCTAssertEqual(Layout.focusRegionCount, 2)
        XCTAssertEqual(Layout.floatCount, 20)
        XCTAssertEqual(Layout.byteCount, 80)
        XCTAssertEqual(Layout.focusByteOffset, 48)
        let float4Alignment = 4 * MemoryLayout<Float>.size
        XCTAssertEqual(Layout.focusByteOffset % float4Alignment, 0, "Metal would pad before focus")
        XCTAssertEqual(Layout.byteCount % float4Alignment, 0, "Metal would pad after focus")
        XCTAssertEqual(ExtensionMetalSource.FocusRegion.primary.rawValue, 0)
        XCTAssertEqual(ExtensionMetalSource.FocusRegion.secondary.rawValue, 1)
    }

    func testCompleteSourceDeclaresFocusAfterValues() throws {
        for isTextured in [false, true] {
            let source = ExtensionMetalSource.completeSource(
                extensionSource: "// author",
                fragmentFunction: ExtensionMetalSurface.defaultFragmentFunction,
                isTextured: isTextured
            )
            let values = try XCTUnwrap(source.range(of: "float values[8];"))
            let focus = try XCTUnwrap(source.range(of: "float4 focus[2];"))
            let end = try XCTUnwrap(source.range(of: "};", range: focus.upperBound..<source.endIndex))
            XCTAssertLessThan(values.upperBound, focus.lowerBound)
            XCTAssertEqual(
                source[focus.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines),
                "",
                "focus is the struct's last member"
            )
        }
    }

    func testValidationRefusesMoreInputsThanTheLayoutHolds() {
        let inputs = (0...Layout.maximumInputs).map {
            ExtensionSurfaceInputBinding(name: "input\($0)", value: .constant(0))
        }
        XCTAssertFalse(ExtensionMetalSurface(shaderResource: "Resources/a.metal", inputs: inputs).isValid)
        XCTAssertTrue(ExtensionMetalSurface(
            shaderResource: "Resources/a.metal",
            inputs: Array(inputs.prefix(Layout.maximumInputs))
        ).isValid)
    }
}
