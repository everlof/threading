import Foundation

/// Whether the first-launch walkthrough still needs to run, and the record that it has.
///
/// Stored in `PreferenceStore` rather than `UserDefaults.standard` for the same reason the
/// app theme is (`AppThemeLibrary.Keys`): hosted tests build onboarding controllers and mark
/// them completed, and under `PreferenceStore` those writes land in the scratch suite instead
/// of deciding what the developer's own next launch shows.
///
/// Versioned as an integer so a future release can raise `currentVersion` and re-run a
/// "what's new" pass; completion records the version it completed.
@MainActor
enum OnboardingState {

    enum Keys {
        static let completedVersion = "onboardingCompletedVersion"
    }

    static let currentVersion = 1

    static var needsOnboarding: Bool {
        needsOnboarding(
            completedVersion: PreferenceStore.shared.integer(forKey: Keys.completedVersion),
            hasProjects: !ProjectStore.shared.projects.isEmpty
        )
    }

    /// The pure rule. `hasProjects` grandfathers an existing user: a store that already holds
    /// projects belongs to someone who needs no welcome, whatever the flag says — the flag did
    /// not exist when they started.
    static func needsOnboarding(completedVersion: Int, hasProjects: Bool) -> Bool {
        completedVersion < currentVersion && !hasProjects
    }

    static func markCompleted() {
        PreferenceStore.shared.set(currentVersion, forKey: Keys.completedVersion)
    }
}
