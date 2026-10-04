import Foundation

public enum RemoteThemeSound {
    public static func slot(for kind: RemoteNotificationKind) -> String? {
        switch kind {
        case .turnCompleted: "sound.turnFinished"
        case .permissionRequest, .agentQuestion, .attentionRequest: "sound.needsAttention"
        default: nil
        }
    }

    public static func acceptsName(_ name: String) -> Bool {
        let prefix = "threading-theme-", suffix = ".caf"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        return RemoteThemeAsset.acceptsDigest(String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    public static func acceptsReceipts(_ names: [String: String]) -> Bool {
        names.count <= 2 && names.allSatisfy {
            ["sound.needsAttention", "sound.turnFinished"].contains($0.key) && acceptsName($0.value)
        }
    }
}
