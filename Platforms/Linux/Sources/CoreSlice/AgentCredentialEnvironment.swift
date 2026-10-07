import Foundation

/// Environment entries that carry a credential.
///
/// Every transport hands them to the child's environment; none writes them as words of its
/// command line, because the command line is what `EventLog` records at every launch, what the
/// `threading-ptyd` journal and the session info panel derive from, and what `ps` shows anyone on
/// this Mac. The values never appear in `description`, so interpolating a plan or a launch into a
/// log line cannot leak one.
struct AgentCredentialEnvironment: Equatable, Sendable {
    static let none = AgentCredentialEnvironment()

    private(set) var entries: [String: String] = [:]

    init() {}

    init(_ entries: [String: String]) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }
    var keys: [String] { entries.keys.sorted() }

    func applied(to environment: [String: String]) -> [String: String] {
        environment.merging(entries) { _, credential in credential }
    }

    /// The same, for the `KEY=value` list a PTY spawn takes. An existing entry for the key is
    /// replaced rather than duplicated, since which of two duplicates a child reads is up to it.
    func applied(toEntries environment: [String]) -> [String] {
        guard !entries.isEmpty else { return environment }
        let kept = environment.filter { entry in
            guard let separator = entry.firstIndex(of: "=") else { return true }
            return entries[String(entry[..<separator])] == nil
        }
        return kept + keys.map { "\($0)=\(entries[$0] ?? "")" }
    }
}

extension AgentCredentialEnvironment: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    var description: String { "AgentCredentialEnvironment(keys: \(keys), values: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["keys": keys]) }
}
