import XCTest
@testable import ThreadingMobile

final class ThemedDialogActionTests: XCTestCase {
    func testRebuildingAnAlertKeepsThePressedActionIdentity() {
        let identities = (0..<100).map { _ in ThemedDialogAction("OK").id }
        XCTAssertEqual(Set(identities).count, 1)
    }

    func testValidationAndHandlerUpdatesDoNotReplaceTheAction() {
        var calls = 0
        let disabled = ThemedDialogAction("Rename", isEnabled: false)
        let enabled = ThemedDialogAction("Rename") { calls += 1 }
        XCTAssertEqual(disabled.id, enabled.id)
        enabled.perform()
        XCTAssertEqual(calls, 1)
    }

    func testDifferentChoicesHaveDifferentIdentities() {
        XCTAssertNotEqual(ThemedDialogAction("OK").id, ThemedDialogAction("Cancel").id)
        XCTAssertNotEqual(
            ThemedDialogAction("Remove").id,
            ThemedDialogAction("Remove", role: .destructive).id
        )
    }

    func testExplicitIdentitySupportsDuplicateAndChangingTitles() {
        let first = ThemedDialogAction("Choose", id: "first")
        XCTAssertNotEqual(first.id, ThemedDialogAction("Choose", id: "second").id)
        XCTAssertEqual(first.id, ThemedDialogAction("Updated choice", id: "first").id)
    }
}
