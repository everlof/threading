import Foundation
import Sparkle

/// Threading's one door to Sparkle.
///
/// Sparkle is contained in `Core/Updates` rather than reached for at call sites, for the same
/// reason the invisible `NSColorWell` lives inside `ThemeSwatchView`: its standard controller
/// brings its own windows, and this app's design system exists to keep third-party chrome out
/// of the interface. The standard controller is gone — `SPUUpdater` is driven directly through
/// `UpdateUserDriver`, whose every stage renders as Threading's own sheets
/// (`UpdatePresenter`). The one window that remains Sparkle's is the installer agent's
/// post-termination progress bar, which no user driver can take over; `releasing.md` records
/// why that is acceptable.
///
/// The user's switch is the authority. `SUEnableAutomaticChecks` in Info.plist is only the
/// shipped default; `AppSettings.automaticUpdateChecksEnabled` is what Settings ▸ General
/// writes, and it is pushed into the updater on every settings change so the two can never
/// disagree about whether Threading is allowed to talk to its release feed. The same recorded
/// value answers Sparkle's first-run permission request inside `UpdateUserDriver`, so that
/// prompt never draws.
@MainActor
final class AppUpdater {

    static let shared = AppUpdater()

    private let presenter = UpdatePresenter()
    private let updater: SPUUpdater

    /// Whether `startUpdater()` succeeded. A start failure — a malformed feed URL, a broken
    /// bundle — leaves an updater no check may be sent to, and the menu item validates
    /// against this rather than offering a command that would assert.
    private let started: Bool

    /// Sparkle holds its delegate weakly; this reference is what keeps it alive.
    private let feedDelegate = FeedDelegate()

    private let appEvents = AppEventObservations()

    private init() {
        let driver = UpdateUserDriver(presenter: presenter)
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: feedDelegate
        )

        do {
            try updater.start()
            started = true
        } catch {
            started = false
            ThreadingLogger.updates.error(
                "Sparkle failed to start: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }

        apply(AppSettings.shared.automaticUpdateChecksEnabled)
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.apply(AppSettings.shared.automaticUpdateChecksEnabled)
        }
    }

    // MARK: - State

    /// Whether Threading is currently allowed to ask its release feed anything.
    var automaticChecksEnabled: Bool {
        updater.automaticallyChecksForUpdates
    }

    private func apply(_ enabled: Bool) {
        // The user's switch, further gated by the channel: a dev build would be offered every
        // release as an "update" daily and forever, so it never checks on a schedule — the
        // explicit menu command remains (`UpdateFeedPolicy.allowsScheduledChecks`).
        updater.automaticallyChecksForUpdates = UpdateFeedPolicy.allowsScheduledChecks(
            on: AppInfo.buildChannel,
            userChoice: enabled
        )
        ThreadingLogger.updates.debug(
            "Update scheduling configured channel=\(AppInfo.buildChannel.rawValue, privacy: .public) requested=\(enabled, privacy: .public) effective=\(self.updater.automaticallyChecksForUpdates, privacy: .public)"
        )

        // Downloading without checking is not a state this app offers: the switch means "do not
        // contact the release feed", and a download implies a check already happened.
        updater.automaticallyDownloadsUpdates = false
    }

    // MARK: - Actions

    /// The explicit "Check for Updates…" command.
    ///
    /// Deliberately works even when automatic checks are off. Switching the scheduled check off
    /// is a statement about background network traffic, not a refusal ever to look — and an app
    /// with no way to check on demand gives someone who turned it off no way back.
    func checkForUpdates() {
        guard started else { return }
        updater.checkForUpdates()
    }

    /// Whether the menu item should be selectable. Sparkle refuses re-entrant checks, and a
    /// menu item that silently does nothing reads as a broken build.
    var canCheckForUpdates: Bool {
        started && updater.canCheckForUpdates
    }
}

// MARK: - Feed routing

/// Routes each build channel to its feed. The stable URL stays in Info.plist (`SUFeedURL`);
/// this only overrides the channels that must not read it — today, nightly, whose date
/// versions would outrank every release in a shared feed (`UpdateFeedPolicy`).
///
/// A separate object rather than `AppUpdater` conforming, because the updater is constructed
/// in `AppUpdater.init` and a stored `let` cannot be built from `self` before it exists.
private final class FeedDelegate: NSObject, SPUUpdaterDelegate {

    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeedPolicy.feedOverride(for: AppInfo.buildChannel)
    }
}
