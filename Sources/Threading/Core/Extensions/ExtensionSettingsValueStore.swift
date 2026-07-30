import Foundation
import ThreadingExtensionKit

enum ExtensionSettingsValueStoreError: LocalizedError {
    case incompatibleFormat(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .incompatibleFormat(let version):
            return L10n.format(
                "Extension settings use unsupported format version %lld.",
                Int64(version)
            )
        case .unreadable(let message):
            return L10n.format("Extension settings could not be read: %@", message)
        }
    }
}

/// Host-owned persistence for extension-declared settings.
///
/// This directory is never granted to the child process, even when it has `storage.kv`.
/// Extensions receive only validated values through their launch environment and process
/// updates, so they cannot rewrite user choices behind the host-rendered controls.
final class ExtensionSettingsValueStore: @unchecked Sendable {
    private struct State: Codable {
        static let currentFormatVersion = 1

        var formatVersion = currentFormatVersion
        var values: [String: ExtensionJSONValue] = [:]
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func effectiveValues(
        extensionIdentifier: String,
        settings: ExtensionSettingsContribution
    ) throws -> [String: ExtensionJSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return settings.effectiveValues(
            overriding: try load(identifier: extensionIdentifier).values
        )
    }

    func set(
        _ value: ExtensionJSONValue,
        field: ExtensionSettingField,
        extensionIdentifier: String
    ) throws {
        guard field.control.accepts(value) else {
            throw ExtensionValidationError(issues: [
                .init(path: "values.\(field.id)", message: "does not match the declared control")
            ])
        }

        lock.lock()
        defer { lock.unlock() }
        var state = try load(identifier: extensionIdentifier)
        if value == field.control.defaultValue {
            state.values.removeValue(forKey: field.id)
        } else {
            state.values[field.id] = value
        }
        try save(state, identifier: extensionIdentifier)
    }

    func value(
        extensionIdentifier: String,
        field: ExtensionSettingField
    ) throws -> ExtensionJSONValue {
        lock.lock()
        defer { lock.unlock() }
        let persisted = try load(identifier: extensionIdentifier).values[field.id]
        guard let persisted, field.control.accepts(persisted) else {
            return field.control.defaultValue
        }
        return persisted
    }

    private func stateURL(identifier: String) -> URL {
        rootURL
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("values.json", isDirectory: false)
    }

    private func load(identifier: String) throws -> State {
        let url = stateURL(identifier: identifier)
        guard fileManager.fileExists(atPath: url.path) else { return State() }
        do {
            let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard state.formatVersion == State.currentFormatVersion else {
                throw ExtensionSettingsValueStoreError.incompatibleFormat(state.formatVersion)
            }
            return state
        } catch let error as ExtensionSettingsValueStoreError {
            throw error
        } catch {
            throw ExtensionSettingsValueStoreError.unreadable(error.localizedDescription)
        }
    }

    private func save(_ state: State, identifier: String) throws {
        let url = stateURL(identifier: identifier)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
