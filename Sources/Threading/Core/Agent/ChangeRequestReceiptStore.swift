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
        static let maximumRepositoryBytes = 1_024
        static let maximumBranchBytes = 4 * 1_024
        static let maximumURLBytes = 8 * 1_024
    }

    private enum ValidationError: Error {
        case invalidReceipt
    }

    private let persistence: RecoverableDefaultsStore<[ChangeRequestReceipt]>
    private var storedReceipts: [ChangeRequestReceipt]

    init(userDefaults: UserDefaults = .standard) {
        let persistence = RecoverableDefaultsStore<[ChangeRequestReceipt]>(
            defaults: userDefaults,
            key: Defaults.key,
            criticality: .primary,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.storedReceipts = persistence.load(
            defaultValue: [],
            validate: Self.validate
        ).value
    }

    var receipts: [ChangeRequestReceipt] {
        storedReceipts
    }

    @discardableResult
    func append(_ receipt: ChangeRequestReceipt) -> Bool {
        var records = storedReceipts
        records.insert(receipt, at: 0)
        records = Array(records.prefix(Defaults.limit))
        do {
            try Self.validate(records)
        } catch {
            ThreadingLogger.session.error("Refusing invalid change-request receipt")
            return false
        }
        guard persistence.save(records) else { return false }
        storedReceipts = records
        return true
    }

    private static func validate(_ receipts: [ChangeRequestReceipt]) throws {
        guard receipts.count <= Defaults.limit,
              receipts.allSatisfy({ receipt in
                  !receipt.repository.isEmpty
                      && receipt.repository.utf8.count <= Defaults.maximumRepositoryBytes
                      && !receipt.branch.isEmpty
                      && receipt.branch.utf8.count <= Defaults.maximumBranchBytes
                      && valid(url: receipt.url)
              }) else {
            throw ValidationError.invalidReceipt
        }
    }

    private static func valid(url: URL?) -> Bool {
        guard let url else { return true }
        return url.absoluteString.utf8.count <= Defaults.maximumURLBytes
            && url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }
}
