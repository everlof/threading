import Foundation
import ThreadingRemoteKit

enum RemoteBrowserTunnelDefaults {
    static let maximumLeases = 16
    static let maximumConnectionsPerLease = 8
    static let lifetime: TimeInterval = 3_600
    static let unclaimedLifetime: TimeInterval = 30
    static let maximumRequestBytes = 1_024
    static let authorityCheckSeconds: UInt64 = 2
    static let chunkBytes = 32 * 1_024
    static let connectTimeout: TimeInterval = 15
    static let proxyUsername = "threading-preview"
}

/// A revocable capability for one loopback origin, never the owner's general API credential.
final class RemoteBrowserTunnelGrant: @unchecked Sendable {
    let token = UUID().uuidString + UUID().uuidString
    let sessionID: SessionID
    let tabID: UUID
    let authorization: RemoteAuthorization
    let origin: RemoteBrowserLocalOrigin
    let expiresAt: Date
    private let lock = NSLock()
    private var revoked = false
    private var claimed = false
    private let claimDeadline: Date
    private var connections: [UUID: @Sendable () -> Void] = [:]

    init(sessionID: SessionID, tabID: UUID, authorization: RemoteAuthorization,
         origin: RemoteBrowserLocalOrigin, now: Date = Date()) {
        self.sessionID = sessionID
        self.tabID = tabID
        self.authorization = authorization
        self.origin = origin
        expiresAt = now.addingTimeInterval(RemoteBrowserTunnelDefaults.lifetime)
        claimDeadline = now.addingTimeInterval(RemoteBrowserTunnelDefaults.unclaimedLifetime)
    }

    var isValid: Bool { lock.withLock { validAt(Date()) } }

    private func validAt(_ date: Date) -> Bool {
        !revoked && date < expiresAt && (claimed || date < claimDeadline)
    }

    func admit(onRevoke: @escaping @Sendable () -> Void) -> UUID? {
        lock.withLock {
            guard validAt(Date()),
                  connections.count < RemoteBrowserTunnelDefaults.maximumConnectionsPerLease else { return nil }
            claimed = true
            let id = UUID()
            connections[id] = onRevoke
            return id
        }
    }

    func release(_ id: UUID) { _ = lock.withLock { connections.removeValue(forKey: id) } }

    func revoke() {
        let callbacks = lock.withLock {
            revoked = true
            let callbacks = Array(connections.values)
            connections.removeAll()
            return callbacks
        }
        callbacks.forEach { $0() }
    }
}

@MainActor
final class RemoteBrowserTunnelStore {
    private var grants: [String: RemoteBrowserTunnelGrant] = [:]
    private var monitor: Task<Void, Never>?

    nonisolated init() {}

    func issue(sessionID: SessionID, tabID: UUID, authorization: RemoteAuthorization,
               url: URL, authorizer: any RemoteAuthorizing) -> RemoteBrowserTunnelDTO? {
        guard let origin = RemoteBrowserLocalOrigin(url: url) else { return nil }
        prune(authorizer: authorizer)
        guard grants.count < RemoteBrowserTunnelDefaults.maximumLeases else { return nil }
        let grant = RemoteBrowserTunnelGrant(
            sessionID: sessionID, tabID: tabID, authorization: authorization, origin: origin
        )
        grants[grant.token] = grant
        if monitor == nil {
            monitor = Task { [weak self, weak authorizer] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: RemoteBrowserTunnelDefaults.authorityCheckSeconds * 1_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    guard let authorizer else { self.removeAll(); return }
                    self.prune(authorizer: authorizer)
                    if self.grants.isEmpty { self.monitor = nil; return }
                }
            }
        }
        return RemoteBrowserTunnelDTO(url: url, token: grant.token, expiresAt: grant.expiresAt)
    }

    func resolve(token: String, authority: String, authorizer: any RemoteAuthorizing) -> RemoteBrowserTunnelGrant? {
        guard let grant = grants[token], grant.isValid,
              grant.origin.accepts(authority: authority), authorizer.isCurrent(grant.authorization),
              RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: grant.sessionID))
        else { return nil }
        return grant
    }

    func close(token: String, sessionID: SessionID, authorization: RemoteAuthorization) {
        guard let grant = grants[token], grant.sessionID == sessionID,
              grant.authorization == authorization else { return }
        grants.removeValue(forKey: token)?.revoke()
    }

    func removeAll() {
        monitor?.cancel()
        monitor = nil
        let old = grants.values
        grants.removeAll()
        old.forEach { $0.revoke() }
    }

    private func prune(authorizer: any RemoteAuthorizing) {
        let expired = grants.values.filter {
            !$0.isValid || !authorizer.isCurrent($0.authorization) ||
                !RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: $0.sessionID))
        }
        for grant in expired { grants.removeValue(forKey: grant.token)?.revoke() }
    }

    nonisolated static func token(from header: String?) -> String? {
        guard let header, header.hasPrefix("Basic "), header.utf8.count < 256,
              let data = Data(base64Encoded: String(header.dropFirst(6))),
              let value = String(data: data, encoding: .utf8),
              value.hasPrefix(RemoteBrowserTunnelDefaults.proxyUsername + ":") else { return nil }
        return String(value.dropFirst(RemoteBrowserTunnelDefaults.proxyUsername.count + 1))
    }
}
