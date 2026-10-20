import Foundation

/// The launch ledger is the crash marker. A start without a matching finish on an unclean launch
/// quarantines only that exact code build. A later successful explicit retry clears it.
enum NativePluginLoadQuarantine {
    struct Identity: Hashable, Sendable {
        let identifier: String
        let codeKey: String

        var ledgerDetail: [String: String] {
            ["plugin": identifier, "code": codeKey]
        }
    }

    static func blockedBuilds(in read: LaunchLedgerRead) -> Set<Identity> {
        guard case .valid(let history) = read else { return [] }
        var blocked = Set<Identity>()
        for launch in history.launches {
            var loading: Identity?
            for record in history.records where record.launch == launch.id
                && record.kind == .checkpoint {
                guard let identity = identity(in: record) else { continue }
                switch record.checkpoint {
                case StartupCheckpoint.nativePluginLoadStarted.rawValue:
                    loading = identity
                case StartupCheckpoint.nativePluginLoadFinished.rawValue:
                    if loading == identity { loading = nil }
                    blocked.remove(identity)
                default:
                    break
                }
            }
            if launch.endedUnexpectedly, let loading {
                blocked.insert(loading)
            }
        }
        return blocked
    }

    private static func identity(in record: LaunchLedgerRecord) -> Identity? {
        guard let identifier = record.detail?["plugin"],
              let codeKey = record.detail?["code"],
              !identifier.isEmpty, identifier.utf8.count <= 1_024,
              !codeKey.isEmpty, codeKey.utf8.count <= 512 else { return nil }
        return Identity(identifier: identifier, codeKey: codeKey)
    }
}
