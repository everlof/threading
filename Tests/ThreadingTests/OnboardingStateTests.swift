import Foundation
import XCTest
@testable import Threading

/// The first-launch rule, where its record lives, and the difference between "never recorded"
/// and "deliberately cleared".
@MainActor
final class OnboardingStateTests: XCTestCase {

    override func tearDown() {
        PreferenceStore.shared.removeObject(forKey: OnboardingState.Keys.completedVersion)
        super.tearDown()
    }

    func testTheRule() {
        // A fresh install: no record, nothing in the store.
        XCTAssertTrue(OnboardingState.needsOnboarding(
            completedVersion: 0, hasRecord: false, hasProjects: false
        ))

        // An existing user upgrading: no record but a store full of projects — grandfathered
        // (the stored property records completion for them; the rule itself just answers no).
        XCTAssertFalse(OnboardingState.needsOnboarding(
            completedVersion: 0, hasRecord: false, hasProjects: true
        ))

        // Completed at the current version: done, projects or not.
        XCTAssertFalse(OnboardingState.needsOnboarding(
            completedVersion: OnboardingState.currentVersion, hasRecord: true, hasProjects: false
        ))
        XCTAssertFalse(OnboardingState.needsOnboarding(
            completedVersion: OnboardingState.currentVersion, hasRecord: true, hasProjects: true
        ))

        // An explicit zero record is "run again" — with a record, projects no longer veto.
        // This is the Clear Flag case, and the reason clearing writes rather than removes.
        XCTAssertTrue(OnboardingState.needsOnboarding(
            completedVersion: 0, hasRecord: true, hasProjects: true
        ))

        // A future what's-new bump re-runs for completers of older versions.
        XCTAssertTrue(OnboardingState.needsOnboarding(
            completedVersion: OnboardingState.currentVersion - 1,
            hasRecord: true,
            hasProjects: false
        ))
    }

    func testCompletionIsRecordedInTheRedirectedStore() {
        XCTAssertTrue(
            PreferenceStore.isRedirected,
            "Hosted tests must write the scratch suite, not the developer's own defaults"
        )

        XCTAssertFalse(OnboardingState.hasRecord)
        OnboardingState.markCompleted()
        XCTAssertTrue(OnboardingState.hasRecord)
        XCTAssertTrue(OnboardingState.isRecorded)
        XCTAssertEqual(OnboardingState.completedVersion, OnboardingState.currentVersion)
    }

    func testClearingLeavesARecordThatSaysRunAgain() {
        OnboardingState.markCompleted()
        OnboardingState.clear()

        XCTAssertTrue(
            OnboardingState.hasRecord,
            "A cleared flag must stay distinguishable from a never-set one, or the "
                + "grandfathering migration re-records it and the walkthrough never returns"
        )
        XCTAssertFalse(OnboardingState.isRecorded)
        XCTAssertEqual(OnboardingState.completedVersion, 0)
        XCTAssertTrue(OnboardingState.needsOnboarding(
            completedVersion: OnboardingState.completedVersion,
            hasRecord: OnboardingState.hasRecord,
            hasProjects: true
        ))
    }
}
