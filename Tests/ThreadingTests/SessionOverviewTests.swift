import AppKit
import XCTest
@testable import Threading

@MainActor
final class SessionOverviewTests: XCTestCase {

    private struct Fixture {
        let controller: SessionOverviewViewController
        let activityBuilds: () -> Int
        let infoBuilds: () -> Int
        let remove: () -> Void
    }

    private func makeFixture(
        initialSection: SessionOverviewSection = .info
    ) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-overview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var activityBuildCount = 0
        var infoBuildCount = 0
        let controller = SessionOverviewViewController(
            sessionID: SessionID(),
            initialSection: initialSection,
            activityFactory: {
                activityBuildCount += 1
                return FileTreeViewController(folderPath: folder.path)
            },
            infoFactory: {
                infoBuildCount += 1
                let info = SessionInfoViewController(
                    sessionID: SessionID(),
                    folderPath: folder.path
                )
                info.readSource = { completion in
                    completion(.empty)
                }
                return info
            }
        )
        return Fixture(
            controller: controller,
            activityBuilds: { activityBuildCount },
            infoBuilds: { infoBuildCount },
            remove: { try? FileManager.default.removeItem(at: folder) }
        )
    }

    func testOnlyTheInitiallySelectedSectionIsBuilt() throws {
        let activity = try makeFixture(initialSection: .activity)
        defer { activity.remove() }
        _ = activity.controller.view
        XCTAssertEqual(activity.activityBuilds(), 1)
        XCTAssertEqual(activity.infoBuilds(), 0)

        let info = try makeFixture(initialSection: .info)
        defer { info.remove() }
        _ = info.controller.view
        XCTAssertEqual(info.activityBuilds(), 0)
        XCTAssertEqual(info.infoBuilds(), 1)
    }

    /// Info leads the run: it is the default, and the reason the panel is opened. Activity,
    /// the account of where the work landed, follows it.
    func testInfoIsTheDefaultLeadingSection() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        XCTAssertEqual(SessionOverviewSection.allCases, [.info, .activity])
        XCTAssertEqual(fixture.controller.selectedSection, .info)
        _ = fixture.controller.view
        XCTAssertEqual(fixture.activityBuilds(), 0)
        XCTAssertEqual(fixture.infoBuilds(), 1)
    }

    func testSwitchingSectionsDetachesTheOldViewAndReusesItsController() throws {
        let fixture = try makeFixture(initialSection: .activity)
        defer { fixture.remove() }
        let controller = fixture.controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        let activity = try XCTUnwrap(controller.activityControllerIfLoaded)
        XCTAssertNotNil(activity.view.superview)
        XCTAssertNil(controller.infoControllerIfLoaded)

        let info = controller.selectInfo()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertNil(activity.view.superview)
        XCTAssertNotNil(info.view.superview)

        XCTAssertTrue(controller.selectActivity() === activity)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertNil(info.view.superview)
        XCTAssertNotNil(activity.view.superview)
        XCTAssertEqual(fixture.activityBuilds(), 1)
        XCTAssertEqual(fixture.infoBuilds(), 1)
    }

    func testTheSectionChoiceIsAccessibleAndReportsPersistenceChanges() throws {
        let fixture = try makeFixture(initialSection: .activity)
        defer { fixture.remove() }
        let controller = fixture.controller
        _ = controller.view
        var reported: [SessionOverviewSection] = []
        controller.onSectionChange = { reported.append($0) }

        controller.select(.info)
        controller.select(.info)
        controller.select(.activity)

        XCTAssertEqual(reported, [.info, .activity])
        XCTAssertNotNil(descendant(
            in: controller.view,
            accessibilityIdentifier: "session-overview.section.activity"
        ))
        XCTAssertNotNil(descendant(
            in: controller.view,
            accessibilityIdentifier: "session-overview.section.info"
        ))
    }

    private func descendant(in view: NSView, accessibilityIdentifier: String) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier { return view }
        return view.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityIdentifier: accessibilityIdentifier)
        }.first
    }
}
