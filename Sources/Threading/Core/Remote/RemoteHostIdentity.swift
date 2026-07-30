import Foundation
import ThreadingRemoteKit

/// Stable, non-secret identity for this Mac in paired-client lists.
enum RemoteHostIdentity {
    private static let defaultsKey = "remoteAccessHostID"

    static var current: RemoteHostDTO {
        RemoteHostDTO(id: identifier, name: displayName)
    }

    private static var identifier: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let made = UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: defaultsKey)
        return made
    }

    private static var displayName: String {
        Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
    }
}
