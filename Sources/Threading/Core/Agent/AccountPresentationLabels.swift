import Foundation
import os
import ThreadingRemoteKit

/// Read-only projection for hot and nonisolated summaries. Never discovers logins on a row
/// configure. Replacing a provider snapshot drops disappeared accounts and bounds retention.
enum AccountPresentationLabels {
    private static let names = OSAllocatedUnfairLock(initialState: [AgentKind: [String: String]]())

    @MainActor
    static func publish(_ values: [AccountID: String], provider: AgentKind) {
        let store = AccountPreferencesStore.shared
        let defaults = store.defaultAppearance
        var labels: [String: String] = [:]
        for (id, name) in values {
            let own = store.appearance(for: id)
            for surface in AccountAppearanceSurface.allCases {
                let style = (defaults.shared ?? AccountAppearance())
                    .overlaying(defaults.surfaces?[surface.rawValue])
                    .overlaying(own.shared).overlaying(own.surfaces?[surface.rawValue])
                labels[key(id, surface)] = style.showName == false ? ""
                    : (style.useShortName == true ? own.shortName ?? name : name)
            }
        }
        names.withLock { $0[provider] = labels }
    }

    static func name(
        for id: AccountID,
        surface: AccountAppearanceSurface = .details,
        fallback: String? = nil
    ) -> String {
        names.withLock { $0[id.provider]?[key(id, surface)] } ?? fallback ?? id.handle.name
    }

    static func usageName(id: String, fallback: String?) -> String {
        guard let accountID = AccountID(rawValue: id) else { return fallback ?? id }
        return name(for: accountID, surface: .usage, fallback: fallback)
    }

    private static func key(_ id: AccountID, _ surface: AccountAppearanceSurface) -> String {
        id.rawValue + "|" + surface.rawValue
    }
}
