#if os(Linux)
import Foundation
@testable import CoreSlice

/// The Linux host's durable, account-qualified visibility choices for the shared model picker.
/// File work runs only on ComposerModelCatalogLoader's serial worker; the UI keeps bounded values.
enum ComposerModelVisibilityStore {
    enum Change: Sendable {
        case hide(String)
        case showAll
    }

    private struct Snapshot: Codable {
        var version = 1
        var accounts: [String: [String]] = [:]
    }

    private static let maximumFileBytes = 1_048_576
    private static let maximumAccounts = 128
    private static let maximumHiddenModels = 256
    private static let maximumIdentifierBytes = 512
    private static var url: URL {
        AppDataLocations.supportDirectory.appendingPathComponent("model-visibility.json")
    }

    static func hiddenModelIDs(for account: AccountID) -> Set<String> {
        (try? read().accounts[account.rawValue]).map(Set.init) ?? []
    }

    static func apply(_ change: Change, for account: AccountID) -> Set<String>? {
        guard account.rawValue.utf8.count <= maximumIdentifierBytes,
              var snapshot = try? read() else { return nil }
        var hidden = Set(snapshot.accounts[account.rawValue] ?? [])
        switch change {
        case .hide(let modelID):
            guard valid(modelID), hidden.contains(modelID) || hidden.count < maximumHiddenModels
            else { return nil }
            hidden.insert(modelID)
        case .showAll:
            hidden.removeAll()
        }
        if !hidden.isEmpty, snapshot.accounts[account.rawValue] == nil,
           snapshot.accounts.count >= maximumAccounts { return nil }
        snapshot.accounts[account.rawValue] = hidden.isEmpty ? nil : hidden.sorted()
        guard let encoded = try? JSONEncoder().encode(snapshot),
              encoded.count <= maximumFileBytes else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoded.write(to: url, options: .atomic)
            return hidden
        } catch { return nil }
    }

    private static func read() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
        let data = try BoundedFileReader.read(url, maximumBytes: maximumFileBytes)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1, snapshot.accounts.count <= maximumAccounts,
              snapshot.accounts.allSatisfy({ key, values in
                  key.utf8.count <= maximumIdentifierBytes
                      && values.count <= maximumHiddenModels && values.allSatisfy(valid)
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentifierBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
#endif
