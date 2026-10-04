import Foundation

/// The bearer credentials an agent presents — an execution's and a session mailbox's — are kept
/// only as a SHA-256 digest. The plaintext exists once, in the value returned to the owner that
/// issues it (dispatch, or `mail-credential`), and from then on only in the agent's environment.
/// A copy of the store therefore authenticates nothing. The credentials are 244 random bits, so
/// an unsalted digest is not a guessing aid; the comparison is constant-time anyway.
enum ControllerCredential {
    static let digestPrefix = "sha256:"
    static let executionKind = "executionCredential"
    static let mailboxKind = "mailboxCredential"
    /// The `record` row that says every stored credential has been digested. No DDL: credentials
    /// are JSON records, and so is this marker.
    static let migrationKind = "storeMigration"
    static let migrationID = "credential-digest"
    private static let migrationBatch = 512

    static func mint() -> String { UUID().uuidString + UUID().uuidString }

    static func digest(_ plaintext: String) -> String {
        var hasher = SHA256()
        hasher.update(Array(plaintext.utf8))
        return digestPrefix + hasher.finalize()
    }

    /// A record that predates digesting (only possible before the open-time migration ran) is
    /// compared by its digest too, so both paths take the same time.
    static func matches(_ presented: String, stored: String?) -> Bool {
        let actual = Array(digest(presented).utf8)
        guard let stored else { return false }
        let expected = Array((stored.hasPrefix(digestPrefix) ? stored : digest(stored)).utf8)
        guard actual.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in actual.indices { difference |= actual[index] ^ expected[index] }
        return difference == 0
    }

    /// Digests every plaintext credential left by an older build, once per store. Runs at open,
    /// in one write transaction; the marker makes every later open a single indexed lookup.
    static func migrate(_ db: ControllerDatabase) throws {
        let marker = "SELECT 1 FROM record WHERE kind=? AND id=? LIMIT 1"
        let markerValues: [ControllerDatabase.Value] = [.text(migrationKind), .text(migrationID)]
        guard try db.rows(marker, markerValues).isEmpty else { return }
        try db.transaction {
            guard try db.rows(marker, markerValues).isEmpty else { return }
            var after: Int64 = 0
            while true {
                let rows = try db.rows("""
                    SELECT sequence,payload FROM record WHERE kind IN (?,?) AND sequence>? ORDER BY sequence LIMIT ?
                    """, [.text(executionKind), .text(mailboxKind), .integer(after), .integer(Int64(migrationBatch))])
                for row in rows {
                    let sequence = row.integers[0]
                    let stored = try JSONDecoder().decode(String.self, from: Data(try row.text(1).utf8))
                    guard !stored.hasPrefix(digestPrefix) else { continue }
                    let payload = String(decoding: try JSONEncoder().encode(digest(stored)), as: UTF8.self)
                    try db.run("UPDATE record SET payload=? WHERE sequence=?", [.text(payload), .integer(sequence)])
                }
                guard rows.count == migrationBatch, let last = rows.last?.integers[0] else { break }
                after = last
            }
            let at = String(decoding: try JSONEncoder().encode(ISO8601DateFormatter().string(from: Date())), as: UTF8.self)
            try db.run("INSERT INTO record(kind,id,payload) VALUES(?,?,?)",
                       [.text(migrationKind), .text(migrationID), .text(at)])
        }
    }
}

extension ControllerStore {
    /// Replaces a credential record with the digest of a fresh credential and returns the plaintext.
    func issueCredential(_ kind: String, _ id: String) throws -> String {
        let credential = ControllerCredential.mint()
        try db.run("""
            INSERT INTO record(kind,id,payload) VALUES(?,?,?)
            ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload
            """, [.text(kind), .text(id), .text(try encode(ControllerCredential.digest(credential)))])
        return credential
    }
    func credentialMatches(_ kind: String, _ id: String, presented: String) throws -> Bool {
        ControllerCredential.matches(presented, stored: try optional(kind, id))
    }
}
