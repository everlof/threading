import Foundation

/// The remembered answers to "may this plugin run inside Threading".
///
/// A value type with no store and no UI, so the rules that matter can be tested directly. The
/// rules are:
///
/// **An approval is for a build, not for a name.** It records the code directory hash alongside the
/// identifier, so a rebuilt, updated or *substituted* bundle at the same path under the same
/// identifier is a different identity and has to be asked about again. Recording the name alone
/// would mean anything that could write that folder inherits a grant the user gave to something
/// else — and this tier maps code into Threading's own process, with its files and its TCC grants.
///
/// **A refusal is remembered too.** Asking again every launch is how a user learns to click through
/// the question that protects them.
struct NativePluginApprovals: Equatable {

    /// Externally sized — a plugins folder is whatever the user puts in it — so the record is
    /// capped and oldest-first. Losing the oldest costs one extra question, never a wrong grant.
    static let capacity = 100

    private(set) var entries: [String]

    init(entries: [String] = []) {
        self.entries = entries
    }

    /// `identifier|fingerprint=1`. Two strings rather than the loader's identity type, because a
    /// policy about what the user agreed to is not a thing that should know the plugin SDK — the
    /// module boundary says so, and it is right: this stays testable without loading anything.
    private static func key(identifier: String, fingerprint: String) -> String {
        "\(identifier)|\(fingerprint)="
    }

    func decision(identifier: String, fingerprint: String) -> Bool? {
        let prefix = Self.key(identifier: identifier, fingerprint: fingerprint)
        for entry in entries.reversed() where entry.hasPrefix(prefix) {
            return entry.hasSuffix("=1")
        }
        return nil
    }

    mutating func remember(_ approved: Bool, identifier: String, fingerprint: String) {
        let prefix = Self.key(identifier: identifier, fingerprint: fingerprint)
        entries.removeAll { $0.hasPrefix(prefix) }
        entries.append("\(prefix)\(approved ? 1 : 0)")
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Forgets every answer about an identifier, whatever build it was.
    ///
    /// What "revoke" means: the user is withdrawing trust from the plugin, not from one build of
    /// it, so a reinstall must ask rather than find an old approval for the same bytes.
    mutating func revoke(identifier: String) {
        entries.removeAll { $0.hasPrefix("\(identifier)|") }
    }
}
