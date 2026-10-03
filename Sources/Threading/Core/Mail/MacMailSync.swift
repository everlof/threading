import Foundation
import ThreadingController

// MARK: - Mac Mail Sync

/// Exchanges agent mail between this Mac's mailbox and the controllers on its remote hosts.
///
/// The Mac sits behind NAT, so it initiates both directions (`agent-mail.md`, "Transport between
/// hosts"): it pushes what it holds for a host and pulls what the host holds for it. A host takes
/// part once its controller's executable and database paths are saved — the Remote automations
/// page stores them on the `RemoteHostRecord` — and it is synced while this Mac is connected to it
/// (its tunnel is up), every `interval`, and soon after an agent here sends to it.
///
/// **Peering is owner work over owner SSH.** Each side must name the other as a peer before
/// `mail-rpc` accepts anything: the Mac writes the host into its own store, and asks the host's
/// `owner-rpc` to write the Mac into the host's (`mail-peer-set`). Neither entry carries a
/// transport — the host cannot reach the Mac, and the Mac runs the exchange itself — so the
/// host's supervisor never tries to dial this laptop.
///
/// **An exchange is one bounded request on stdin** to `<controller> --database <db> mail-rpc
/// --peer <this Mac's host id>`, over the same SSH runner the automation client uses. The owner's
/// SSH authority covers the peer authority `mail-rpc` grants. Every response names the host that
/// answered, and one from any host other than the peered one is refused: an alias that now
/// reaches a different machine must neither receive nor supply mail.
actor MacMailSync {

    // MARK: - Types

    /// One remote controller this Mac exchanges mail with.
    struct Endpoint: Equatable, Sendable {
        let hostID: RemoteHostID
        let name: String
        let destination: RemoteHostDestination
        let executable: String
        let database: String
    }

    struct Report: Equatable, Sendable {
        var pushed = 0
        var pulled = 0
        var issues: [String] = []
        /// Mac sessions that received mail in this pass.
        var recipients: Set<SessionID> = []
    }

    enum SyncError: Error, Equatable {
        case transport(String)
        case invalidResponse
        case wrongHost
    }

    // MARK: - Properties

    static let shared = MacMailSync(
        mailbox: .shared,
        runner: SystemSSHCommandRunner(maximumOutputBytes: MailTransportLimits.responseBytes)
    )

    private let mailbox: MacMailbox
    private let runner: any RemoteHostCommandRunning
    /// The controller host id each endpoint answered with, once peered in this run.
    private var peered: [RemoteHostID: HostID] = [:]
    private var inFlight: Set<RemoteHostID> = []
    private var timer: Task<Void, Never>?
    private var endpointsProvider: (@MainActor () -> [Endpoint])?

    // MARK: - Initialization

    init(mailbox: MacMailbox, runner: any RemoteHostCommandRunning) {
        self.mailbox = mailbox
        self.runner = runner
    }

    // MARK: - Scheduling

    /// Starts the periodic pass. `endpoints` answers on the main actor with the hosts that are
    /// configured and currently connected.
    func start(endpoints: @escaping @MainActor () -> [Endpoint]) {
        guard timer == nil else { return }
        endpointsProvider = endpoints
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MacMailSyncDefaults.interval * 1_000_000_000))
                guard let self else { return }
                let current = await MainActor.run { endpoints() }
                for endpoint in current.prefix(MacMailSyncDefaults.hostsPerPass) {
                    _ = await self.sync(endpoint)
                }
            }
        }
    }

    /// An agent here just sent to `host`: sync that host soon rather than at the next tick.
    nonisolated func kick(host: HostID) {
        Task { await self.syncSoon(host) }
    }

    private func syncSoon(_ host: HostID) async {
        try? await Task.sleep(nanoseconds: UInt64(MacMailSyncDefaults.kickDelay * 1_000_000_000))
        guard let provider = endpointsProvider else { return }
        let all = await MainActor.run { provider() }
        let known = peered.first { $0.value == host }?.key
        // A host already peered is matched by its controller id; otherwise every configured host
        // is a candidate, since the id is only learned by asking.
        for endpoint in all where known == nil || endpoint.hostID == known {
            _ = await sync(endpoint)
        }
    }

    // MARK: - One Pass

    /// Peers with one host if needed, then pushes and pulls bounded batches.
    @discardableResult
    func sync(_ endpoint: Endpoint) async -> Report {
        var report = Report()
        guard !inFlight.contains(endpoint.hostID) else { return report }
        inFlight.insert(endpoint.hostID)
        defer { inFlight.remove(endpoint.hostID) }
        do {
            let store = try await mailbox.controllerStore()
            let local = try await mailbox.host()
            let remote = try await peer(endpoint, store: store, local: local)

            for _ in 0..<MacMailSyncDefaults.exchangesPerDirection {
                let batch = try await store.outboundBatch(for: remote)
                guard !batch.envelopes.isEmpty else { break }
                let response = try await exchange(
                    endpoint, MailRPCRequest(push: MailPush(from: local.id, messages: batch.envelopes)),
                    local: local.id, expecting: remote
                )
                try await store.applyPushResults(response.results ?? [], peer: remote)
                report.pushed += (response.results ?? []).filter { $0.outcome != .refused }.count
            }

            for _ in 0..<MacMailSyncDefaults.exchangesPerDirection {
                guard let current = try await store.mailPeer(remote) else { break }
                let response = try await exchange(
                    endpoint,
                    MailRPCRequest(pull: MailPull(after: current.pullCursor, refused: current.pendingRefusals)),
                    local: local.id, expecting: remote
                )
                let messages = response.messages ?? []
                try await store.acceptPulled(messages, from: remote, next: response.next ?? current.pullCursor)
                report.pulled += messages.count
                for message in messages where message.recipient.host == local.id && message.recipient.kind == .session {
                    report.recipients.insert(SessionID(message.recipient.id))
                }
                guard !messages.isEmpty else { break }
            }
        } catch {
            report.issues.append(Self.describe(error))
            // A failure may mean the host was rebuilt; learn its identity again next time.
            peered[endpoint.hostID] = nil
        }
        if !report.recipients.isEmpty {
            let recipients = report.recipients
            await MainActor.run {
                for sessionID in recipients { MacMailDelivery.shared.arrived(for: sessionID, priority: .normal) }
            }
        }
        if !report.issues.isEmpty {
            EventLog.shared.record(.mcp, "Mail sync with a remote host failed", [
                "host": endpoint.name,
                "issue": report.issues.joined(separator: "; ")
            ])
        }
        return report
    }

    // MARK: - Peering

    private func peer(_ endpoint: Endpoint, store: ControllerStore, local: ControllerHost) async throws -> HostID {
        if let known = peered[endpoint.hostID] { return known }
        let remote: ControllerHost = try await ownerRPC(endpoint, "host", [])
        guard remote.id != local.id else { throw SyncError.wrongHost }

        let existing = try await store.mailPeer(remote.id)
        if existing == nil || existing?.name != remote.name {
            _ = try await store.setMailPeer(
                host: remote.id, expectedRevision: existing?.revision ?? 0, name: String(remote.name.prefix(64)),
                transport: nil, push: false, pull: false
            )
        }

        let theirs: ControllerPage<MailPeer> = try await ownerRPC(endpoint, "mail-peers", [])
        let mine = theirs.items.first { $0.host == local.id }
        if mine == nil || mine?.name != local.name {
            let settings = #"{"transport":null,"push":false,"pull":false}"#
            let _: MailPeer = try await ownerRPC(endpoint, "mail-peer-set", [
                .init(value: local.id.description),
                .init(value: String(mine?.revision ?? 0)),
                .init(value: String(local.name.prefix(64))),
                .init(text: settings)
            ])
        }
        peered[endpoint.hostID] = remote.id
        return remote.id
    }

    // MARK: - Transport

    private struct OwnerRequest: Encodable {
        struct Argument: Encodable {
            var value: String? = nil
            var text: String? = nil
        }
        let command: String
        let arguments: [Argument]
    }

    private func ownerRPC<T: Decodable>(_ endpoint: Endpoint, _ command: String, _ arguments: [OwnerRequest.Argument]) async throws -> T {
        let input = try JSONEncoder().encode(OwnerRequest(command: command, arguments: arguments))
        let output = try await run(endpoint, subcommand: "owner-rpc", input: input)
        return try Self.decodeLastLine(T.self, from: output)
    }

    private func exchange(_ endpoint: Endpoint, _ request: MailRPCRequest, local: HostID, expecting host: HostID) async throws
        -> MailRPCResponse {
        let input = try JSONEncoder().encode(request)
        guard input.count <= MailTransportLimits.requestBytes else { throw SyncError.transport("request_too_large") }
        let output = try await run(endpoint, subcommand: "mail-rpc --peer \(local.description)", input: input)
        let response = try Self.decodeLastLine(MailRPCResponse.self, from: output)
        guard response.host == host else { throw SyncError.wrongHost }
        return response
    }

    /// Blocking SSH, so it runs on a detached task rather than on this actor's executor.
    private func run(_ endpoint: Endpoint, subcommand: String, input: Data) async throws -> String {
        let command = Self.quoted(endpoint.executable) + " --database " + Self.quoted(endpoint.database) + " " + subcommand
        let runner = runner
        let destination = endpoint.destination
        let result = try await Task.detached(priority: .utility) {
            try runner.run(
                on: destination, command: command, input: .data(input),
                extraOptions: [], timeout: MacMailSyncDefaults.timeout
            )
        }.value
        guard result.succeeded else { throw SyncError.transport(String(result.output.suffix(256))) }
        return result.output
    }

    /// The controller prints one JSON line; anything before it (an SSH banner on the merged
    /// stream) is ignored rather than failing the decode.
    static func decodeLastLine<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let value = try? JSONDecoder().decode(T.self, from: Data(line.utf8)) else {
            throw SyncError.invalidResponse
        }
        return value
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as SyncError:
            switch error {
            case .transport(let detail): return "transport: \(detail)"
            case .invalidResponse: return "invalid_response"
            case .wrongHost: return "mail_peer_identity"
            }
        case let error as ControllerError: return error.description
        default: return MacMailbox.describe(error)
        }
    }
}

// MARK: - Live Endpoints

extension MacMailSync {
    /// The hosts whose controller paths are saved and whose tunnel is up right now.
    @MainActor
    static func liveEndpoints() -> [Endpoint] {
        RemoteHostStore.shared.hosts.compactMap { host -> Endpoint? in
            guard let executable = host.controllerExecutable, let database = host.controllerDatabase,
                  RemoteAutomationEndpoint(hostID: host.id, executable: executable, database: database).isValid,
                  host.isValid,
                  RemoteExecutionHosts.shared.tunnelIsRunning(for: host.sshDestination) else { return nil }
            return Endpoint(hostID: host.id, name: host.displayName, destination: host.sshDestination,
                            executable: executable, database: database)
        }
    }
}

extension RemoteAutomationEndpoint {
    var isValid: Bool { (try? validate()) != nil }
}

// MARK: - Defaults

enum MacMailSyncDefaults {
    /// While connected, a host is synced this often.
    static let interval: TimeInterval = 15
    /// After a send, the destination is synced this soon — long enough to coalesce a burst.
    static let kickDelay: TimeInterval = 1
    static let exchangesPerDirection = 4
    /// Hosts per periodic pass, as the controller's own sync bounds its peers per tick.
    static let hostsPerPass = 8
    static let timeout: TimeInterval = 30
}
