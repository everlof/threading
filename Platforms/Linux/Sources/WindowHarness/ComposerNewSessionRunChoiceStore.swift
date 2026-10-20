#if os(Linux)
import Foundation
@testable import CoreSlice

/// The model and effort last accepted by the opening composer for one exact login.
/// An absent value still means the provider chooses; a remembered default is never pinned.
struct ComposerNewSessionRunChoice: Codable, Sendable, Equatable {
    let model: String?
    let reasoningEffort: String?
}

/// Bounded, account-qualified composer memory. Call only on the catalogue worker, after the
/// session record has committed; no preference file work belongs to a chip or paint callback.
enum ComposerNewSessionRunChoiceStore {
    private struct Snapshot: Codable {
        var version = 1
        var accounts: [String: ComposerNewSessionRunChoice] = [:]
    }

    private static let maximumFileBytes = 1_048_576
    private static let maximumAccounts = 128
    private static let maximumAccountBytes = 512
    private static let maximumModelBytes = 512
    private static let maximumEffortBytes = 1_024
    private static var url: URL {
        AppDataLocations.supportDirectory.appendingPathComponent("new-session-run-choice.json")
    }

    static func choice(for account: AccountID) -> ComposerNewSessionRunChoice? {
        guard valid(account.rawValue, maximumBytes: maximumAccountBytes) else { return nil }
        return (try? read())?.accounts[account.rawValue]
    }

    @discardableResult
    static func set(_ choice: ComposerNewSessionRunChoice, for account: AccountID) -> Bool {
        guard valid(account.rawValue, maximumBytes: maximumAccountBytes),
              validOptional(choice.model, maximumBytes: maximumModelBytes),
              validOptional(choice.reasoningEffort, maximumBytes: maximumEffortBytes),
              var snapshot = try? read() else { return false }

        let remembered = choice.model == nil && choice.reasoningEffort == nil ? nil : choice
        guard remembered == nil || snapshot.accounts[account.rawValue] != nil
                || snapshot.accounts.count < maximumAccounts else { return false }
        snapshot.accounts[account.rawValue] = remembered
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= maximumFileBytes else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    private static func read() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
        let data = try BoundedFileReader.read(url, maximumBytes: maximumFileBytes)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1, snapshot.accounts.count <= maximumAccounts,
              snapshot.accounts.allSatisfy({ key, choice in
                  valid(key, maximumBytes: maximumAccountBytes)
                      && validOptional(choice.model, maximumBytes: maximumModelBytes)
                      && validOptional(choice.reasoningEffort, maximumBytes: maximumEffortBytes)
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }

    private static func validOptional(_ value: String?, maximumBytes: Int) -> Bool {
        value.map { valid($0, maximumBytes: maximumBytes) } ?? true
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
#endif
