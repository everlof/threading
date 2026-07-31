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
        let hasProjects = !ProjectStore.shared.projects.isEmpty

        // Grandfathering is a one-time *recording*, not a standing veto: a store with projects
        // and no record at all belongs to someone who predates the walkthrough, so the first
        // read writes the record for them. From then on the record alone decides — which is
        // what lets Advanced's "Clear Flag" bring the walkthrough back over an existing store:
        // clearing writes an explicit zero, a record saying "run again", where a *missing* key
        // would be indistinguishable from the upgrade case and be silently re-grandfathered.
        if !hasRecord, hasProjects {
            markCompleted()
            return false
        }
        return needsOnboarding(
            completedVersion: completedVersion,
            hasRecord: hasRecord,
            hasProjects: hasProjects
        )
    }

    /// The pure rule, testable without a store: with a record the version decides; without
    /// one, only a store with no projects is a first launch (the other case grandfathers).
    static func needsOnboarding(completedVersion: Int, hasRecord: Bool, hasProjects: Bool) -> Bool {
        hasRecord ? completedVersion < currentVersion : !hasProjects
    }

    static var hasRecord: Bool {
        PreferenceStore.shared.object(forKey: Keys.completedVersion) != nil
    }

    static var completedVersion: Int {
        PreferenceStore.shared.integer(forKey: Keys.completedVersion)
    }

    static var isRecorded: Bool { completedVersion >= currentVersion }

    static func markCompleted() {
        PreferenceStore.shared.set(currentVersion, forKey: Keys.completedVersion)
    }

    /// Forgets the completion, so the next launch opens with the walkthrough — the true
    /// first-launch path, deferred main window and all. Advanced's row calls this.
    static func clear() {
        PreferenceStore.shared.set(0, forKey: Keys.completedVersion)
    }
}
