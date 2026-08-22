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

/// What one route walk may spend, per attempt and in total.
///
/// Every number here is read off the 2026-08-21 incident rather than chosen. That walk ran 23
/// candidates at 4000 ms each, serially, and the tailnet address that worked was attempt 22: the
/// person watched a bare spinner for ninety seconds and filed a support report before the route
/// that was up got its turn. Two facts from the same journal set the bounds:
///
/// - **A route's own address answers in under a second or not at all.** The tailnet door that
///   worked returned in 818 ms and 929 ms on the two traces that reached it. A LAN address whose
///   SYNs are being dropped returns nothing at all, so its cost is exactly whatever timeout it is
///   given. Four seconds is kept for a route's own address, because that attempt is the one whose
///   answer decides whether the route exists.
/// - **A guessed port is worth less than an address.** A Mac on this network refuses a port
///   nothing is listening on immediately; a port that neither answers nor refuses inside two
///   seconds is behind the same silence as the address itself. So the sticky range is walked at
///   half the price.
///
/// The ceiling follows from the ordering: under `RemoteRouteWave` every route's own address is
/// tried in the first wave, so a Mac with three routes has spent at most three route timeouts
/// before every way in has been heard from. Twelve seconds covers that, and it ends the wait well
/// inside the fifteen seconds after which a person concludes the app is broken. A walk of exactly
/// one candidate is not a walk and keeps the ordinary request timeout: there is no other route to
/// get on with, so cutting it short would only turn a slow success into a failure.
enum RemoteRouteWalkBudget {
    /// What one address of a route is given before the walk moves on.
    static let routeAttemptTimeout: TimeInterval = 4
    /// What one guessed port of the sticky range is given.
    static let portAttemptTimeout: TimeInterval = 2
    /// What one address of a route is given for an operation that changes something on the Mac,
    /// which may do real work before it answers.
    static let mutationAttemptTimeout: TimeInterval = 8
    /// The whole read-only walk's ceiling, past which the caller is answered.
    static let walkCeiling: TimeInterval = 12

    /// The timeout for one read-only attempt.
    static func timeout(for wave: RemoteRouteWave?, isOnlyCandidate: Bool) -> TimeInterval {
        guard !isOnlyCandidate else { return RemoteClientDefaults.requestTimeoutSeconds }
        return wave == .port ? portAttemptTimeout : routeAttemptTimeout
    }

    /// The timeout for one attempt at an operation that changes something on the Mac.
    static func mutationTimeout(for wave: RemoteRouteWave?, isOnlyCandidate: Bool) -> TimeInterval {
        guard !isOnlyCandidate else { return RemoteClientDefaults.requestTimeoutSeconds }
        return wave == .port ? routeAttemptTimeout : mutationAttemptTimeout
    }

    /// How long a whole walk over `candidateCount` candidates may keep the caller waiting.
    static func ceiling(forCandidateCount candidateCount: Int) -> TimeInterval {
        candidateCount > 1 ? walkCeiling : RemoteClientDefaults.requestTimeoutSeconds
    }
}

/// Answers the caller with whichever comes first, the walk or the budget, and lets the walk go on.
///
/// A walk that has run out of budget has not been proved wrong; it has only stopped being
/// something to make a person wait for. So the caller is handed the ordinary named transport
/// failure at the ceiling while the walk keeps its remaining candidates, and a success that lands
/// afterwards is delivered to `lateSuccess` rather than thrown away. That is what makes the
/// ceiling safe to set at twelve seconds: nothing is abandoned, only stopped being waited on.
@MainActor
enum RemoteRouteWalkDeadline {

    /// Which side of the race answered.
    private final class Arbiter<Value> {
        private enum State {
            case waiting
            case answeredBeforeAnyoneWaited(Result<Value, Error>?)
            case listening(CheckedContinuation<Result<Value, Error>?, Never>)
            case settled
        }

        private var state: State = .waiting

        /// The first answer, or nil when the budget elapsed first.
        func firstAnswer() async -> Result<Value, Error>? {
            switch state {
            case .answeredBeforeAnyoneWaited(let answer):
                state = .settled
                return answer
            case .waiting:
                return await withCheckedContinuation { continuation in
                    state = .listening(continuation)
                }
            case .listening, .settled:
                return nil
            }
        }

        /// True when this answer is the one the caller received.
        @discardableResult
        func settle(_ answer: Result<Value, Error>?) -> Bool {
            switch state {
            case .waiting:
                state = .answeredBeforeAnyoneWaited(answer)
                return true
            case .listening(let continuation):
                state = .settled
                continuation.resume(returning: answer)
                return true
            case .answeredBeforeAnyoneWaited, .settled:
                return false
            }
        }
    }

    static func run<Value: Sendable>(
        ceiling: TimeInterval,
        walk: @escaping @MainActor () async throws -> Value,
        lateSuccess: @escaping @MainActor (Value) async -> Void,
        exceeded: @escaping @Sendable () -> Error
    ) async throws -> Value {
        let arbiter = Arbiter<Value>()
        let walkTask = Task { @MainActor in try await walk() }
        let budgetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(ceiling))
            guard !Task.isCancelled else { return }
            arbiter.settle(nil)
        }
        Task { @MainActor in
            let outcome = await walkTask.result
            let wasAwaited = arbiter.settle(outcome)
            budgetTask.cancel()
            guard !wasAwaited, case .success(let value) = outcome else { return }
            await lateSuccess(value)
        }

        // Cancellation still means cancellation. The walk outliving its *budget* is the point;
        // outliving a refresh that was replaced, or a Mac the user switched away from, would be a
        // route walk nothing owns.
        let answer = await withTaskCancellationHandler {
            await arbiter.firstAnswer()
        } onCancel: {
            walkTask.cancel()
            budgetTask.cancel()
        }
        guard let answer else { throw exceeded() }
        return try answer.get()
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
