import Foundation
import os
import XCTest
@testable import Threading
import ThreadingController

/// Paging, page budgets, the command allow-list and staleness of connected hosts' usage reads,
/// against a fake owner-RPC transport.
final class RemoteAgentUsageClientTests: XCTestCase {
    static let workerA = "11111111-1111-1111-1111-111111111111"
    static let workerB = "22222222-2222-2222-2222-222222222222"
    /// 2026-10-03 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_028_800)

    static func cell(_ day: String, worker: String = workerA, model: String = "claude-sonnet-4-5",
                     uncached: Int64 = 100, output: Int64 = 50, cost: Double = 1, requests: Int64 = 2) -> String {
        """
        {"day":"\(day)","workerID":"\(worker)","account":"ops","model":"\(model)","uncachedInput":\(uncached),\
        "cachedInput":0,"cacheWrite":0,"output":\(output),"reasoning":0,"costUSD":\(cost),"requests":\(requests),"executions":1}
        """
    }

    static func page(_ cells: [String], next: Int64) -> Data {
        Data("{\"items\":[\(cells.joined(separator: ","))],\"next\":\(next)}".utf8)
    }

    /// Answers each command from a closure and records what was asked.
    final class FakeTransport: RemoteAgentUsageTransport, @unchecked Sendable {
        let calls = OSAllocatedUnfairLock(initialState: [(String, [String])]())
        let concurrent = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        let answer: @Sendable (String, [String], RemoteHostID) throws -> Data
        let delay: UInt64
        init(delay: UInt64 = 0, answer: @escaping @Sendable (String, [String], RemoteHostID) throws -> Data) {
            self.answer = answer; self.delay = delay
        }
        func ownerRPC(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                      command: String, arguments: [String]) async throws -> Data {
            calls.withLock { $0.append((command, arguments)) }
            concurrent.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            defer { concurrent.withLock { $0.now -= 1 } }
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return try answer(command, arguments, endpoint.hostID)
        }
    }

    static func host(_ name: String = "devbox", id: RemoteHostID = RemoteHostID()) -> RemoteAgentUsageHost {
        RemoteAgentUsageHost(id: id, name: name,
                             endpoint: RemoteAutomationEndpoint(hostID: id, executable: "/usr/bin/controller", database: "/var/db/c.db"),
                             destination: RemoteHostDestination(alias: name, configFile: nil))
    }

    // MARK: - Client

    func testSummaryPagesEachSegmentNewestFirstUntilAnEmptyPage() async throws {
        let transport = FakeTransport { command, arguments, _ in
            XCTAssertEqual(command, "usage-summary")
            switch (arguments[0], arguments[2]) {
            case ("2026-09-27", "0"): return Self.page([Self.cell("2026-10-03"), Self.cell("2026-10-02")], next: 2)
            case ("2026-09-27", "2"): return Self.page([Self.cell("2026-09-30")], next: 9)
            default: return Self.page([], next: Int64(arguments[2]) ?? 0)
            }
        }
        let read = try await RemoteAgentUsageClient(transport: transport).summary(
            endpoint: Self.host().endpoint, destination: Self.host().destination, now: Self.now)
        XCTAssertEqual(read.cells.map(\.day), ["2026-10-03", "2026-10-02", "2026-09-30"])
        XCTAssertFalse(read.isTruncated)
        XCTAssertEqual(read.completeFrom, "2026-07-06", "ninety UTC days ending today")
        let ranges = transport.calls.withLock { $0.map { [$0.1[0], $0.1[1], $0.1[2]] } }
        XCTAssertEqual(ranges, [
            ["2026-09-27", "2026-10-03", "0"], ["2026-09-27", "2026-10-03", "2"], ["2026-09-27", "2026-10-03", "9"],
            ["2026-09-04", "2026-09-26", "0"], ["2026-07-06", "2026-09-03", "0"]
        ])
    }

    func testPageBudgetCutsTheOldestDaysAndSaysFromWhenTheReadIsComplete() async throws {
        let transport = FakeTransport { _, arguments, _ in
            let cursor = Int64(arguments[2]) ?? 0
            // The newest week ends; the older segments never do.
            if arguments[0] == "2026-09-27", cursor >= 1 { return Self.page([], next: cursor) }
            return Self.page([Self.cell(arguments[1])], next: cursor + 1)
        }
        let read = try await RemoteAgentUsageClient(transport: transport).summary(
            endpoint: Self.host().endpoint, destination: Self.host().destination, now: Self.now, maximumPages: 6)
        XCTAssertTrue(read.isTruncated)
        XCTAssertEqual(read.completeFrom, "2026-09-27", "only the newest week was read completely")
        XCTAssertEqual(transport.calls.withLock { $0.count }, 6, "the page budget bounds the work, not just the result")
    }

    func testARepeatedCursorStopsTheRead() async {
        let transport = FakeTransport { _, _, _ in Self.page([Self.cell("2026-10-03")], next: 0) }
        do {
            _ = try await RemoteAgentUsageClient(transport: transport).summary(
                endpoint: Self.host().endpoint, destination: Self.host().destination, now: Self.now)
            XCTFail("a page that did not advance was accepted")
        } catch {
            XCTAssertEqual(error as? RemoteAgentUsageError, .cursorDidNotAdvance)
        }
        XCTAssertEqual(transport.calls.withLock { $0.count }, 1)
    }

    func testOnlyUsageCommandsCrossTheSSHTransport() async throws {
        let transport = SSHRemoteAgentUsageTransport(runner: RefusingRunner())
        do {
            _ = try await transport.ownerRPC(endpoint: Self.host().endpoint, destination: Self.host().destination,
                                             command: "automation-delete", arguments: [])
            XCTFail("a mutation outside the usage set reached SSH")
        } catch {
            XCTAssertEqual(error as? RemoteAgentUsageError, .commandNotAllowed("automation-delete"))
        }
    }

    private struct RefusingRunner: RemoteHostCommandRunning {
        func run(on destination: RemoteHostDestination, command: String, input: RemoteHostCommandInput,
                 extraOptions: [String], timeout: TimeInterval) throws -> RemoteHostCommandResult {
            XCTFail("reached ssh"); return .init(output: "", termination: .exited(1))
        }
    }

    func testBudgetSetSendsTheRevisionAndNoneForNoLimit() async throws {
        let transport = FakeTransport { command, arguments, _ in
            XCTAssertEqual(command, "worker-budget-set")
            XCTAssertEqual(arguments, [Self.workerA, "3", "none"])
            return Data("{\"workerID\":\"\(Self.workerA)\",\"revision\":4}".utf8)
        }
        let budget = try await RemoteAgentUsageClient(transport: transport).setBudget(
            endpoint: Self.host().endpoint, destination: Self.host().destination,
            worker: try WorkerID(Self.workerA), expectedRevision: 3, tokensPerDay: nil)
        XCTAssertEqual(budget.revision, 4)
        XCTAssertNil(budget.tokensPerDay)
    }

    func testAbsentBudgetDecodesAsNil() async throws {
        let transport = FakeTransport { _, _, _ in Data("null\n".utf8) }
        let budget = try await RemoteAgentUsageClient(transport: transport).budget(
            endpoint: Self.host().endpoint, destination: Self.host().destination, worker: try WorkerID(Self.workerA))
        XCTAssertNil(budget)
    }

    // MARK: - Service

    private func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agent-usage-\(UUID().uuidString).json")
    }

    static func healthyAnswer(_ command: String, _ arguments: [String]) -> Data {
        if command == "workers" {
            return arguments[0] == "0"
                ? Data("{\"items\":[{\"id\":\"\(workerA)\",\"name\":\"Newsletter triage\"}],\"next\":1}".utf8)
                : page([], next: 1)
        }
        return arguments[0] == "2026-09-27" && arguments[2] == "0"
            ? page([cell("2026-10-03")], next: 1) : page([], next: Int64(arguments[2]) ?? 0)
    }

    func testAnUnreachableHostKeepsItsLastSummaryAndIsStaleNotEmpty() async throws {
        let url = cacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = Self.host()
        let reachable = OSAllocatedUnfairLock(initialState: true)
        let transport = FakeTransport { command, arguments, _ in
            guard reachable.withLock({ $0 }) else { throw RemoteAgentUsageError.rejected("ssh: connect: timed out") }
            return Self.healthyAnswer(command, arguments)
        }
        let clock = OSAllocatedUnfairLock(initialState: Self.now)
        let service = RemoteAgentUsageService(client: .init(transport: transport), cacheURL: url, postsEvents: false,
                                              now: { clock.withLock { $0 } })
        let unread = await service.states(for: [host])
        XCTAssertEqual(unread.first?.freshness(now: Self.now), .unread)

        await service.refresh(hosts: [host])
        var states = await service.states(for: [host])
        var state = try XCTUnwrap(states.first)
        XCTAssertEqual(state.freshness(now: Self.now), .current)
        XCTAssertEqual(state.snapshot?.cells.count, 1)
        XCTAssertEqual(state.snapshot?.workerNames[Self.workerA], "Newsletter triage")

        reachable.withLock { $0 = false }
        clock.withLock { $0 = Self.now.addingTimeInterval(3_600) }
        await service.refresh(hosts: [host], force: true)
        states = await service.states(for: [host])
        state = try XCTUnwrap(states.first)
        XCTAssertEqual(state.snapshot?.cells.count, 1, "a failed read never replaces the last summary")
        XCTAssertNotNil(state.lastFailure)
        XCTAssertEqual(state.freshness(now: Self.now.addingTimeInterval(3_600)), .stale(since: Self.now))

        // The cache survives a relaunch with its age intact.
        let reopened = RemoteAgentUsageService(client: .init(transport: transport), cacheURL: url, postsEvents: false)
        let restoredStates = await reopened.states(for: [host])
        let restored = try XCTUnwrap(restoredStates.first)
        XCTAssertEqual(restored.snapshot?.fetchedAt, Self.now)
        XCTAssertEqual(restored.snapshot?.cells.count, 1)
    }

    func testAgeAloneMakesASummaryStale() {
        var state = RemoteAgentUsageHostState(hostID: RemoteHostID(), hostName: "devbox")
        state.snapshot = RemoteAgentUsageSnapshot(fetchedAt: Self.now, from: "2026-07-06", through: "2026-10-03",
                                                  completeFrom: "2026-07-06", cells: [], workerNames: [:])
        XCTAssertEqual(state.freshness(now: Self.now.addingTimeInterval(60)), .current)
        XCTAssertEqual(state.freshness(now: Self.now.addingTimeInterval(RemoteAgentUsageDefaults.staleAfter + 1)),
                       .stale(since: Self.now))
    }

    func testHostsAreReadBoundedlyConcurrentAndDisconnectedOnesAreForgotten() async throws {
        let url = cacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = FakeTransport(delay: 20_000_000) { command, arguments, _ in Self.healthyAnswer(command, arguments) }
        let service = RemoteAgentUsageService(client: .init(transport: transport), cacheURL: url, postsEvents: false,
                                              now: { Self.now })
        let hosts = (0..<8).map { Self.host("host\($0)") }
        await service.refresh(hosts: hosts)
        XCTAssertLessThanOrEqual(transport.concurrent.withLock { $0.peak }, RemoteAgentUsageDefaults.maximumConcurrentHosts)
        let read = await service.states(for: hosts)
        XCTAssertEqual(read.compactMap(\.snapshot).count, 8)

        // Within the refresh interval nothing is re-read unless forced.
        let before = transport.calls.withLock { $0.count }
        await service.refresh(hosts: hosts)
        XCTAssertEqual(transport.calls.withLock { $0.count }, before)

        await service.refresh(hosts: Array(hosts.prefix(2)), force: true)
        let kept = await service.states(for: hosts)
        XCTAssertEqual(kept.compactMap(\.snapshot).count, 2, "a host that is no longer connected leaves the page")
    }
}
