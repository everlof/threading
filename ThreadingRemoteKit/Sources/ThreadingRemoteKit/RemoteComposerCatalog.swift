import Foundation

/// Stable ids for composer actions implemented by Threading rather than by an agent provider.
/// They live in the wire package so every client can distinguish an app-local action from a
/// provider command with the same spelling.
public enum RemoteComposerCatalog {
    public static let skillsCommandID = "threading.command:skills"
    public static let maximumPresentedSuggestions = 64
}

/// The provider-neutral leading-token query used by remote composers. Keeping matching in the
/// wire package makes the iPhone and future web/native clients agree on aliases, case folding,
/// ordering, and when ordinary prose stops being a command query.
public struct RemoteComposerCompletionQuery: Equatable, Sendable {
    public let trigger: String
    public let fragment: String

    public init(trigger: String, fragment: String) {
        self.trigger = trigger
        self.fragment = fragment
    }

    public static func parse(_ text: String) -> RemoteComposerCompletionQuery? {
        guard let first = text.first else { return nil }
        let trigger: String
        switch first {
        case "/": trigger = "slash"
        case "$": trigger = "dollar"
        default: return nil
        }

        let remainder = text.dropFirst()
        guard !remainder.contains(where: { $0.isWhitespace }) else { return nil }
        return RemoteComposerCompletionQuery(trigger: trigger, fragment: String(remainder))
    }

    public func suggestions(
        from capabilities: [RemoteComposerCapabilityDTO],
        matchingKind kind: String? = nil
    ) -> [RemoteComposerCapabilityDTO] {
        let needle = folded(fragment)
        let ranked = capabilities
            .filter { capability in
                guard capability.trigger == trigger else { return false }
                if let kind {
                    if kind == "skill" {
                        guard capability.canBrowseAsSkill else { return false }
                    } else {
                        guard capability.kind == kind else { return false }
                    }
                }
                guard !needle.isEmpty else { return true }
                return searchableValues(for: capability).contains {
                    folded($0).contains(needle)
                }
            }
            .sorted { lhs, rhs in
                let lhsScore = score(lhs, needle: needle)
                let rhsScore = score(rhs, needle: needle)
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
        return Array(ranked.prefix(RemoteComposerCatalog.maximumPresentedSuggestions))
    }

    private func searchableValues(for capability: RemoteComposerCapabilityDTO) -> [String] {
        [capability.name, capability.displayName, capability.description] + capability.aliases
    }

    private func score(_ capability: RemoteComposerCapabilityDTO, needle: String) -> Int {
        guard !needle.isEmpty else { return capability.kind == "command" ? 0 : 1 }
        let name = folded(capability.name)
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if capability.aliases.contains(where: { folded($0).hasPrefix(needle) }) { return 2 }
        if name.contains(needle) { return 3 }
        return 4
    }

    private func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
