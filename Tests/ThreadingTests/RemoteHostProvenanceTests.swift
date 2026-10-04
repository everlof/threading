import XCTest
import ThreadingPTYClient
import ThreadingPTYHostKit

@testable import Threading

/// A host can have two installers — this Mac's Remote Hosts setup and another (Rindabox's
/// Ansible) — and this Mac must never retire, disable at boot or prune a generation it did not
/// install. These tests run the shipping shell scripts in a real `sh` against a scratch home, and
/// the shipping clients against a fake daemon that speaks an older protocol.
final class RemoteHostProvenanceTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHostProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Lays out one install directory with an executable and, optionally, a marker.
    private func install(_ identifier: String, bridge: Bool = false, marker: String?) throws {
        let root = bridge ? RemoteHostDefaults.remoteBridgeLibraryDirectory : RemoteHostDefaults.remoteLibraryDirectory
        let name = bridge ? RemoteHostDefaults.bridgeExecutableName : RemoteHostDefaults.daemonExecutableName
        let directory = home.appendingPathComponent(root).appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        if let marker {
            try Data((marker + "\n").utf8).write(
                to: directory.appendingPathComponent(RemoteHostDefaults.provenanceMarkerFileName)
            )
        }
    }

    private func exists(_ identifier: String, bridge: Bool = false) -> Bool {
        let root = bridge ? RemoteHostDefaults.remoteBridgeLibraryDirectory : RemoteHostDefaults.remoteLibraryDirectory
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(root).appendingPathComponent(identifier).path)
    }

    /// Runs `script` through `sh -s` with `HOME` at the scratch home, in that directory — exactly
    /// how `ssh host sh -s` runs it on a host.
    @discardableResult
    private func runShell(_ script: String, stdin: Data? = nil, command: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = command.map { ["-c", $0] } ?? ["-s"]
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(command == nil ? Data(script.utf8) : (stdin ?? Data()))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func binary(_ digestPrefix: String) -> RemoteHostBinary {
        RemoteHostBinary(
            url: URL(fileURLWithPath: "/tmp/threading-ptyd"),
            architecture: .arm64,
            sha256: digestPrefix + String(repeating: "0", count: 64 - digestPrefix.count)
        )
    }

    // MARK: - Markers

    func testAMarkerReadsAsThisMacAnotherInstallerOrNobody() {
        XCTAssertEqual(RemoteHostProvenance(marker: "threading-mac\n"), .threadingMac)
        XCTAssertEqual(RemoteHostProvenance(marker: "external:rindabox-ansible"), .external("rindabox-ansible"))
        XCTAssertEqual(RemoteHostProvenance(marker: ""), .unmarked)
        XCTAssertEqual(RemoteHostProvenance(marker: "external:"), .unmarked)
        XCTAssertEqual(RemoteHostProvenance(marker: "external:has space"), .unmarked)
        XCTAssertEqual(RemoteHostProvenance(marker: "somebody"), .unmarked)
    }

    /// The real probe, in a real shell: each install directory's marker is reported beside it.
    func testTheProbeReportsEachInstallDirectorysInstaller() throws {
        try install("aaaaaaaaaaaaaaaa", marker: "threading-mac")
        try install("bbbbbbbbbbbbbbbb", marker: "external:rindabox-ansible")
        try install("cccccccccccccccc", marker: nil)
        try install("dddddddddddddddd", bridge: true, marker: "threading-mac")
        let result = try runShell(RemoteHostFacts.probeScript)
        let facts = try RemoteHostFacts.parse(result.output)
        XCTAssertEqual(facts.installedBinaries, ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "cccccccccccccccc"])
        XCTAssertEqual(facts.provenance(ofDaemon: "aaaaaaaaaaaaaaaa"), .threadingMac)
        XCTAssertEqual(facts.provenance(ofDaemon: "bbbbbbbbbbbbbbbb"), .external("rindabox-ansible"))
        XCTAssertEqual(facts.provenance(ofDaemon: "cccccccccccccccc"), .unmarked)
        XCTAssertEqual(facts.provenance(ofDaemon: "never-installed"), .unmarked)
        XCTAssertEqual(facts.bridgeProvenance["dddddddddddddddd"], .threadingMac)
    }

    // MARK: - Plan

    func testOnlyThisMacsGenerationsAreDisabledAtBootAndExternalOnesAreNamed() throws {
        let probe = """
            machine=x86_64
            home=/home/agent
            user=agent
            shell=/bin/bash
            systemctl=/usr/bin/systemctl
            linger=yes
            installed=1111111111111111
            installed=2222222222222222
            installed=3333333333333333
            active=threading-ptyd@2222222222222222.service
            enabled=threading-ptyd@1111111111111111.service
            enabled=threading-ptyd@2222222222222222.service
            enabled=threading-ptyd@3333333333333333.service
            managed=1111111111111111 threading-mac
            managed=2222222222222222 external:rindabox-ansible
            """
        let facts = try RemoteHostFacts.parse(probe)
        let plan = RemoteHostInstallPlan.make(facts: facts, binary: binary("ffffffffffffffff"))
        XCTAssertEqual(plan.otherEnabledInstances, ["1111111111111111"],
                       "another installer's and an unmarked generation's boot policy are not this Mac's")
        XCTAssertEqual(plan.externalActiveInstances, ["2222222222222222": .external("rindabox-ansible")])
        XCTAssertEqual(plan.externalManagerName, "rindabox-ansible")
    }

    // MARK: - Rendezvous decisions

    func testAnExternallyManagedDaemonIsUsedWhenCompatibleAndNeverRetired() throws {
        let external = RemoteHostInstallPlan(
            uploadsBinary: false, enablesLinger: false, otherActiveInstances: ["2222222222222222"],
            externalActiveInstances: ["2222222222222222": .external("rindabox-ansible")],
            isRunning: false, otherEnabledInstances: []
        )
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .ready, plan: external), .useExternal)
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .mismatched(.peerTooOld), plan: external),
                       .refuseExternal(manager: "rindabox-ansible"),
                       "an older external daemon is reported as theirs to upgrade, never retired")
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .notRunning, plan: external), .startOwn)

        // A daemon answering while no instance this Mac knows is active was started by
        // something else entirely.
        let unknownHolder = RemoteHostInstallPlan(
            uploadsBinary: false, enablesLinger: false, otherActiveInstances: [],
            isRunning: false, otherEnabledInstances: []
        )
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .mismatched(.peerTooOld), plan: unknownHolder),
                       .refuseExternal(manager: nil))

        // Another installer's unit template: nothing of this Mac's may start through it.
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .notRunning, plan: unknownHolder, foreignUnit: true),
                       .refuseExternal(manager: nil))
    }

    func testThisMacsOwnGenerationsKeepTheUpgradePath() {
        let own = RemoteHostInstallPlan(
            uploadsBinary: false, enablesLinger: false, otherActiveInstances: ["1111111111111111"],
            isRunning: false, otherEnabledInstances: ["1111111111111111"]
        )
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .ready, plan: own), .upgradeOwnGenerations)
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .mismatched(.peerTooOld), plan: own), .retireOwnTooOld)
        XCTAssertEqual(RemoteHostRendezvousAction.decide(probe: .mismatched(.selfTooOld), plan: own),
                       .refuseIncompatible(.selfTooOld))
    }

    @MainActor
    func testTheExternalFailureNamesWhereToUpgrade() {
        let named = RemoteHostFailure.managedExternally(manager: "rindabox-ansible")
        XCTAssertEqual(named.token, RemoteHostFailure.managedExternallyToken)
        XCTAssertTrue(named.detail.contains("rindabox-ansible"))
        XCTAssertEqual(RemoteHostPresentation.guidance(for: named), named.detail)
    }

    // MARK: - Scripts in a real shell

    /// The prune once removed every hex directory but the kept ones — another installer's
    /// running generation included. Now only directories still marked as this Mac's go.
    func testThePruneRemovesOnlyThisMacsUnusedGenerations() throws {
        try install("1111111111111111", marker: "threading-mac")           // ours, unused → pruned
        try install("2222222222222222", marker: "external:rindabox-ansible") // theirs → kept
        try install("3333333333333333", marker: nil)                       // unknown → kept
        try install("4444444444444444", marker: "threading-mac")           // ours, kept by name
        try install("5555555555555555", bridge: true, marker: "threading-mac")
        try install("6666666666666666", bridge: true, marker: "external:rindabox-ansible")

        let result = try runShell(RemoteHostInstallScripts.pruneScript(keeping: ["4444444444444444"]))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(exists("1111111111111111"))
        XCTAssertTrue(exists("2222222222222222"), "another installer's generation is never pruned")
        XCTAssertTrue(exists("3333333333333333"), "an unmarked generation counts as external")
        XCTAssertTrue(exists("4444444444444444"))
        XCTAssertFalse(exists("5555555555555555", bridge: true))
        XCTAssertTrue(exists("6666666666666666", bridge: true))
    }

    func testAnUploadMarksANewDirectoryAsThisMacsButNeverClaimsAnotherInstallers() throws {
        let payload = home.appendingPathComponent("payload")
        try Data("binary".utf8).write(to: payload)
        let fresh = binary("aaaaaaaaaaaaaaaa")
        try runShell("", stdin: try Data(contentsOf: payload),
                     command: RemoteHostInstallScripts.uploadCommand(for: fresh))
        let freshMarker = home.appendingPathComponent(RemoteHostDefaults.remoteLibraryDirectory)
            .appendingPathComponent("aaaaaaaaaaaaaaaa").appendingPathComponent(RemoteHostDefaults.provenanceMarkerFileName)
        XCTAssertEqual(try String(contentsOf: freshMarker, encoding: .utf8), "threading-mac\n")

        // A directory another installer created, missing its binary: filled in, still theirs.
        let theirs = home.appendingPathComponent(RemoteHostDefaults.remoteLibraryDirectory)
            .appendingPathComponent("bbbbbbbbbbbbbbbb")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("external:rindabox-ansible\n".utf8)
            .write(to: theirs.appendingPathComponent(RemoteHostDefaults.provenanceMarkerFileName))
        try runShell("", stdin: try Data(contentsOf: payload),
                     command: RemoteHostInstallScripts.uploadCommand(for: binary("bbbbbbbbbbbbbbbb")))
        XCTAssertEqual(
            try String(contentsOf: theirs.appendingPathComponent(RemoteHostDefaults.provenanceMarkerFileName), encoding: .utf8),
            "external:rindabox-ansible\n"
        )
    }

    func testAnotherInstallersUnitTemplateIsNeverOverwritten() throws {
        let unitDirectory = home.appendingPathComponent(RemoteHostDefaults.remoteUnitDirectory)
        try FileManager.default.createDirectory(at: unitDirectory, withIntermediateDirectories: true)
        let unit = unitDirectory.appendingPathComponent(RemoteHostDefaults.remoteUnitTemplateName)

        // No template: ours to write.
        XCTAssertEqual(try runShell(RemoteHostInstallScripts.unitOwnershipScript).status, 0)

        // Our own template (carries the line): ours.
        try Data(RemoteHostInstallScripts.unitTemplate.utf8).write(to: unit)
        XCTAssertEqual(try runShell(RemoteHostInstallScripts.unitOwnershipScript).status, 0)

        // A legacy template with no line, and nothing on the host naming another installer:
        // an older build of this app wrote it.
        try Data("[Service]\nExecStart=/old\n".utf8).write(to: unit)
        XCTAssertEqual(try runShell(RemoteHostInstallScripts.unitOwnershipScript).status, 0)

        // The same template on a host where another installer marked its generation: theirs.
        try install("2222222222222222", marker: "external:rindabox-ansible")
        XCTAssertEqual(try runShell(RemoteHostInstallScripts.unitOwnershipScript).status,
                       RemoteHostInstallScripts.foreignUnitExitStatus)
    }

    // MARK: - Clients never retire a remote daemon

    /// Asking a remote daemon what it holds once sent `retire` to any older daemon — another
    /// installer's included — because the admin client kept the app's retire-on-upgrade default.
    func testTheRemoteAdminSurveyNeverRetiresAnOlderDaemon() throws {
        let daemon = try FakePTYHostDaemon { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload),
                  case .hello = control else { return }
            daemon.send(.hello(PTYHostHello(protocolVersion: 0, minimumSupported: 0, build: "old", pid: 1)))
        }
        defer { daemon.stop() }
        XCTAssertNil(RemoteHostDaemonAdmin.sessions(socketPath: daemon.socketPath, build: "1.2.3 (456)"))
        XCTAssertTrue(daemon.waitUntilReadingFinished())
        XCTAssertEqual(daemon.receivedControl.count, 1, "hello only — never retire")
        guard case .hello = daemon.receivedControl.first else { return XCTFail("expected hello") }
    }

    func testARemoteProbeNeverRetiresAnOlderDaemon() throws {
        let daemon = try FakePTYHostDaemon { frame, daemon in
            guard frame.kind == .control,
                  let control = try? JSONDecoder().decode(PTYHostFrame.self, from: frame.payload),
                  case .hello = control else { return }
            daemon.send(.hello(PTYHostHello(protocolVersion: 0, minimumSupported: 0, build: "old", pid: 1)))
        }
        defer { daemon.stop() }
        XCTAssertEqual(PTYHostClient.probe(socketPath: daemon.socketPath, build: "1.2.3 (456)", retiresOlderDaemon: false),
                       .mismatched(.peerTooOld))
        XCTAssertTrue(daemon.waitUntilReadingFinished())
        XCTAssertEqual(daemon.receivedControl.count, 1, "hello only — never retire")
    }

    /// The backstop: any client of this app for a forwarded remote socket defaults to not
    /// retiring, whichever call site built it.
    func testAForwardedSocketIsRecognisedAsARemoteDaemon() {
        let forwarded = RemoteHostSockets.forwardedSocketDirectory.appendingPathComponent("abc.sock").path
        XCTAssertTrue(RemoteHostSockets.isForwardedDaemonSocket(forwarded))
        XCTAssertFalse(RemoteHostSockets.isForwardedDaemonSocket(PTYHostLocation.socketPath))
        XCTAssertFalse(RemoteHostSockets.isForwardedDaemonSocket(
            RemoteHostSockets.forwardedSocketDirectory.path + "-elsewhere/abc.sock"
        ))
    }
}
