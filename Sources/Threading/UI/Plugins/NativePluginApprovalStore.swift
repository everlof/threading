import Foundation
import ThreadingPluginKit

/// Where the answers live, and the one place that asks.
@MainActor
final class NativePluginApprovalStore {

    static let shared = NativePluginApprovalStore()

    private enum Defaults {
        static let key = "nativePluginApprovals"
    }

    /// A recorded choice, so it goes through `PreferenceStore` rather than `.standard` — a hosted
    /// test must not answer this question on the developer's behalf for their next launch.
    private var defaults: UserDefaults { PreferenceStore.shared }

    func decision(for identity: PluginLoader.PluginIdentity) -> Bool? {
        stored().decision(
            identifier: identity.bundleIdentifier,
            fingerprint: identity.cdHash
        )
    }

    func remember(_ approved: Bool, for identity: PluginLoader.PluginIdentity) {
        var approvals = stored()
        approvals.remember(
            approved,
            identifier: identity.bundleIdentifier,
            fingerprint: identity.cdHash
        )
        defaults.set(approvals.entries, forKey: Defaults.key)
    }

    func revoke(identifier: String) {
        var approvals = stored()
        approvals.revoke(identifier: identifier)
        defaults.set(approvals.entries, forKey: Defaults.key)
    }

    private func stored() -> NativePluginApprovals {
        NativePluginApprovals(entries: defaults.stringArray(forKey: Defaults.key) ?? [])
    }
}
