import XCTest
@testable import Threading

@MainActor
final class GitRepositoryAdmissionTests: XCTestCase {
    func testRepositoryDiscoveryDoesNotWaitForAnUnrelatedReview() async throws {
        let enclosure = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRepositoryAdmissionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: enclosure) }
        let slow = try await makeRepository(at: enclosure.appendingPathComponent("slow"))
        let fast = try await makeRepository(at: enclosure.appendingPathComponent("fast"))
        let monitor = slow.appendingPathComponent(".git/blocking-monitor")
        let entered = slow.appendingPathComponent(".git/monitor-entered")
        let release = slow.appendingPathComponent(".git/monitor-release")
        try """
        #!/bin/sh
        touch .git/monitor-entered
        for i in $(seq 1 100); do
            test -e .git/monitor-release && break
            /bin/sleep 0.1
        done
        printf 'fixture-token\\000'
        """.write(to: monitor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        defer { try? Data().write(to: release) }
        try await runGit(["config", "core.fsmonitor", monitor.path], in: slow)

        let reviewFinished = expectation(description: "blocked review released")
        GitReviewReader.diff(.uncommitted, in: slow) { _ in reviewFinished.fulfill() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: entered.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entered.path))

        let discovered = expectation(description: "repository discovered while review is blocked")
        var result: Result<[String], GitFailure>?
        let started = ContinuousClock.now
        GitReviewReader.repositoryFiles(in: fast) {
            result = $0
            discovered.fulfill()
        }
        await fulfillment(of: [discovered], timeout: 3)
        let discoveryDuration = started.duration(to: .now)
        try Data().write(to: release)
        await fulfillment(of: [reviewFinished], timeout: 5)
        XCTAssertEqual(try XCTUnwrap(result).get(), ["file.swift"])
        print("repository discovery with blocked review: \(discoveryDuration)")
    }

    private func makeRepository(at root: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("first\n".utf8).write(to: root.appendingPathComponent("file.swift"))
            for arguments in [
                ["init", "--quiet"],
                ["config", "user.name", "Fixture"],
                ["config", "user.email", "fixture@example.com"],
                ["config", "commit.gpgsign", "false"],
                ["add", "file.swift"],
                ["commit", "--quiet", "-m", "first"]
            ] {
                _ = try GitProcess.run(arguments, in: root, maximumOutput: 1_024, timeout: 5)
            }
            try Data("second\n".utf8).write(to: root.appendingPathComponent("file.swift"))
            return root
        }.value
    }

    private func runGit(_ arguments: [String], in root: URL) async throws {
        _ = try await Task.detached(priority: .userInitiated) {
            try GitProcess.run(arguments, in: root, maximumOutput: 1_024, timeout: 5)
        }.value
    }
}
