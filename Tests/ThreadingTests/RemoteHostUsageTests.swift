import Foundation
import XCTest
@testable import Threading

/// A remote session's usage: read from its transcript mirror, billed to the host's own login rather
/// than an account on this Mac, and never counted twice.
@MainActor
final class RemoteHostUsageTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/threading-remote-usage-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func project(_ name: String, host: ProjectExecutionHost?) -> Project {
        var project = Project(name: name, folderURL: URL(fileURLWithPath: "/tmp/\(name)"))
        project.executionHost = host
        return project
    }

    /// One source per machine, however many projects run on it, named for the machine — a remote
    /// agent spends the host's login, and attributing that to a Mac account would show it spending
    /// tokens it never spent.
    func testEachHostIsOneSourceNamedForTheMachine() {
        let record = RemoteHostRecord.typed(label: "Build box", destination: "box", sshConfigFile: "")
        let onBox = ProjectExecutionHost.on(record, remoteDirectory: "/srv/a")
        let alsoOnBox = ProjectExecutionHost.on(record, remoteDirectory: "/srv/b")
        let onPi = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/app")

        let sources = TranscriptUsageService.remoteHostSources(
            projects: [
                project("a", host: onBox),
                project("b", host: alsoOnBox),
                project("c", host: onPi),
                project("local", host: nil)
            ],
            hostName: { $0 == record.id ? record.displayName : nil },
            mirrorRoot: root
        )

        XCTAssertEqual(sources.count, 2, "one machine was counted once per project on it")
        XCTAssertEqual(sources.map(\.accountName), [
            L10n.format("%@ (remote host)", "Build box"),
            L10n.format("%@ (remote host)", "pi")
        ])
        XCTAssertTrue(sources.allSatisfy { $0.accountID.hasPrefix(UsageReportDefaults.remoteHostAccountPrefix) })
        XCTAssertTrue(sources.allSatisfy { $0.layout == .remoteMirror && $0.runtimeID == AgentKind.claude.rawValue })
        XCTAssertEqual(
            sources.first?.path,
            root.appendingPathComponent(onBox.sshDestination.identifier, isDirectory: true).path
        )
    }

    /// The mirror's own files are what is scanned — flat, `.jsonl` only — and a record read from one
    /// carries the host's identity, the conversation's own id, and the remote checkout it ran in.
    func testAMirroredTranscriptYieldsRecordsBilledToTheHost() throws {
        let mirror = root.appendingPathComponent("0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let line = #"{"sessionId":"5c9e","requestId":"r1","timestamp":"2026-09-18T10:00:00.000Z","cwd":"/home/me/app","message":{"id":"m1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":4}}}"#
        try (line + "\n").write(to: mirror.appendingPathComponent("5c9e.jsonl"), atomically: true, encoding: .utf8)
        try Data().write(to: mirror.appendingPathComponent(".partial-download"))

        let files = TranscriptUsageIndex.transcripts(inMirrorAt: mirror.path)
        XCTAssertEqual(files.map(\.lastPathComponent), ["5c9e.jsonl"])

        let record = try XCTUnwrap(try ClaudeUsageAdapter.records(
            inTranscriptAt: try XCTUnwrap(files.first),
            accountID: UsageReportDefaults.remoteHostAccountPrefix + "0123456789abcdef",
            accountName: L10n.format("%@ (remote host)", "pi")
        ).first)
        XCTAssertEqual(record.sessionID, "5c9e", "a receipt finds a conversation by this id")
        XCTAssertEqual(record.accountID, UsageReportDefaults.remoteHostAccountPrefix + "0123456789abcdef")
        XCTAssertEqual(record.tokens.output, 4)
    }

    /// A mirror is never listed by an account scan, which would take it for a local conversation.
    func testAnAccountScanNeverSeesAMirror() throws {
        let account = root.appendingPathComponent("claude-config", isDirectory: true)
        let projects = account.appendingPathComponent("projects/-Users-me-app", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: projects.appendingPathComponent("local.jsonl"))

        let mirrorRoot = RemoteTranscriptMirror.shared.root.standardizedFileURL.path
        XCTAssertFalse(mirrorRoot.contains("/.claude"), "the mirror sits inside a Claude directory")
        XCTAssertEqual(TranscriptUsageIndex.transcripts(inAccountAt: account.path).map(\.lastPathComponent),
                       ["local.jsonl"])
    }
}
