import AppKit
import XCTest
@testable import Threading

/// What a view tells the pointer over itself, and the carving that keeps two answers apart.
///
/// The rule this exists to hold: **claiming nothing is not claiming the arrow**. Cursor
/// rectangles are a window's list, so a view that registers none inherits whatever is registered
/// behind it — a terminal's I-beam, a text view's, a field's. `PointerClaiming` makes that a
/// property a reviewer can read and a test can assert, instead of the absence of a method.
@MainActor
final class PointerClaimsTests: XCTestCase {

    /// A view that claims exactly what a test tells it to.
    private final class ClaimingView: NSView, PointerClaiming {
        var restingPointer: NSCursor?
        var pointerClaims: [PointerClaim] = []
    }

    private enum Fixture {
        static let bounds = NSRect(x: 0, y: 0, width: 200, height: 100)
    }

    private func view() -> ClaimingView {
        ClaimingView(frame: Fixture.bounds)
    }

    // MARK: - Helpers

    /// Every point of `view` is answered exactly once, by asserting the claims are disjoint and
    /// their areas sum to the view's own.
    private func assertTiles(
        _ view: ClaimingView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let claims = view.resolvedPointerClaims()
        for (index, claim) in claims.enumerated() {
            for other in claims[claims.index(after: index)...] {
                XCTAssertFalse(
                    claim.rect.intersects(other.rect),
                    "\(claim.rect) and \(other.rect) overlap, which AppKit leaves undefined",
                    file: file, line: line
                )
            }
        }
        let claimed = claims.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(
            claimed, view.bounds.width * view.bounds.height, accuracy: 0.5,
            "disjoint claims summing to the view's area cover all of it and no more",
            file: file, line: line
        )
    }

    // MARK: - Resting

    func testAViewThatClaimsNothingRegistersNothing() {
        let view = view()

        XCTAssertTrue(
            view.resolvedPointerClaims().isEmpty,
            "nil at rest is the statement that what is behind this view should answer"
        )
    }

    func testARestingCursorCoversTheWholeView() {
        let view = view()
        view.restingPointer = .arrow

        XCTAssertEqual(view.resolvedPointerClaims(), [PointerClaim(view.bounds, .arrow)])
    }

    func testEveryThemedControlAnswersForItselfByDefault() {
        let button = ThemedButton(title: "Ask AI", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 80, height: 24)

        XCTAssertEqual(
            button.resolvedPointerClaims(), [PointerClaim(button.bounds, .arrow)],
            "a control over a terminal or a transcript must not inherit their I-beam"
        )
    }

    // MARK: - Carving

    func testASpecificClaimIsCutOutOfTheRestingCursorRatherThanCoveredByIt() {
        let view = view()
        let grip = NSRect(x: 80, y: 40, width: 40, height: 20)
        view.restingPointer = .arrow
        view.pointerClaims = [PointerClaim(grip, .resizeUpDown)]

        let claims = view.resolvedPointerClaims()
        XCTAssertEqual(claims.first, PointerClaim(grip, .resizeUpDown), "the specific claim first")
        XCTAssertTrue(
            claims.dropFirst().allSatisfy { $0.cursor === NSCursor.arrow && !$0.rect.intersects(grip) },
            "and the rest of the view around it"
        )
        assertTiles(view)
    }

    func testAnEarlierClaimKeepsTheGroundItSharesWithALaterOne() {
        let view = view()
        let corner = NSRect(x: 0, y: 0, width: 20, height: 100)
        view.pointerClaims = [
            PointerClaim(corner, .crosshair),
            PointerClaim(view.bounds, .resizeUpDown)
        ]

        let claims = view.resolvedPointerClaims()
        XCTAssertEqual(claims.first, PointerClaim(corner, .crosshair))
        XCTAssertTrue(
            claims.dropFirst().allSatisfy { !$0.rect.intersects(corner) },
            "a band stated after a corner does not have to be trimmed around it by hand"
        )
        view.restingPointer = .arrow
        assertTiles(view)
    }

    func testAClaimReachingPastTheViewIsClippedToIt() {
        let view = view()
        view.pointerClaims = [PointerClaim(view.bounds.insetBy(dx: -50, dy: -50), .pointingHand)]

        XCTAssertEqual(view.resolvedPointerClaims(), [PointerClaim(view.bounds, .pointingHand)])
    }

    func testAnEmptyClaimIsNotRegistered() {
        let view = view()
        view.pointerClaims = [PointerClaim(NSRect(x: 300, y: 0, width: 10, height: 10), .crosshair)]

        XCTAssertTrue(
            view.resolvedPointerClaims().isEmpty,
            "a claim entirely outside the view names no ground at all"
        )
    }

    /// The carve is a band decomposition rather than each piece being split against each hole in
    /// turn, so a surface with many claims — an annotation overlay's markers — stays countable.
    func testManyClaimsLeaveACountableNumberOfRectangles() {
        let view = view()
        view.restingPointer = .crosshair
        view.pointerClaims = (0..<12).map { index in
            PointerClaim(
                NSRect(x: CGFloat(index) * 16 + 2, y: 30, width: 10, height: 10),
                .pointingHand
            )
        }

        let claims = view.resolvedPointerClaims()
        XCTAssertEqual(claims.filter { $0.cursor === NSCursor.pointingHand }.count, 12)
        XCTAssertLessThanOrEqual(
            claims.count, 4 * view.pointerClaims.count,
            "the remainder is decomposed in bands, not split hole by hole"
        )
        assertTiles(view)
    }

    // MARK: - Refresh

    func testMovedClaimsAreRegisteredAgainOnTheNextReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = view()
        window.contentView?.addSubview(view)
        view.restingPointer = .arrow
        view.pointerClaims = [PointerClaim(NSRect(x: 0, y: 0, width: 20, height: 100), .crosshair)]
        view.resetCursorRects()

        view.pointerClaims = [PointerClaim(NSRect(x: 40, y: 0, width: 20, height: 100), .crosshair)]
        view.refreshPointerClaims()

        XCTAssertEqual(
            view.resolvedPointerClaims().first?.rect,
            NSRect(x: 40, y: 0, width: 20, height: 100),
            "AppKit re-asks only when the view's own geometry moved, so a view whose claims "
                + "moved inside an unchanged frame has to say so"
        )
    }
}
