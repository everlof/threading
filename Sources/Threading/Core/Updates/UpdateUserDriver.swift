import Foundation
import Sparkle

// MARK: - The presentation seam

/// What the update UI must be able to show, in the app's own vocabulary.
///
/// `UpdateUserDriver` is the only caller and `UpdatePresenter` the only conformer; the
/// protocol exists so the boundary between Sparkle's lifecycle and Threading's sheets is a
/// set of named facts rather than a shared object graph — and so the driver can be exercised
/// in tests against a recording presenter without a window ever existing.
@MainActor
protocol UpdatePresenting: AnyObject {

    /// A person chose Check for Updates and the feed has not answered yet. Scheduled checks
    /// never surface this — background traffic is not something to draw.
    func showCheckingForUpdates(cancel: @escaping () -> Void)

    /// The feed offered an update; `respond` must eventually be called exactly once.
    func showUpdateFound(
        _ info: UpdateVersionInfo,
        origin: UpdateCheckOrigin,
        respond: @escaping (UpdateChoice) -> Void
    )

    /// Linked release notes resolved (or failed) after the found sheet went up.
    func showReleaseNotes(_ notes: UpdateReleaseNotes)

    func showDownloadStarted(cancel: @escaping () -> Void)
    func showDownloadProgress(_ progress: UpdateDownloadProgress)

    /// Extraction replaces the download stage; past this point the download cancel is dead.
    func showExtractionStarted()
    func showExtractionProgress(_ fraction: Double)

    func showReadyToInstall(respond: @escaping (UpdateChoice) -> Void)
    func showInstalling()

    /// Rare by design: only reachable when the updater outlives the relaunch.
    func showUpdateInstalled(acknowledge: @escaping () -> Void)

    func showNoUpdateFound(message: String, detail: String, acknowledge: @escaping () -> Void)
    func showUpdateError(message: String, detail: String, acknowledge: @escaping () -> Void)

    /// Tear down whatever is showing. Sparkle calls this when a session ends however it ends.
    func dismissUpdateUI()

    /// Bring whatever is showing to the front; the user asked for a check mid-session.
    func focusUpdateUI()
}

// MARK: - The driver

/// Threading's replacement for `SPUStandardUserDriver`.
///
/// Sparkle's stock driver brings its own AppKit windows, which `docs/THEME_BOUNDARY.md`
/// exists to keep out of this app. This implementation reduces every callback to the
/// provider-neutral values in `UpdateFlow.swift` and hands them to `UpdatePresenting`;
/// nothing downstream of this file sees a Sparkle type.
///
/// The permission request is answered here with no UI at all: Threading already owns that
/// choice as `AppSettings.automaticUpdateChecksEnabled` (Settings ▸ General), and `AppUpdater`
/// pushes it into the updater on every settings change — so Sparkle should never need to ask,
/// and if it does, the recorded setting *is* the answer. The system profile is never sent;
/// the Privacy page's description of what an update check reveals depends on that.
@MainActor
final class UpdateUserDriver: NSObject {

    private let presenter: UpdatePresenting
    private let automaticChecksApproved: () -> Bool

    /// Reset when a download begins, because one driver serves many update sessions.
    private var downloadProgress = UpdateDownloadProgress()

    init(
        presenter: UpdatePresenting,
        automaticChecksApproved: @escaping () -> Bool = {
            AppSettings.shared.automaticUpdateChecksEnabled
        }
    ) {
        self.presenter = presenter
        self.automaticChecksApproved = automaticChecksApproved
    }

    // MARK: - Translation

    private func versionInfo(for item: SUAppcastItem) -> UpdateVersionInfo {
        UpdateVersionInfo(
            version: item.displayVersionString,
            isInformational: item.isInformationOnlyUpdate,
            isCritical: item.isCriticalUpdate,
            infoURL: item.infoURL,
            releaseNotes: releaseNotes(for: item)
        )
    }

    /// Threading's own appcast embeds Markdown in the item description
    /// (`sparkle:format="markdown"`, the `scripts/generate_appcast.sh` contract), so the
    /// common case needs no second fetch. A feed that links notes instead gets `.pending`,
    /// which Sparkle resolves through `showUpdateReleaseNotes`.
    private func releaseNotes(for item: SUAppcastItem) -> UpdateReleaseNotes {
        if let description = item.itemDescription, !description.isEmpty {
            return .embedded(description)
        }
        if item.releaseNotesURL != nil {
            return .pending
        }
        return .none
    }

    private static func sparkleChoice(_ choice: UpdateChoice) -> SPUUserUpdateChoice {
        switch choice {
        case .install: return .install
        case .dismiss: return .dismiss
        case .skip: return .skip
        }
    }
}

// MARK: - SPUUserDriver

extension UpdateUserDriver: SPUUserDriver {

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        let approved = automaticChecksApproved()
        ThreadingLogger.updates.debug(
            "Update permission answered automatic=\(approved, privacy: .public) system_profile=false"
        )
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: approved,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        ThreadingLogger.updates.info("User-initiated update check started")
        presenter.showCheckingForUpdates(cancel: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        ThreadingLogger.updates.info(
            "Update found version=\(appcastItem.displayVersionString, privacy: .private(mask: .hash)) user_initiated=\(state.userInitiated, privacy: .public) informational=\(appcastItem.isInformationOnlyUpdate, privacy: .public) critical=\(appcastItem.isCriticalUpdate, privacy: .public)"
        )
        presenter.showUpdateFound(
            versionInfo(for: appcastItem),
            origin: state.userInitiated ? .user : .scheduled
        ) { choice in
            reply(Self.sparkleChoice(choice))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let text = UpdateReleaseNotesDecoding.text(
            from: downloadData.data,
            encodingName: downloadData.textEncodingName
        )
        ThreadingLogger.updates.info(
            "Update release notes received bytes=\(downloadData.data.count, privacy: .public) decoded=\(text != nil, privacy: .public)"
        )
        presenter.showReleaseNotes(text.map { .downloaded($0) } ?? .unavailable)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        ThreadingLogger.updates.error(
            "Release notes failed to download: \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
        presenter.showReleaseNotes(.unavailable)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // Sparkle populates this error with alert-ready strings covering the "no update for
        // you" reasons it can tell apart — already newest, newer than the feed, Mac too old,
        // macOS too old or too new — so the honest sheet is its words rather than a hardcoded
        // "up to date" that would misreport the hardware and OS cases.
        //
        // A channel the updater is not subscribed to is deliberately *not* among them:
        // SPUBasicUpdateDriver says so in as many words ("we can't tell the user about them")
        // and reports being on the latest version. That is not a gap to paper over here. The
        // one way to reach it is running a beta after choosing stable in Settings, and the
        // truthful answer there is that nothing is being offered — the next stable release
        // outranks that beta by construction (scripts/release_tag_policy.sh), so it arrives on
        // its own. Inventing a "you are on a beta" sheet would mean inferring from an error
        // code what Sparkle just said it could not determine.
        let nsError = error as NSError
        ThreadingLogger.updates.info(
            "Update check completed without an offer domain=\(nsError.domain, privacy: .private(mask: .hash)) code=\(nsError.code, privacy: .public)"
        )
        presenter.showNoUpdateFound(
            message: nsError.localizedDescription,
            detail: nsError.localizedRecoverySuggestion ?? "",
            acknowledge: acknowledgement
        )
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        ThreadingLogger.updates.error(
            "Updater error: \(nsError.localizedDescription, privacy: .private(mask: .hash))"
        )
        presenter.showUpdateError(
            message: nsError.localizedDescription,
            detail: nsError.localizedFailureReason
                ?? nsError.localizedRecoverySuggestion
                ?? "",
            acknowledge: acknowledgement
        )
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadProgress = UpdateDownloadProgress()
        ThreadingLogger.updates.info("Update download started")
        presenter.showDownloadStarted(cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        downloadProgress.expect(expectedContentLength)
        presenter.showDownloadProgress(downloadProgress)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadProgress.receive(length)
        presenter.showDownloadProgress(downloadProgress)
    }

    func showDownloadDidStartExtractingUpdate() {
        ThreadingLogger.updates.info("Update extraction started")
        presenter.showExtractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        presenter.showExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ThreadingLogger.updates.notice("Update ready to install and relaunch")
        presenter.showReadyToInstall { choice in
            reply(Self.sparkleChoice(choice))
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // Threading terminates cleanly on the quit event Sparkle sends, so the retry handler
        // goes unused; the sheet's only job is to say why the app is about to disappear.
        ThreadingLogger.updates.notice(
            "Update installation started application_terminated=\(applicationTerminated, privacy: .public)"
        )
        presenter.showInstalling()
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        ThreadingLogger.updates.info(
            "Update installation completed relaunched=\(relaunched, privacy: .public)"
        )
        presenter.showUpdateInstalled(acknowledge: acknowledgement)
    }

    func showUpdateInFocus() {
        ThreadingLogger.updates.debug("Update UI focused")
        presenter.focusUpdateUI()
    }

    func dismissUpdateInstallation() {
        ThreadingLogger.updates.debug("Update UI dismissed")
        presenter.dismissUpdateUI()
    }
}
