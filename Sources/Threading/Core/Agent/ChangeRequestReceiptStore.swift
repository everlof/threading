import Foundation

/// Durable evidence for a publish transition. The UI shows the immediate notice; this bounded
/// ledger survives it and records which repository, branch, credential source and URL were involved.
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
    let credentialSource: ChangeRequestCredentialSource?

    init(
        date: Date,
        action: Action,
        repository: String,
        branch: String,
        url: URL?,
        credentialSource: ChangeRequestCredentialSource?
    ) {
        self.date = date
        self.action = action
        self.repository = repository
        self.branch = branch
        self.url = url
        self.credentialSource = credentialSource
    }

    private enum CodingKeys: String, CodingKey {
        case date, action, repository, branch, url, credentialSource
        case legacyCredentialTier = "credentialTier"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        action = try container.decode(Action.self, forKey: .action)
        repository = try container.decode(String.self, forKey: .repository)
        branch = try container.decode(String.self, forKey: .branch)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        credentialSource = try container.decodeIfPresent(
            ChangeRequestCredentialSource.self,
            forKey: .credentialSource
        ) ?? container.decodeIfPresent(
            ChangeRequestCredentialSource.self,
            forKey: .legacyCredentialTier
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(action, forKey: .action)
        try container.encode(repository, forKey: .repository)
        try container.encode(branch, forKey: .branch)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(credentialSource, forKey: .credentialSource)
    }
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
