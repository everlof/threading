import Foundation
import XCTest
@testable import Threading

/// Hosts as records: configured once, named by every project that runs on them, and edited in one
/// place. What a project keeps is a copy, so the interesting assertions are about the copy staying
/// true — and about a project never being left pointed at a machine this app no longer knows.
@MainActor
final class RemoteHostStoreTests: HostedStoreTestCase {

    private nonisolated(unsafe) var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/threading-hosts-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() -> RemoteHostStore {
        RemoteHostStore(directory: directory)
    }

    // MARK: - The list

    func testAHostIsAddedOnceAndSurvivesReopening() throws {
        let store = makeStore()
        let host = RemoteHostRecord.typed(label: "Pi", destination: "pi", sshConfigFile: "")
        XCTAssertEqual(store.add(host), .applied)
        XCTAssertEqual(store.ordered.map(\.displayName), ["Pi"])

        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "Again", destination: "pi", sshConfigFile: "")),
                       .duplicate(host.id), "one machine is one record")

        let reopened = makeStore()
        XCTAssertEqual(reopened.host(withID: host.id)?.destination, "pi")
        XCTAssertEqual(reopened.host(naming: "pi", sshConfigFile: nil)?.id, host.id)
    }

    /// The same validation the editor shows, so a host `ssh` would misread cannot be saved and then
    /// refused at every launch.
    func testAHostSSHWouldMisreadIsRefusedWithItsReason() {
        let store = makeStore()
        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "", destination: "-oProxyCommand=x", sshConfigFile: "")),
                       .refused(.unsafeDestination))
        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "", destination: "", sshConfigFile: "")),
                       .refused(.missingDestination))
        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "", destination: "pi", sshConfigFile: "relative/config")),
                       .refused(.relativeConfigFile))
        XCTAssertTrue(store.hosts.isEmpty)
    }

    /// A blank label is not a blank row: the machine's own name stands in for it.
    func testAHostWithoutALabelShowsItsDestination() {
        let host = RemoteHostRecord.typed(label: "  ", destination: "me@build.example", sshConfigFile: "")
        XCTAssertEqual(host.displayName, "me@build.example")
        XCTAssertEqual(RemoteHostRecord.typed(label: " Build box ", destination: "b", sshConfigFile: "").displayName,
                       "Build box")
    }

    // MARK: - What a project keeps

    /// Editing the machine reaches every project on it, and removing it clears them rather than
    /// leaving a project pointed at a host nothing knows.
    func testProjectsFollowTheRecordTheyName() throws {
        let store = makeStore()
        let record = RemoteHostRecord.typed(label: "Pi", destination: "pi", sshConfigFile: "")
        XCTAssertEqual(store.add(record), .applied)

        let projects = ProjectStore.shared
        let project = try XCTUnwrap(projects.addProject(folderURL: scratchFolder()))
        XCTAssertEqual(
            projects.setExecutionHost(.on(record, remoteDirectory: "/home/me/app"), forProjectID: project.id),
            .applied
        )
        XCTAssertEqual(projects.projects(onHost: record.id).map(\.id), [project.id])

        var renamed = record
        renamed.destination = "pi.local"
        XCTAssertEqual(store.update(renamed), .applied)
        XCTAssertEqual(projects.refreshExecutionHosts(from: store), 1)
        XCTAssertEqual(projects.project(withID: project.id)?.executionHost?.destination, "pi.local")
        XCTAssertEqual(projects.project(withID: project.id)?.executionHost?.remoteDirectory, "/home/me/app",
                       "the folder is the project's own and does not move with the machine")

        XCTAssertEqual(store.remove(record.id), .applied)
        XCTAssertEqual(projects.refreshExecutionHosts(from: store), 1)
        XCTAssertNil(projects.project(withID: project.id)?.executionHost,
                     "a project kept a host the app no longer knows")
    }

    /// A project set up before hosts were records keeps working: its machine joins the list, once,
    /// and the project ends up naming that record.
    func testAProjectFromBeforeTheListIsAdoptedIntoIt() throws {
        let store = makeStore()
        let projects = ProjectStore.shared
        let first = try XCTUnwrap(projects.addProject(folderURL: scratchFolder()))
        let second = try XCTUnwrap(projects.addProject(folderURL: scratchFolder()))
        // The old shape: a destination on the project and no record anywhere.
        let legacy = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/app")
        XCTAssertEqual(projects.setExecutionHost(legacy, forProjectID: first.id), .applied)
        XCTAssertEqual(projects.setExecutionHost(legacy, forProjectID: second.id), .applied)
        XCTAssertNil(projects.project(withID: first.id)?.executionHost?.hostID)

        XCTAssertEqual(projects.refreshExecutionHosts(from: store), 2)
        XCTAssertEqual(store.hosts.count, 1, "two projects on one machine adopted it twice")
        let adopted = try XCTUnwrap(store.hosts.first)
        XCTAssertEqual(adopted.destination, "pi")
        XCTAssertEqual(projects.project(withID: first.id)?.executionHost?.hostID, adopted.id)
        XCTAssertEqual(projects.project(withID: second.id)?.executionHost?.hostID, adopted.id)

        XCTAssertEqual(projects.refreshExecutionHosts(from: store), 0, "a second pass changes nothing")
    }

    // MARK: - Helpers

    private func scratchFolder() throws -> URL {
        let url = directory.appendingPathComponent("project-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
