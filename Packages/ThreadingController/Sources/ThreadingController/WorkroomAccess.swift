import Foundation

// How a person outside this Mac proves who they are to the Linked Workrooms portal. The owner
// issues a single-use invitation; redeeming it in a browser mints a device session. Both are
// 256-bit random tokens kept only as SHA-256 digests — the record id is the digest, so a lookup
// is one unique-index read and a copy of the store authenticates nothing. Every request resolves
// the device again, so removing a person or revoking a device takes effect on the next click.

public enum WorkroomInvitationState: String, Codable, Sendable { case pending, redeemed, revoked }

public struct WorkroomInvitation: Codable, Equatable, Sendable {
    /// A public handle for the owner's list; never a credential.
    public let id: UUID
    public let person: WorkroomPersonID
    public let issuedAt: String
    public let expiresAt: String
    public internal(set) var state: WorkroomInvitationState
    public internal(set) var redeemedAt: String?
    public internal(set) var deviceID: UUID?
}

public enum WorkroomDeviceState: String, Codable, Sendable { case active, revoked }

public struct WorkroomDevice: Codable, Equatable, Sendable {
    /// A public handle for the owner's list and for revocation; never a credential.
    public let id: UUID
    public let person: WorkroomPersonID
    /// What the browser said it was, cut short. Shown so a stolen redemption is noticeable.
    public let label: String
    public let createdAt: String
    public let expiresAt: String
    public internal(set) var lastSeenAt: String
    public internal(set) var state: WorkroomDeviceState
}

/// An authenticated portal visitor, resolved from a device token for one request.
public struct WorkroomParticipant: Equatable, Sendable {
    public let person: WorkroomPerson
    public let device: WorkroomDevice
}

/// Token minting and the derived per-device form token. Portable: no CryptoKit.
public enum WorkroomToken {
    /// 32 bytes from the system CSPRNG, base64url without padding (43 characters).
    public static func mint() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Only tokens of the minted shape are looked up, so arbitrary input never reaches SQL.
    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 43 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func digest(_ token: String) -> String { ControllerCredential.digest(token) }

    /// The form token for a device session: derived from the session token, which only that
    /// browser's cookie holds, so it needs no storage and cannot be computed by another site.
    public static func formToken(for sessionToken: String) -> String {
        String(ControllerCredential.digest("workroom-form:" + sessionToken).dropFirst(ControllerCredential.digestPrefix.count).prefix(43))
    }

    /// Constant-time comparison for a presented form token.
    public static func equal(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

extension ControllerStore {
    // MARK: - Owner

    /// A fresh single-use link for `person`. Any invitation of theirs still pending is revoked
    /// in the same transaction, so only the newest copied link works.
    public func issueWorkroomInvitation(person: WorkroomPersonID,
                                        lifetime: TimeInterval = WorkroomLimits.invitationLifetime) throws -> (WorkroomInvitation, String) {
        guard lifetime > 0, lifetime <= WorkroomLimits.invitationLifetime else { throw ControllerError.invalidInput("lifetime") }
        return try db.transaction {
            let value: WorkroomPerson = try required("workroomPerson", person.description)
            guard value.state == .active else { throw ControllerError.notFound }
            try revokePendingInvitations(person: person)
            let token = WorkroomToken.mint()
            let invitation = WorkroomInvitation(id: UUID(), person: person, issuedAt: Self.now(),
                                                expiresAt: Self.timestamp(Date().addingTimeInterval(lifetime)),
                                                state: .pending, redeemedAt: nil, deviceID: nil)
            try insert("workroomInvitation", WorkroomToken.digest(token), parent: person.description,
                       state: invitation.state.rawValue, value: invitation)
            try event("workroom.invited", person.description)
            return (invitation, token)
        }
    }

    public func workroomDevices(person: WorkroomPersonID) throws -> [WorkroomDevice] {
        try db.rows("""
            SELECT payload FROM record INDEXED BY record_ready
            WHERE kind='workroomDevice' AND parent=? AND state='active' ORDER BY sequence DESC LIMIT ?
            """, [.text(person.description), .integer(Int64(WorkroomLimits.devicesPerPerson))]).map { try decode($0.text(0)) }
    }

    /// The newest invitation of this person, whatever its state: what the owner's list shows.
    public func latestWorkroomInvitation(person: WorkroomPersonID) throws -> WorkroomInvitation? {
        try db.rows("""
            SELECT payload FROM record INDEXED BY record_parent
            WHERE kind='workroomInvitation' AND parent=? ORDER BY sequence DESC LIMIT 1
            """, [.text(person.description)]).first.map { try decode($0.text(0)) }
    }

    public func revokeWorkroomDevice(person: WorkroomPersonID, deviceID: UUID) throws {
        try db.transaction {
            let rows = try db.rows("""
                SELECT id,payload FROM record INDEXED BY record_ready
                WHERE kind='workroomDevice' AND parent=? AND state='active' ORDER BY sequence LIMIT 100
                """, [.text(person.description)])
            for row in rows {
                var device: WorkroomDevice = try decode(row.text(1))
                guard device.id == deviceID else { continue }
                device.state = .revoked
                try update("workroomDevice", try row.text(0), state: device.state.rawValue, value: device)
                try event("workroom.device_revoked", person.description)
            }
        }
    }

    // MARK: - Portal

    /// Redeems a single-use invitation. Two browsers racing for one link serialize on the write
    /// lock; the second finds it redeemed. Returns the new device session's token once.
    public func redeemWorkroomInvitation(_ token: String, deviceLabel: String,
                                         now: Date = Date()) throws -> (WorkroomParticipant, String) {
        guard WorkroomToken.isWellFormed(token) else { throw ControllerError.notFound }
        let label = String(deviceLabel.filter { !$0.isNewline && $0 != "\0" }.prefix(120))
        return try db.transaction {
            let id = WorkroomToken.digest(token)
            guard var invitation: WorkroomInvitation = try optional("workroomInvitation", id),
                  invitation.state == .pending, let expiry = Self.date(invitation.expiresAt), now < expiry else {
                throw ControllerError.notFound
            }
            let person: WorkroomPerson = try required("workroomPerson", invitation.person.description)
            guard person.state == .active else { throw ControllerError.notFound }
            try retireOldestDevices(person: person.id)
            let sessionToken = WorkroomToken.mint()
            let device = WorkroomDevice(id: UUID(), person: person.id, label: label.isEmpty ? "Browser" : label,
                                        createdAt: Self.timestamp(now),
                                        expiresAt: Self.timestamp(now.addingTimeInterval(WorkroomLimits.deviceLifetime)),
                                        lastSeenAt: Self.timestamp(now), state: .active)
            try insert("workroomDevice", WorkroomToken.digest(sessionToken), parent: person.id.description,
                       state: device.state.rawValue, value: device)
            invitation.state = .redeemed
            invitation.redeemedAt = Self.timestamp(now)
            invitation.deviceID = device.id
            try update("workroomInvitation", id, state: invitation.state.rawValue, value: invitation)
            try event("workroom.redeemed", person.id.description)
            return (WorkroomParticipant(person: person, device: device), sessionToken)
        }
    }

    /// The person behind a device token, or nil for anything unknown, revoked, expired or
    /// belonging to a removed person. Writes only to record that the device was seen, and at
    /// most every `deviceTouchInterval`.
    public func workroomParticipant(sessionToken: String, now: Date = Date()) throws -> WorkroomParticipant? {
        guard WorkroomToken.isWellFormed(sessionToken) else { return nil }
        let id = WorkroomToken.digest(sessionToken)
        guard var device: WorkroomDevice = try optional("workroomDevice", id), device.state == .active,
              let expiry = Self.date(device.expiresAt), now < expiry else { return nil }
        let person: WorkroomPerson = try required("workroomPerson", device.person.description)
        guard person.state == .active else { return nil }
        if let seen = Self.date(device.lastSeenAt), now.timeIntervalSince(seen) >= WorkroomLimits.deviceTouchInterval {
            device.lastSeenAt = Self.timestamp(now)
            try db.transaction {
                guard let current: WorkroomDevice = try optional("workroomDevice", id), current.state == .active else { return }
                try update("workroomDevice", id, state: device.state.rawValue, value: device)
            }
        }
        return WorkroomParticipant(person: person, device: device)
    }

    /// A person's own language choice in the portal. It sticks against agents.
    public func participantSetLanguage(person: WorkroomPersonID, language: String) throws -> WorkroomPerson {
        try setWorkroomPersonLanguage(person, language: language, source: .person)
    }

    // MARK: - Helpers

    func revokeWorkroomCredentials(person: WorkroomPersonID) throws {
        try revokePendingInvitations(person: person)
        while true {
            let rows = try db.rows("""
                SELECT id,payload FROM record INDEXED BY record_ready
                WHERE kind='workroomDevice' AND parent=? AND state='active' ORDER BY sequence LIMIT 100
                """, [.text(person.description)])
            for row in rows {
                var device: WorkroomDevice = try decode(row.text(1))
                device.state = .revoked
                try update("workroomDevice", try row.text(0), state: device.state.rawValue, value: device)
            }
            guard rows.count == 100 else { return }
        }
    }

    private func revokePendingInvitations(person: WorkroomPersonID) throws {
        while true {
            let rows = try db.rows("""
                SELECT id,payload FROM record INDEXED BY record_ready
                WHERE kind='workroomInvitation' AND parent=? AND state='pending' ORDER BY sequence LIMIT 100
                """, [.text(person.description)])
            for row in rows {
                var invitation: WorkroomInvitation = try decode(row.text(1))
                invitation.state = .revoked
                try update("workroomInvitation", try row.text(0), state: invitation.state.rawValue, value: invitation)
            }
            guard rows.count == 100 else { return }
        }
    }

    /// A person keeps at most `devicesPerPerson` live sessions; a new one retires the oldest.
    private func retireOldestDevices(person: WorkroomPersonID) throws {
        let rows = try db.rows("""
            SELECT id,payload FROM record INDEXED BY record_ready
            WHERE kind='workroomDevice' AND parent=? AND state='active' ORDER BY sequence LIMIT 100
            """, [.text(person.description)])
        guard rows.count >= WorkroomLimits.devicesPerPerson else { return }
        for row in rows.prefix(rows.count - WorkroomLimits.devicesPerPerson + 1) {
            var device: WorkroomDevice = try decode(row.text(1))
            device.state = .revoked
            try update("workroomDevice", try row.text(0), state: device.state.rawValue, value: device)
        }
    }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
