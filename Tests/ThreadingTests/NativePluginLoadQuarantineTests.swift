import XCTest
@testable import Threading

final class NativePluginLoadQuarantineTests: XCTestCase {
    private let plugin = NativePluginLoadQuarantine.Identity(
        identifier: "codes.threading.plugin.t3navigator",
        codeKey: "build-a"
    )

    func testUnfinishedLoadOnUncleanLaunchBlocksOnlyThatBuild() {
        let read = history(
            launches: [launch("one", ending: .unclean)],
            records: [checkpoint(.nativePluginLoadStarted, launch: "one")]
        )
        let blocked = NativePluginLoadQuarantine.blockedBuilds(in: read)
        XCTAssertEqual(blocked, [plugin])
        XCTAssertFalse(blocked.contains(.init(
            identifier: plugin.identifier, codeKey: "build-b"
        )))
    }

    func testCompletedLoadOrCleanExitDoesNotQuarantine() {
        let completed = history(
            launches: [launch("one", ending: .unclean)],
            records: [
                checkpoint(.nativePluginLoadStarted, launch: "one"),
                checkpoint(.nativePluginLoadFinished, launch: "one")
            ]
        )
        XCTAssertTrue(NativePluginLoadQuarantine.blockedBuilds(in: completed).isEmpty)

        let clean = history(
            launches: [launch("one", ending: .clean)],
            records: [checkpoint(.nativePluginLoadStarted, launch: "one")]
        )
        XCTAssertTrue(NativePluginLoadQuarantine.blockedBuilds(in: clean).isEmpty)
    }

    func testSuccessfulExplicitRetryClearsEarlierCrash() {
        let read = history(
            launches: [launch("one", ending: .unclean), launch("two", ending: .clean)],
            records: [
                checkpoint(.nativePluginLoadStarted, launch: "one"),
                checkpoint(.nativePluginLoadStarted, launch: "two"),
                checkpoint(.nativePluginLoadFinished, launch: "two")
            ]
        )
        XCTAssertTrue(NativePluginLoadQuarantine.blockedBuilds(in: read).isEmpty)
    }

    private func history(
        launches: [LaunchLedgerLaunch],
        records: [LaunchLedgerRecord]
    ) -> LaunchLedgerRead {
        var value = LaunchLedgerHistory()
        value.launches = launches
        value.records = records
        return .valid(value)
    }

    private func launch(_ id: String, ending: LaunchDisposition) -> LaunchLedgerLaunch {
        var value = LaunchLedgerLaunch(
            id: id,
            startedAt: Date(),
            uptime: 0,
            bootID: "boot",
            fingerprint: "host-a",
            mode: .normal
        )
        value.ending = LaunchEnding(disposition: ending, systemInitiated: false)
        return value
    }

    private func checkpoint(
        _ kind: StartupCheckpoint,
        launch: String
    ) -> LaunchLedgerRecord {
        LaunchLedgerRecord(
            version: 1,
            kind: .checkpoint,
            launch: launch,
            at: "",
            uptime: 0,
            boot: "boot",
            build: nil,
            fingerprint: nil,
            mode: nil,
            writer: nil,
            pid: nil,
            checkpoint: kind.rawValue,
            detail: plugin.ledgerDetail,
            disposition: nil,
            systemInitiated: nil
        )
    }
}
