import Foundation
import ThreadingController

/// Runs this host's half of mail exchange with its peers: pushes what it holds for each, pulls
/// what each holds for it. Each exchange runs the owner-authored transport argv (normally `ssh`
/// to a forced-command key) with one bounded request on stdin and one response on stdout.
public enum ControllerMailSync {
    public struct Report: Codable, Sendable {
        public var pushed = 0
        public var pulled = 0
        public var issues: [String] = []
        public var isEmpty: Bool { pushed == 0 && pulled == 0 && issues.isEmpty }
    }
    public enum Limits {
        public static let peersPerPass = 8
        public static let exchangesPerDirection = 4
        public static let timeout: TimeInterval = 30
    }

    /// One bounded pass over a page of peers. Returns the cursor for the next page (0 wraps).
    public static func sync(store: ControllerStore, after: Int64 = 0) async throws -> (Report, Int64) {
        var report = Report()
        let page = try await store.mailPeersToSync(after: after, limit: Limits.peersPerPass)
        for peer in page.items {
            do { try await sync(peer: peer, store: store, report: &report) }
            catch { report.issues.append("\(peer.host): \(describe(error))") }
        }
        return (report, page.next)
    }

    static func sync(peer: MailPeer, store: ControllerStore, report: inout Report) async throws {
        guard let transport = peer.transport else { return }
        let local = try await store.host()
        if peer.push {
            for _ in 0..<Limits.exchangesPerDirection {
                let batch = try await store.outboundBatch(for: peer.host)
                guard !batch.envelopes.isEmpty else { break }
                let response = try await exchange(transport, MailRPCRequest(push: MailPush(from: local.id, messages: batch.envelopes)), expecting: peer.host)
                try await store.applyPushResults(response.results ?? [], peer: peer.host)
                report.pushed += (response.results ?? []).filter { $0.outcome != .refused }.count
            }
        }
        if peer.pull {
            var current = peer
            for _ in 0..<Limits.exchangesPerDirection {
                let response = try await exchange(transport, MailRPCRequest(pull: MailPull(after: current.pullCursor, refused: current.pendingRefusals)), expecting: peer.host)
                let messages = response.messages ?? []
                let complete = try await store.acceptPulled(messages, from: peer.host, next: response.next ?? current.pullCursor)
                // A page this store could not write stays unacknowledged; the next pass pulls it again.
                guard complete else { report.issues.append("\(peer.host): \(MailRefusalReason.unavailable)"); break }
                report.pulled += messages.count
                guard !messages.isEmpty, let reloaded = try await store.mailPeer(peer.host) else { break }
                current = reloaded
            }
        }
    }

    /// A response from a host other than the one configured is refused: an SSH alias that now
    /// reaches a different machine must not receive or supply mail.
    public static func exchange(_ argv: [String], _ request: MailRPCRequest, expecting host: HostID) async throws -> MailRPCResponse {
        let input = try JSONEncoder().encode(request)
        guard input.count <= MailTransportLimits.requestBytes else { throw ControllerError.invalidInput("mail_rpc_size") }
        let output = try await run(argv, input: input, limit: MailTransportLimits.responseBytes, timeout: Limits.timeout)
        let response = try JSONDecoder().decode(MailRPCResponse.self, from: output)
        guard response.host == host else { throw ControllerError.invalidInput("mail_peer_identity") }
        return response
    }

    static func run(_ argv: [String], input: Data, limit: Int, timeout: TimeInterval) async throws -> Data {
        guard let executable = argv.first else { throw ControllerRuntimeError.unavailable }
        let result = await BoundedCommand.run(executable: executable, arguments: Array(argv.dropFirst()),
            environment: ProcessInfo.processInfo.environment, directory: FileManager.default.currentDirectoryPath,
            input: input, timeout: timeout, outputLimit: limit)
        if result.failure == "timed_out" { throw ControllerRuntimeError.timedOut }
        if result.failure == "output_too_large" { throw ControllerRuntimeError.overflow }
        guard result.failure == nil, result.exitCode == 0 else { throw ControllerRuntimeError.unavailable }
        return result.output
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ControllerError { return error.description }
        if let error = error as? ControllerRuntimeError {
            switch error {
            case .unavailable: return "unavailable"
            case .timedOut: return "timed_out"
            case .overflow: return "response_too_large"
            case .protocolFailure: return "protocol_failure"
            case .spawnRefused: return "refused"
            }
        }
        return "invalid_response"
    }
}
