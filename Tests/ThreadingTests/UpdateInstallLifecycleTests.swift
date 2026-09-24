import Foundation
import XCTest
@testable import Threading

@MainActor
final class UpdateInstallLifecycleTests: XCTestCase {

    func testAStillRunningAppDoesNotClaimToBeInstallingAndCanRetryItsQuit() {
        defer { AppUpdater.clearInstallRelaunchPending() }
        let presenter = RecordingPresenter()
        let driver = UpdateUserDriver(presenter: presenter)
        var retryCount = 0

        driver.showInstallingUpdate(withApplicationTerminated: false) {
            retryCount += 1
        }

        XCTAssertEqual(presenter.dismissCount, 1)
        XCTAssertEqual(presenter.installingCount, 0)

        driver.showUpdateInFocus()
        XCTAssertEqual(presenter.retryCount, 1)
        XCTAssertEqual(presenter.focusCount, 0)

        presenter.retry?()
        XCTAssertEqual(retryCount, 1)
        XCTAssertTrue(AppUpdater.takeInstallRelaunchPending())
        XCTAssertFalse(AppUpdater.takeInstallRelaunchPending(), "one quit event must consume the exception")

        presenter.retry?()
        driver.dismissUpdateInstallation()
        XCTAssertFalse(AppUpdater.takeInstallRelaunchPending(), "ending the update clears unused consent")
        driver.showUpdateInFocus()
        XCTAssertEqual(presenter.retryCount, 1, "a finished update must not retain the retry")
        XCTAssertEqual(presenter.focusCount, 1)
    }

    func testAnAlreadyTerminatedAppOnlyShowsInstallationProgress() {
        let presenter = RecordingPresenter()
        let driver = UpdateUserDriver(presenter: presenter)

        driver.showInstallingUpdate(withApplicationTerminated: true) {
            XCTFail("Sparkle forbids retry after termination")
        }

        XCTAssertEqual(presenter.installingCount, 1)
        XCTAssertEqual(presenter.dismissCount, 0)
        driver.showUpdateInFocus()
        XCTAssertEqual(presenter.retryCount, 0)
        XCTAssertEqual(presenter.focusCount, 1)
    }

    private final class RecordingPresenter: UpdatePresenting {
        var installingCount = 0
        var dismissCount = 0
        var retryCount = 0
        var focusCount = 0
        var retry: (() -> Void)?

        func showCheckingForUpdates(cancel: @escaping () -> Void) {}
        func showUpdateFound(
            _ info: UpdateVersionInfo,
            origin: UpdateCheckOrigin,
            respond: @escaping (UpdateChoice) -> Void
        ) {}
        func showReleaseNotes(_ notes: UpdateReleaseNotes) {}
        func showDownloadStarted(cancel: @escaping () -> Void) {}
        func showDownloadProgress(_ progress: UpdateDownloadProgress) {}
        func showExtractionStarted() {}
        func showExtractionProgress(_ fraction: Double) {}
        func showReadyToInstall(respond: @escaping (UpdateChoice) -> Void) {}
        func showInstalling() { installingCount += 1 }
        func showReadyToRetryTermination(retry: @escaping () -> Void) {
            retryCount += 1
            self.retry = retry
        }
        func showUpdateInstalled(acknowledge: @escaping () -> Void) {}
        func showNoUpdateFound(message: String, detail: String, acknowledge: @escaping () -> Void) {}
        func showUpdateError(message: String, detail: String, acknowledge: @escaping () -> Void) {}
        func dismissUpdateUI() { dismissCount += 1 }
        func focusUpdateUI() { focusCount += 1 }
    }
}
