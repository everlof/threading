import Foundation
import ThreadingPTYHostKit

/// One connection carries one session's raw byte stream. Hosts synchronize this value alongside
/// their connection state; the policy itself performs no I/O and owns no locks or event queues.
struct PTYHostConnectionBinding {
    struct Reservation: Equatable {
        fileprivate let generation: UInt64
    }

    private(set) var session: PTYHostSessionIdentity?
    private var reservation: Reservation?
    private var generation: UInt64 = 0

    @discardableResult
    mutating func prepare(_ frame: PTYHostFrame) throws -> Reservation? {
        switch frame {
        case .spawn(let request): return try bind(request.id)
        case .attach(let request): return try bind(request.id)
        case .resize(let request): try requireMatch(request.id)
        case .detach(let request): try requireMatch(request.id)
        case .closeInput(let request): try requireMatch(request.id)
        case .kill(let request): try requireMatch(request.id)
        default: break
        }
        return nil
    }

    func requireInputBinding() throws {
        guard session != nil else { throw PTYHostClientError.notBound }
    }

    /// A frame never accepted by the writer releases only its own attempt. Session identity
    /// alone cannot distinguish a refused attempt from a retry for that same session.
    mutating func sendingFailed(_ attempt: Reservation?) {
        guard let attempt, reservation == attempt else { return }
        reset()
    }

    /// Refusal lets the caller try again. An unrelated refusal cannot unbind the active stream.
    mutating func received(_ frame: PTYHostFrame) {
        if case .spawnRefused(let refusal) = frame { release(matching: refusal.id) }
    }

    mutating func reset() { session = nil; reservation = nil }

    private mutating func bind(_ id: PTYHostSessionIdentity) throws -> Reservation {
        if let session { throw PTYHostClientError.alreadyBound(session) }
        generation &+= 1
        let attempt = Reservation(generation: generation)
        session = id
        reservation = attempt
        return attempt
    }

    private func requireMatch(_ id: PTYHostSessionIdentity) throws {
        guard let session else { throw PTYHostClientError.notBound }
        guard session == id else { throw PTYHostClientError.sessionMismatch(bound: session, frame: id) }
    }

    private mutating func release(matching id: PTYHostSessionIdentity) {
        if session == id { reset() }
    }
}
