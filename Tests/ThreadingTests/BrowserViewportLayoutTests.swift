import XCTest

@testable import Threading

final class BrowserViewportLayoutTests: XCTestCase {

    func testAutomaticViewportFillsItsHost() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: nil
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 760, height: 1_000))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 0, y: 0, width: 760, height: 1_000)
        )
    }

    func testShortResponsiveViewportStartsAtThePageTop() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: CGSize(width: 760, height: 656)
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 760, height: 1_000))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 0, y: 0, width: 760, height: 656),
            "unused vertical canvas belongs below the page, never between it and the address bar"
        )
    }

    func testResponsiveViewportCentresOnlyAcrossTheUnusedWidth() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: CGSize(width: 390, height: 844)
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 760, height: 1_000))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 185, y: 0, width: 390, height: 844)
        )
    }

    func testOversizedViewportStartsAtItsDocumentOriginAndPans() throws {
        let layout = try XCTUnwrap(BrowserViewportLayout.resolve(
            visibleSize: CGSize(width: 760, height: 1_000),
            requestedViewport: CGSize(width: 1_440, height: 1_200)
        ))

        XCTAssertEqual(layout.canvasSize, CGSize(width: 1_440, height: 1_200))
        XCTAssertEqual(
            layout.viewportFrame,
            CGRect(x: 0, y: 0, width: 1_440, height: 1_200)
        )
    }
}
