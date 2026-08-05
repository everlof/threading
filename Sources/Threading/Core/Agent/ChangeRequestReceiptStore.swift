import Foundation

/// Durable evidence for a publish transition. The UI shows the immediate notice; this bounded
/// ledger survives it and records which repository, branch, account tier and URL were involved.
struct ChangeRequestReceipt: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case pushed
        case createdDraft
        case createdReady
    }

    let date: Date
    let action: Action
    let repository: String
    let branch: String
    let url: URL?
    let credentialTier: GitHubCredential.Tier?
}

@MainActor
final class ChangeRequestReceiptStore {
    static let shared = ChangeRequestReceiptStore()

    private enum Defaults {
        static let key = "changeRequest.publishReceipts.v1"
        static let limit = 100
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var receipts: [ChangeRequestReceipt] {
        guard let data = userDefaults.data(forKey: Defaults.key) else { return [] }
        return (try? JSONDecoder().decode([ChangeRequestReceipt].self, from: data)) ?? []
    }

    func append(_ receipt: ChangeRequestReceipt) {
        var records = receipts
        records.insert(receipt, at: 0)
        records = Array(records.prefix(Defaults.limit))
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: Defaults.key)
    }
}
