import Foundation
import ThreadingRemoteKit

/// Turns the policy-approved network candidates into a fixed number of sequential lanes.
///
/// A lane never splits one advertised door's sticky-port walk. The private-network kinds start
/// together, and a spare lane lets two Tailscale doors start together as the Happy-Eyeballs case:
/// an IPv4 TLS failure must not leave a usable IPv6 address waiting behind LAN timeouts. Four is
/// the resource contract, independent of how many endpoints or sticky ports a host advertises.
enum PrivateNetworkRouteRacePlan {
    static let maximumConcurrentLanes = 4
    static let maximumTailnetLanes = 2

    static func lanes(
        _ candidates: [RemoteHostConnectionCandidate]
    ) -> [[RemoteHostConnectionCandidate]] {
        guard !candidates.isEmpty else { return [] }

        var kindOrder: [String] = []
        var candidatesByKind: [String: [RemoteHostConnectionCandidate]] = [:]
        for candidate in candidates {
            if candidatesByKind[candidate.kind] == nil {
                kindOrder.append(candidate.kind)
            }
            candidatesByKind[candidate.kind, default: []].append(candidate)
        }

        var lanes: [[RemoteHostConnectionCandidate]] = []
        for (index, kind) in kindOrder.enumerated() {
            guard let kindCandidates = candidatesByKind[kind] else { continue }
            if lanes.count < maximumConcurrentLanes {
                lanes.append(kindCandidates)
            } else {
                // Endpoint selection currently admits at most four known kinds (three private
                // kinds plus the legacy relay). Folding a future kind into an existing lane keeps
                // every candidate without allowing wire input to raise connection concurrency.
                lanes[index % maximumConcurrentLanes].append(contentsOf: kindCandidates)
            }
        }

        guard lanes.count < maximumConcurrentLanes,
              let tailnetIndex = lanes.firstIndex(where: {
                  $0.first?.kind == RemoteHostEndpointKind.tailscale
              }) else {
            return lanes
        }

        let tailnetDoors = doorGroups(lanes[tailnetIndex])
        let tailnetLaneCount = min(
            maximumTailnetLanes,
            tailnetDoors.count,
            maximumConcurrentLanes - lanes.count + 1
        )
        guard tailnetLaneCount > 1 else { return lanes }

        var split = Array(
            repeating: [RemoteHostConnectionCandidate](),
            count: tailnetLaneCount
        )
        for (index, door) in tailnetDoors.enumerated() {
            split[index % tailnetLaneCount].append(contentsOf: door)
        }
        lanes[tailnetIndex] = split[0]
        lanes.append(contentsOf: split.dropFirst())
        return lanes
    }

    private static func doorGroups(
        _ candidates: [RemoteHostConnectionCandidate]
    ) -> [[RemoteHostConnectionCandidate]] {
        var doorOrder: [String] = []
        var candidatesByDoor: [String: [RemoteHostConnectionCandidate]] = [:]
        for candidate in candidates {
            if candidatesByDoor[candidate.doorID] == nil {
                doorOrder.append(candidate.doorID)
            }
            candidatesByDoor[candidate.doorID, default: []].append(candidate)
        }
        return doorOrder.compactMap { candidatesByDoor[$0] }
    }
}

/// Races a small, caller-bounded set of independent ways to obtain the same read-only result.
///
/// The first valid success wins. An early failure does not suppress a slower success, and if
/// every attempt fails the caller's priority chooses the stable error presented to the user.
/// This helper deliberately knows nothing about URLs or transports; `RemoteAppModel` supplies a
/// fixed set of hosted/private lanes and keeps each lane's port walk sequential.
enum FirstSuccessfulTaskRace {
    enum RaceError: Error {
        case noAttempts
    }

    struct Attempt<Value: Sendable>: Sendable {
        let id: String
        let failurePriority: Int
        let operation: @Sendable () async throws -> Value

        init(
            id: String,
            failurePriority: Int,
            operation: @escaping @Sendable () async throws -> Value
        ) {
            self.id = id
            self.failurePriority = failurePriority
            self.operation = operation
        }
    }

    struct Winner<Value: Sendable>: Sendable {
        let id: String
        let value: Value
    }

    private struct FailedAttempt: @unchecked Sendable {
        let insertionOrder: Int
        let priority: Int
        let error: Error
    }

    private enum Completion<Value: Sendable>: @unchecked Sendable {
        case succeeded(id: String, value: Value)
        case failed(FailedAttempt)
    }

    static func run<Value: Sendable>(
        _ attempts: [Attempt<Value>],
        winnerSelected: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> Winner<Value> {
        guard !attempts.isEmpty else { throw RaceError.noAttempts }

        return try await withThrowingTaskGroup(
            of: Completion<Value>.self,
            returning: Winner<Value>.self
        ) { group in
            for (index, attempt) in attempts.enumerated() {
                group.addTask {
                    do {
                        let value = try await attempt.operation()
                        try Task.checkCancellation()
                        return .succeeded(id: attempt.id, value: value)
                    } catch {
                        return .failed(FailedAttempt(
                            insertionOrder: index,
                            priority: attempt.failurePriority,
                            error: error
                        ))
                    }
                }
            }

            var failures: [FailedAttempt] = []
            while let completion = try await group.next() {
                switch completion {
                case .succeeded(let id, let value):
                    // Some route owners wrap their real work in a coalesced unstructured task.
                    // Let them stop that task before the structured group waits for cancellation.
                    await winnerSelected(id)
                    group.cancelAll()
                    return Winner(id: id, value: value)
                case .failed(let failure):
                    failures.append(failure)
                }
            }

            if Task.isCancelled { throw CancellationError() }
            let selected = failures.min {
                ($0.priority, $0.insertionOrder) < ($1.priority, $1.insertionOrder)
            }
            throw selected?.error ?? RaceError.noAttempts
        }
    }
}
