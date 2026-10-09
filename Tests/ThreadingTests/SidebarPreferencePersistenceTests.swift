import Foundation
import XCTest
@testable import Threading

@MainActor
final class SidebarPreferencePersistenceTests: XCTestCase {
    private static let keys = [
        "groupsSessionsByBranch", "groupsLoneBranches", "compactsSidebarTree",
        "sidebarSessionOrder", "sidebarSessionOrderIsReversed", "previewsSidebarChats",
        "nativeSidebarGroupByFact", "nativeSidebarSortByFact",
    ]

    func testArrangementSurvivesReopeningItsPreferenceDomain() throws {
        let suite = "SidebarPreferencePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        chooseArrangement(in: settings)
        XCTAssertTrue(defaults.synchronize())

        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reopened = AppSettings(defaults: reopenedDefaults)
        assertChosenArrangement(in: reopened)
        XCTAssertEqual(reopenedDefaults.string(forKey: "sidebarSessionOrder"), "name")

        // Re-selecting the same order must preserve its direction, including after reload.
        reopened.sidebarSessionOrder = .name
        XCTAssertTrue(reopened.sidebarSessionOrderIsReversed)
        reopened.sidebarSessionOrder = .manual
        XCTAssertFalse(reopened.sidebarSessionOrderIsReversed)

        reopened.nativeSidebarGroupByFact = nil
        reopened.nativeSidebarSortByFact = nil
        let cleared = AppSettings(defaults: reopenedDefaults)
        XCTAssertNil(cleared.nativeSidebarGroupByFact)
        XCTAssertNil(cleared.nativeSidebarSortByFact)
    }

    func testArrangementUsesTheInjectedUserChoiceStore() throws {
        let behaviorSuite = "SidebarPreferencePersistenceTests.behavior.\(UUID().uuidString)"
        let choiceSuite = "SidebarPreferencePersistenceTests.choice.\(UUID().uuidString)"
        let behavior = try XCTUnwrap(UserDefaults(suiteName: behaviorSuite))
        let choices = try XCTUnwrap(UserDefaults(suiteName: choiceSuite))
        defer {
            behavior.removePersistentDomain(forName: behaviorSuite)
            choices.removePersistentDomain(forName: choiceSuite)
        }
        let settings = AppSettings(defaults: behavior, userChoiceDefaults: choices)
        let originalBehavior = behavior.persistentDomain(forName: behaviorSuite) as NSDictionary?

        chooseArrangement(in: settings)

        assertChosenArrangement(in: settings)
        assertChosenArrangement(in: AppSettings(defaults: behavior, userChoiceDefaults: choices))
        XCTAssertEqual(behavior.persistentDomain(forName: behaviorSuite) as NSDictionary?, originalBehavior)
        XCTAssertEqual(Set(choices.persistentDomain(forName: choiceSuite)?.keys.map { $0 } ?? []),
                       Set(Self.keys))
    }

    func testHostedArrangementChoicesLeaveTheUsersDefaultsUntouched() {
        XCTAssertTrue(PreferenceStore.isRedirected)
        let choices = PreferenceStore.shared
        let previous = Self.keys.map { ($0, choices.object(forKey: $0)) }
        defer {
            for (key, value) in previous { choices.set(value, forKey: key) }
        }
        let standard = snapshot(UserDefaults.standard)

        chooseArrangement(in: AppSettings.shared)

        assertChosenArrangement(in: AppSettings.shared)
        let restored = NativeSidebarPipelineOptions.current
        XCTAssertEqual(restored.sessionOrder, .name)
        XCTAssertTrue(restored.sessionOrderReversed)
        XCTAssertFalse(restored.branchGrouping)
        XCTAssertFalse(restored.loneBranchHeadings)
        XCTAssertTrue(restored.compactTree)
        XCTAssertFalse(restored.chatPreview)
        XCTAssertEqual(restored.groupByFact?.id, "probe.group")
        XCTAssertEqual(restored.sortByFact?.id, "probe.sort")
        XCTAssertEqual(snapshot(UserDefaults.standard), standard,
                       "sidebar tests changed the arrangement restored by the user's app")
    }

    private func chooseArrangement(in settings: AppSettings) {
        settings.groupsSessionsByBranch = false
        settings.groupsLoneBranches = false
        settings.compactsSidebarTree = true
        settings.sidebarSessionOrder = .name
        settings.sidebarSessionOrderIsReversed = true
        settings.previewsSidebarChats = false
        settings.nativeSidebarGroupByFact = "probe.group@1"
        settings.nativeSidebarSortByFact = "probe.sort@1"
    }

    private func assertChosenArrangement(
        in settings: AppSettings,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(settings.groupsSessionsByBranch, file: file, line: line)
        XCTAssertFalse(settings.groupsLoneBranches, file: file, line: line)
        XCTAssertTrue(settings.compactsSidebarTree, file: file, line: line)
        XCTAssertEqual(settings.sidebarSessionOrder, .name, file: file, line: line)
        XCTAssertTrue(settings.sidebarSessionOrderIsReversed, file: file, line: line)
        XCTAssertFalse(settings.previewsSidebarChats, file: file, line: line)
        XCTAssertEqual(settings.nativeSidebarGroupByFact, "probe.group@1", file: file, line: line)
        XCTAssertEqual(settings.nativeSidebarSortByFact, "probe.sort@1", file: file, line: line)
    }

    private func snapshot(_ defaults: UserDefaults) -> NSDictionary {
        NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        }))
    }
}
