import Combine
import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileProjectDisclosureStoreTests: XCTestCase {
    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "MobileProjectDisclosureStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return (suiteName, defaults)
    }

    func testCollapseAndExpansionSurviveRecreationAndStayScopedToHostAndProject() {
        let (_, defaults) = makeDefaults()
        let store = MobileProjectDisclosureStore(defaults: defaults)
        let key = MobileProjectDisclosureStore.projectKey(id: "project-a", name: "Original")
        XCTAssertTrue(store.isExpanded(hostID: "mac-a", projectKey: key))
        XCTAssertTrue(store.setExpanded(false, hostID: "mac-a", projectKey: key))

        let reloaded = MobileProjectDisclosureStore(defaults: defaults)
        let renamed = MobileProjectDisclosureStore.projectKey(id: "project-a", name: "Renamed")
        XCTAssertFalse(reloaded.isExpanded(hostID: "mac-a", projectKey: renamed))
        XCTAssertTrue(reloaded.isExpanded(hostID: "mac-b", projectKey: key))
        XCTAssertTrue(reloaded.isExpanded(hostID: "mac-a", projectKey: "id:project-b"))
        XCTAssertTrue(reloaded.setExpanded(true, hostID: "mac-a", projectKey: key))
        XCTAssertTrue(MobileProjectDisclosureStore(defaults: defaults)
            .isExpanded(hostID: "mac-a", projectKey: key))
    }

    func testLegacyNamesAndHostProjectBoundariesCannotCollide() {
        let (_, defaults) = makeDefaults()
        let store = MobileProjectDisclosureStore(defaults: defaults)
        let legacy = MobileProjectDisclosureStore.projectKey(id: nil, name: "project")
        let identified = MobileProjectDisclosureStore.projectKey(id: "project", name: "project")
        XCTAssertTrue(store.setExpanded(false, hostID: "mac", projectKey: legacy))
        XCTAssertTrue(store.isExpanded(hostID: "mac", projectKey: identified))
        XCTAssertFalse(MobileProjectDisclosureStore(defaults: defaults)
            .isExpanded(hostID: "mac", projectKey: legacy))
        XCTAssertTrue(store.setExpanded(false, hostID: "a", projectKey: "bc"))
        XCTAssertTrue(store.isExpanded(hostID: "ab", projectKey: "c"))
    }

    func testMissingHostCannotWriteAndUnreadablePreferenceIsPreserved() throws {
        let (suiteName, defaults) = makeDefaults()
        let store = MobileProjectDisclosureStore(defaults: defaults)
        XCTAssertFalse(store.setExpanded(false, hostID: nil, projectKey: "project"))
        XCTAssertTrue(store.isExpanded(hostID: nil, projectKey: "project"))
        XCTAssertTrue(store.setExpanded(false, hostID: "mac", projectKey: "project"))
        let key = try XCTUnwrap(defaults.persistentDomain(forName: suiteName)?.keys.first)
        defaults.set("unreadable", forKey: key)
        XCTAssertTrue(store.isExpanded(hostID: "mac", projectKey: "project"))
        XCTAssertFalse(store.setExpanded(false, hostID: "mac", projectKey: "project"))
        XCTAssertEqual(defaults.string(forKey: key), "unreadable")
    }

    func testOnlyChangedSavedChoicesInvalidateTheDashboard() {
        let (_, defaults) = makeDefaults()
        let store = MobileProjectDisclosureStore(defaults: defaults)
        var updates = 0
        let observation = store.objectWillChange.sink { updates += 1 }
        XCTAssertTrue(store.setExpanded(false, hostID: "mac", projectKey: "project"))
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(store.setExpanded(false, hostID: "mac", projectKey: "project"))
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(store.setExpanded(true, hostID: "mac", projectKey: "project"))
        XCTAssertEqual(updates, 2)
        withExtendedLifetime(observation) {}
    }

    func testThousandProjectsKeepIndependentScalarChoices() {
        let (suiteName, defaults) = makeDefaults()
        let store = MobileProjectDisclosureStore(defaults: defaults)
        for index in 0..<1_000 {
            XCTAssertTrue(store.setExpanded(false, hostID: "mac", projectKey: "id:\(index)"))
        }
        let reloaded = MobileProjectDisclosureStore(defaults: defaults)
        XCTAssertTrue(reloaded.setExpanded(true, hostID: "mac", projectKey: "id:500"))
        for index in 0..<1_000 {
            XCTAssertEqual(reloaded.isExpanded(hostID: "mac", projectKey: "id:\(index)"), index == 500)
        }
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?.count, 1_000)
    }
}
