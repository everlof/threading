import Foundation

/// The remembered answers to "may this chat's agent link the log tap into my app".
///
/// A value type with no store and no UI, so the rule that matters — an answer belongs to one chat
/// and is never inherited by another — can be tested directly. `DeviceLogTapConsentController`
/// owns where it is persisted.
struct DeviceLogTapDecisions: Equatable {

    /// A chat list is externally sized, so the record is capped and oldest-first. Losing the
    /// oldest decision costs one extra question, never a wrong grant.
    static let capacity = 200

    private(set) var entries: [String]

    init(entries: [String] = []) {
        self.entries = entries
    }

    func decision(for sessionID: SessionID) -> Bool? {
        let prefix = "\(sessionID.rawValue.uuidString)="
        // Reversed: the newest answer for a chat wins if an older one somehow survived.
        for entry in entries.reversed() where entry.hasPrefix(prefix) {
            return entry.hasSuffix("=1")
        }
        return nil
    }

    mutating func remember(_ approved: Bool, for sessionID: SessionID) {
        let prefix = "\(sessionID.rawValue.uuidString)="
        entries.removeAll { $0.hasPrefix(prefix) }
        entries.append("\(prefix)\(approved ? 1 : 0)")
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}
