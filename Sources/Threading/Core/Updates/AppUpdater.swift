import Foundation
import Sparkle

/// Threading's one door to Sparkle.
///
/// Sparkle is contained here rather than reached for at call sites, for the same reason the
/// invisible `NSColorWell` lives inside `ThemeSwatchView`: it brings its own windows, and this
/// app's design system exists to keep third-party chrome out of the interface. Nothing outside
/// this file imports Sparkle, so replacing `SPUStandardUpdaterController` with a custom
/// `SPUUserDriver` later changes this type and nothing else — see
/// `docs/architecture/releasing.md` for why that swap is planned rather than done.
///
/// The user's switch is the authority. `SUEnableAutomaticChecks` in Info.plist is only the
/// shipped default; `AppSettings.automaticUpdateChecksEnabled` is what Settings ▸ General
/// writes, and it is pushed into the updater on every settings change so the two can never
/// disagree about whether Threading is allowed to talk to its release feed.
@MainActor
final class AppUpdater {

    static let shared = AppUpdater()

    /// `startingUpdater: true` is safe here because the updater's *own* scheduled check is
    /// governed by `automaticallyChecksForUpdates`, which `apply` sets from the user's choice
    /// before any check can fire.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private let appEvents = AppEventObservations()

    private init() {
        apply(AppSettings.shared.automaticUpdateChecksEnabled)
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.apply(AppSettings.shared.automaticUpdateChecksEnabled)
        }
    }

    // MARK: - State

    /// Whether Threading is currently allowed to ask its release feed anything.
    var automaticChecksEnabled: Bool {
        controller.updater.automaticallyChecksForUpdates
    }

    private func apply(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled

        // Downloading without checking is not a state this app offers: the switch means "do not
        // contact the release feed", and a download implies a check already happened.
        controller.updater.automaticallyDownloadsUpdates = false
    }

    // MARK: - Actions

    /// The explicit "Check for Updates…" command.
    ///
    /// Deliberately works even when automatic checks are off. Switching the scheduled check off
    /// is a statement about background network traffic, not a refusal ever to look — and an app
    /// with no way to check on demand gives someone who turned it off no way back.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether the menu item should be selectable. Sparkle refuses re-entrant checks, and a
    /// menu item that silently does nothing reads as a broken build.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
