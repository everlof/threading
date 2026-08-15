import XCTest
@testable import Threading

@MainActor
final class BrowserStorageCommandServiceTests: XCTestCase {
    func testInvalidActionDoesNotResolveAPage() {
        let service = BrowserStorageCommandService()
        var resolvedPage = false
        var result: BrowserStorageCommandResult?

        service.execute(action: "list", context: {
            resolvedPage = true
            return nil
        }) { result = $0 }

        XCTAssertFalse(resolvedPage)
        XCTAssertEqual(result, .failure("action must be clear_site_data."))
    }

    func testMissingWebPageIsRefused() {
        let service = BrowserStorageCommandService()
        var result: BrowserStorageCommandResult?

        service.execute(action: " clear_site_data ", context: { nil }) { result = $0 }

        XCTAssertEqual(
            result,
            .failure("Open an http or https page before clearing browser site data.")
        )
    }

    func testDeniedOriginNeverRequestsDestructiveConfirmation() throws {
        let service = BrowserStorageCommandService()
        var requestedConfirmation = false
        var cleared = false
        var result: BrowserStorageCommandResult?
        let context = try makeContext(
            authorize: { decide in decide(false) },
            confirm: { _ in requestedConfirmation = true },
            clear: { _ in cleared = true }
        )

        service.execute(action: "clear_site_data", context: { context }) { result = $0 }

        XCTAssertEqual(
            result,
            .failure("The user did not allow browser access to example.com.")
        )
        XCTAssertFalse(requestedConfirmation)
        XCTAssertFalse(cleared)
    }

    func testPageChangeDuringAuthorizationStopsBeforeConfirmation() throws {
        let service = BrowserStorageCommandService()
        var current = true
        var authorize: ((Bool) -> Void)?
        var requestedConfirmation = false
        var result: BrowserStorageCommandResult?
        let context = try makeContext(
            authorize: { authorize = $0 },
            confirm: { _ in requestedConfirmation = true },
            isCurrent: { current }
        )

        service.execute(action: "clear_site_data", context: { context }) { result = $0 }
        current = false
        authorize?(true)

        XCTAssertEqual(
            result,
            .failure(
                "The shared browser page changed while access was being decided; retry "
                    + "against the site now on screen."
            )
        )
        XCTAssertFalse(requestedConfirmation)
    }

    func testCancelledConfirmationDoesNotClearData() throws {
        let service = BrowserStorageCommandService()
        var cleared = false
        var result: BrowserStorageCommandResult?
        let context = try makeContext(
            confirm: { decide in decide(false) },
            clear: { _ in cleared = true }
        )

        service.execute(action: "clear_site_data", context: { context }) { result = $0 }

        XCTAssertEqual(result, .failure("The user cancelled clearing browser site data."))
        XCTAssertFalse(cleared)
    }

    func testPageChangeDuringConfirmationRefusesWithoutClearing() throws {
        let service = BrowserStorageCommandService()
        var current = true
        var confirm: ((Bool) -> Void)?
        var cleared = false
        var result: BrowserStorageCommandResult?
        let context = try makeContext(
            confirm: { confirm = $0 },
            isCurrent: { current },
            clear: { _ in cleared = true }
        )

        service.execute(action: "clear_site_data", context: { context }) { result = $0 }
        current = false
        confirm?(true)

        XCTAssertEqual(
            result,
            .failure(
                "The browser page or tab changed before site data could be cleared; "
                    + "nothing was removed."
            )
        )
        XCTAssertFalse(cleared)
    }

    func testSuccessMessagesDescribePrivateSharedAndEmptyStores() throws {
        let service = BrowserStorageCommandService()
        let cases: [(BrowserSiteDataClearReport, String)] = [
            (
                .init(recordsRemoved: nil, context: .private),
                "Cleared the active tab's unique private WebKit data store."
            ),
            (
                .init(recordsRemoved: 2, context: .shared),
                "Cleared 2 WebKit website data records for example.com."
            ),
            (
                .init(recordsRemoved: 0, context: .shared),
                "WebKit reported no stored website data records for example.com; "
                    + "nothing needed removal."
            )
        ]

        for (report, expectedDetail) in cases {
            var result: BrowserStorageCommandResult?
            let context = try makeContext(
                clear: { completion in completion(report) }
            )

            service.execute(action: "clear_site_data", context: { context }) { result = $0 }

            XCTAssertTrue(result?.succeeded == true)
            XCTAssertTrue(result?.message.contains(expectedDetail) == true, result?.message ?? "")
            XCTAssertTrue(result?.message.contains("stayed loaded") == true)
        }
    }

    private func makeContext(
        authorize: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) },
        confirm: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) },
        isCurrent: @escaping () -> Bool = { true },
        clear: @escaping (@escaping (BrowserSiteDataClearReport) -> Void) -> Void = {
            $0(.init(recordsRemoved: 1, context: .shared))
        }
    ) throws -> BrowserStorageCommandContext {
        let url = try XCTUnwrap(URL(string: "https://example.com/account"))
        return BrowserStorageCommandContext(
            origin: try XCTUnwrap(BrowserOrigin(url: url)),
            authorize: authorize,
            confirmClear: confirm,
            isCurrent: isCurrent,
            clearSiteData: clear
        )
    }
}
