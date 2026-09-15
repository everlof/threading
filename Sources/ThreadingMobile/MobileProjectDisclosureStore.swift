import Combine
import CryptoKit
import Foundation

/// Phone-local navigation preferences. Each disclosure is one scalar preference, so toggling
/// a project never decodes or rewrites an archive proportional to the number of chats/projects.
@MainActor
final class MobileProjectDisclosureStore: ObservableObject {
    private static let keyPrefix = "threading.mobile.project-collapsed.v1."
    @Published private var changeGeneration: UInt64 = 0
    private let defaults: UserDefaults
    private struct PreviewIdentity: Hashable {
        let hostID: String?
        let projectKey: String
    }
    private var previewStages: [PreviewIdentity: MobileProjectChatPreview.Stage] = [:]

    func chatPreviewStage(hostID: String?, projectKey: String) -> MobileProjectChatPreview.Stage {
        previewStages[PreviewIdentity(hostID: hostID, projectKey: projectKey)] ?? .compact
    }

    func setChatPreviewStage(_ stage: MobileProjectChatPreview.Stage, hostID: String?, projectKey: String) {
        let identity = PreviewIdentity(hostID: hostID, projectKey: projectKey)
        guard chatPreviewStage(hostID: hostID, projectKey: projectKey) != stage else { return }
        if stage == .compact { previewStages.removeValue(forKey: identity) }
        else { previewStages[identity] = stage }
        changeGeneration &+= 1
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isExpanded(hostID: String?, projectKey: String) -> Bool {
        guard let hostID else { return true }
        return !(defaults.object(forKey: key(hostID: hostID, projectKey: projectKey)) as? Bool ?? false)
    }

    @discardableResult
    func setExpanded(_ expanded: Bool, hostID: String?, projectKey: String) -> Bool {
        guard let hostID else { return false }
        let preferenceKey = key(hostID: hostID, projectKey: projectKey)
        // Preserve an unreadable value rather than silently replacing it with a default.
        if let value = defaults.object(forKey: preferenceKey), !(value is Bool) { return false }
        guard isExpanded(hostID: hostID, projectKey: projectKey) != expanded else { return true }
        defaults.set(!expanded, forKey: preferenceKey)
        guard (defaults.object(forKey: preferenceKey) as? Bool) == !expanded else { return false }
        changeGeneration &+= 1
        return true
    }

    /// Stable IDs survive a project rename; older hosts can only identify a group by name.
    nonisolated static func projectKey(id: String?, name: String) -> String {
        if let id { return "id:\(id)" }
        return "name:\(name)"
    }

    private func key(hostID: String, projectKey: String) -> String {
        // Length framing prevents ambiguous host/project pairs. The digest keeps keys bounded
        // and avoids putting project names in the defaults directory's key listing.
        let identity = "\(hostID.utf8.count):\(hostID)\(projectKey)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return Self.keyPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}
