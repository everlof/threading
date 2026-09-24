import Foundation
import XCTest
@testable import Threading

final class CodexRolloutIdentityTests: XCTestCase {
    func testFindsOnlyOneRecentRolloutForTheLaunchingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingCodexIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let launchedAt = Date()
        let wanted = TranscriptID(UUID().uuidString.lowercased())
        let unrelated = TranscriptID(UUID().uuidString.lowercased())
        try write(id: unrelated, cwd: other.path, in: sessions, at: launchedAt)
        let wantedFile = dayDirectory(in: sessions, at: launchedAt)
            .appendingPathComponent("rollout-\(wanted.rawValue).jsonl")
        try write(id: wanted, cwd: project.path, in: sessions, at: launchedAt)
        XCTAssertEqual(CodexRolloutIdentity.find(
            projectPath: project.path + "/", sessionsDirectory: sessions, launchedAt: launchedAt
        ), wanted)
        XCTAssertEqual(CodexRolloutIdentity.rolloutURL(for: wanted, projectPath: project.path,
            sessionsDirectory: sessions, launchedAt: launchedAt)?.resolvingSymlinksInPath(),
            wantedFile.resolvingSymlinksInPath())
        XCTAssertNil(CodexRolloutIdentity.rolloutURL(for: unrelated, projectPath: project.path,
            sessionsDirectory: sessions, launchedAt: launchedAt))

        let competing = TranscriptID(UUID().uuidString.lowercased())
        try write(id: competing, cwd: project.path, in: sessions, at: launchedAt)
        XCTAssertNil(CodexRolloutIdentity.find(
            projectPath: project.path, sessionsDirectory: sessions, launchedAt: launchedAt
        ))
        XCTAssertEqual(CodexRolloutIdentity.rolloutURL(for: wanted, projectPath: project.path,
            sessionsDirectory: sessions, launchedAt: launchedAt)?.resolvingSymlinksInPath(),
            wantedFile.resolvingSymlinksInPath())
    }

    private func write(id: TranscriptID, cwd: String, in sessions: URL, at date: Date) throws {
        let day = dayDirectory(in: sessions, at: date)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let header: [String: Any] = ["type": "session_meta", "payload": ["id": id.rawValue, "cwd": cwd]]
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(10)
        try data.write(to: day.appendingPathComponent("rollout-\(id.rawValue).jsonl"))
    }

    private func dayDirectory(in sessions: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        return sessions.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }
}
