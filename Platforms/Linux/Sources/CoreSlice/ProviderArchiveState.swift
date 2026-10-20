import Foundation

// MARK: - Provider State

enum ProviderArchiveLocation: Equatable, Sendable {
    case active
    case archived
    case absent
    case ambiguous

    var archivedValue: Bool? {
        switch self {
        case .active: return false
        case .archived: return true
        case .absent, .ambiguous: return nil
        }
    }
}

/// One account's observable archive state, read from the two stores the provider itself moves
/// rollouts between. The filename carries the UUID; the transcript body is never opened.
struct ProviderArchiveSnapshot: Sendable {
    let locations: [TranscriptID: ProviderArchiveLocation]

    subscript(sessionID: TranscriptID) -> ProviderArchiveLocation {
        locations[sessionID] ?? .absent
    }

    static func read(
        account: AgentAccount,
        sessionIDs: Set<TranscriptID>,
        fileManager: FileManager = FileManager()
    ) -> ProviderArchiveSnapshot? {
        let root = URL(fileURLWithPath: account.configPath)
        guard let active = rolloutIDs(
            beneath: root.appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory),
            matching: sessionIDs,
            fileManager: fileManager
        ), let archived = rolloutIDs(
            beneath: root.appendingPathComponent(ProviderArchiveDefaults.archivedDirectory),
            matching: sessionIDs,
            fileManager: fileManager
        ) else { return nil }

        let locations = Dictionary(uniqueKeysWithValues: sessionIDs.map { sessionID in
            let location: ProviderArchiveLocation
            switch (active.contains(sessionID), archived.contains(sessionID)) {
            case (true, false): location = .active
            case (false, true): location = .archived
            case (false, false): location = .absent
            case (true, true): location = .ambiguous
            }
            return (sessionID, location)
        })
        return ProviderArchiveSnapshot(locations: locations)
    }

    private static func rolloutIDs(
        beneath root: URL,
        matching sessionIDs: Set<TranscriptID>,
        fileManager: FileManager
    ) -> Set<TranscriptID>? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else { return nil }

        // Transcript ids are UUIDs and therefore case-insensitive. Build this defensively rather
        // than using `uniqueKeysWithValues`: an imported record that differs only in UUID casing
        // must not be able to trap a launch-time reconciliation.
        var wanted: [String: TranscriptID] = [:]
        for sessionID in sessionIDs {
            wanted[sessionID.rawValue.lowercased()] = sessionID
        }
        var found = Set<TranscriptID>()
        for case let url as URL in enumerator {
            guard url.pathExtension == CodexDiscoveryDefaults.rolloutExtension,
                  url.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix)
            else { continue }

            let stem = url.deletingPathExtension().lastPathComponent
            let rawID = String(stem.suffix(ProviderArchiveDefaults.uuidLength)).lowercased()
            guard UUID(uuidString: rawID) != nil, let sessionID = wanted[rawID] else { continue }
            found.insert(sessionID)
        }
        return found
    }
}

// MARK: - Three-Way Reconciliation

struct ProviderArchiveReconciliationPlan: Equatable, Sendable {
    /// A provider command is needed only when its observed value is not the target.
    let providerTarget: Bool?
    /// The value both sides record once that command, if any, succeeds.
    let synchronizedState: Bool

    static func make(local: Bool, provider: Bool, lastSynchronized: Bool?) -> Self {
        let target: Bool
        if let lastSynchronized {
            if local == provider {
                target = local
            } else if local == lastSynchronized {
                // Only the provider moved since the last agreement: mirror its external action.
                target = provider
            } else {
                // Only Threading moved: carry its local action out to the provider.
                target = local
            }
        } else {
            // Migration has no chronological base. Archive is reversible; resurfacing a filed
            // conversation is surprising. Preserve either side's existing archive intent.
            target = local || provider
        }

        return Self(
            providerTarget: provider == target ? nil : target,
            synchronizedState: target
        )
    }
}

enum ProviderArchiveDefaults {
    static let archivedDirectory = "archived_sessions"
    static let uuidLength = 36
    static let maximumErrorLength = 800
    static let maximumCommandOutputBytes = 64 * 1024
    static let commandTimeout: TimeInterval = 30
    static let maximumConcurrentCommands = 4
}
