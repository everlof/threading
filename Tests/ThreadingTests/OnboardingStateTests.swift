import Foundation
import XCTest
@testable import Threading

/// The first-launch rule and where its record lives.
@MainActor
final class OnboardingStateTests: XCTestCase {

    override func tearDown() {
        PreferenceStore.shared.removeObject(forKey: OnboardingState.Keys.completedVersion)
        super.tearDown()
    }

    func testTheRule() {
        // A fresh install: nothing recorded, nothing in the store.
        XCTAssertTrue(OnboardingState.needsOnboarding(completedVersion: 0, hasProjects: false))

        // Completed at the current version: done.
        XCTAssertFalse(OnboardingState.needsOnboarding(
            completedVersion: OnboardingState.currentVersion,
            hasProjects: false
        ))

        // An existing user upgrading: the store already holds projects, and whoever built it
        // needs no welcome, whatever the flag says.
        XCTAssertFalse(OnboardingState.needsOnboarding(completedVersion: 0, hasProjects: true))

        // A future what's-new bump re-runs for completers of older versions.
        XCTAssertTrue(OnboardingState.needsOnboarding(
            completedVersion: OnboardingState.currentVersion - 1,
            hasProjects: false
        ))
    }

    func testCompletionIsRecordedInTheRedirectedStore() {
        XCTAssertTrue(
            PreferenceStore.isRedirected,
            "Hosted tests must write the scratch suite, not the developer's own defaults"
        )

        OnboardingState.markCompleted()
        XCTAssertEqual(
            PreferenceStore.shared.integer(forKey: OnboardingState.Keys.completedVersion),
            OnboardingState.currentVersion
        )
    }
}
