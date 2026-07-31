import Foundation

/// Moves unreadable `UserDefaults` state aside, so that a failed load cannot authorise its own
/// overwrite.
///
/// This is `ProjectStore`'s rule for `projects.json` — quarantine the bytes nobody could read,
/// and permit writes only if that succeeded — applied to the small stores that keep their state
/// as one encoded blob in `UserDefaults`. Those had exactly the shape the document store was
/// fixed for, and worse odds: a decode failure fell through to *defaults*, and the next save —
/// which for a settings store is any ordinary edit — wrote those defaults over bytes nobody had
/// read. One schema change was all it took to erase a user's keyboard bindings or their account
/// names, with nothing anywhere reporting it.
///
/// The distinction that matters is **missing** versus **unreadable**. Missing is the first run
/// and needs no ceremony. Unreadable is data that meant something to whoever wrote it, and the
/// only honest options are to keep it or to say out loud that it could not be kept.
enum DefaultsQuarantine {

    /// Where the unreadable copy of a key is kept.
    ///
    /// One slot per key rather than a timestamped series: a second failure means the first
    /// quarantine has already been superseded by whatever the user did next, and an unbounded
    /// pile of dead blobs in `UserDefaults` is its own small bug.
    static func quarantineKey(for key: String) -> String { "\(key).unreadable" }

    /// Copies the unreadable value aside and confirms the copy landed.
    ///
    /// Returns whether writes to the original key may now proceed. Read back rather than
    /// assumed, because "we saved a backup" is the one claim that must not be taken on trust
    /// immediately before overwriting the original.
    @discardableResult
    static func quarantine(
        _ data: Data,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Bool {
        let destination = quarantineKey(for: key)
        defaults.set(data, forKey: destination)

        guard defaults.data(forKey: destination) == data else {
            ThreadingLogger.session.error(
                """
                Could not quarantine unreadable \(key, privacy: .public); \
                refusing to overwrite it.
                """
            )
            return false
        }

        ThreadingLogger.session.error(
            """
            \(key, privacy: .public) could not be decoded; the previous value is kept at \
            \(destination, privacy: .public).
            """
        )
        return true
    }
}

// MARK: - Recoverable Stores

/// The product promise attached to persisted bytes.
///
/// The declaration is part of constructing a store so a new blob cannot accidentally inherit
/// cache semantics. Only a rebuildable cache may discard an unreadable value without first
/// preserving it.
enum PersistenceCriticality: String {
    case primary
    case userAuthored
    case preference
    case rebuildableCache
}

enum PersistenceRecoveryLocation: Equatable {
    case defaultsKey(String)
    case file(URL)
}

/// Missing, readable and unreadable are deliberately three different states.
enum RecoverableStoreLoadOutcome<Value> {
    case missing(defaultValue: Value)
    case loaded(Value)
    case unreadable(fallback: Value, recovery: PersistenceRecoveryLocation?)

    var value: Value {
        switch self {
        case .missing(let value), .loaded(let value), .unreadable(let value, _):
            return value
        }
    }
}

private struct RecoverableStoreEnvelopeProbe: Decodable {
    let formatVersion: Int
    let containsValue: Bool

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        containsValue = container.contains(.value)
    }
}

private struct RecoverableStoreEnvelope<Value: Codable>: Codable {
    static var currentVersion: Int { 1 }

    let formatVersion: Int
    let value: Value

    init(value: Value) {
        self.formatVersion = Self.currentVersion
        self.value = value
    }
}

private enum RecoverableStoreError: LocalizedError {
    case unsupportedVersion(found: Int, current: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found, let current):
            return "stored format version \(found) is newer than supported version \(current)"
        }
    }
}

/// A versioned `Codable` blob in `UserDefaults` with a verified recovery copy.
final class RecoverableDefaultsStore<Value: Codable> {

    private let defaults: UserDefaults
    private let key: String
    private let criticality: PersistenceCriticality
    private(set) var writesAllowed = true

    init(
        defaults: UserDefaults,
        key: String,
        criticality: PersistenceCriticality
    ) {
        self.defaults = defaults
        self.key = key
        self.criticality = criticality
    }

    func load(
        defaultValue: @autoclosure () -> Value,
        validate: (Value) throws -> Void = { _ in }
    ) -> RecoverableStoreLoadOutcome<Value> {
        guard let data = defaults.data(forKey: key) else {
            return .missing(defaultValue: defaultValue())
        }

        do {
            let value = try decode(data)
            try validate(value)
            return .loaded(value)
        } catch {
            let fallback = defaultValue()
            if criticality == .rebuildableCache {
                defaults.removeObject(forKey: key)
                return .unreadable(fallback: fallback, recovery: nil)
            }

            writesAllowed = DefaultsQuarantine.quarantine(data, forKey: key, in: defaults)
            let recovery = writesAllowed
                ? PersistenceRecoveryLocation.defaultsKey(
                    DefaultsQuarantine.quarantineKey(for: key)
                )
                : nil
            ThreadingLogger.session.error(
                """
                Could not load \(self.key, privacy: .public) as \
                \(self.criticality.rawValue, privacy: .public) state: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .unreadable(fallback: fallback, recovery: recovery)
        }
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        guard writesAllowed else {
            ThreadingLogger.session.error(
                "Refusing to save \(self.key, privacy: .public): recovery copy was not verified"
            )
            return false
        }

        do {
            let data = try JSONEncoder().encode(RecoverableStoreEnvelope(value: value))
            defaults.set(data, forKey: key)
            guard defaults.data(forKey: key) == data else {
                writesAllowed = false
                ThreadingLogger.session.error(
                    "Could not verify saved \(self.key, privacy: .public); later writes are disabled"
                )
                return false
            }
            return true
        } catch {
            ThreadingLogger.session.error(
                "Could not save \(self.key, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func decode(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        if let probe = try? decoder.decode(RecoverableStoreEnvelopeProbe.self, from: data),
           probe.containsValue {
            guard probe.formatVersion == RecoverableStoreEnvelope<Value>.currentVersion else {
                throw RecoverableStoreError.unsupportedVersion(
                    found: probe.formatVersion,
                    current: RecoverableStoreEnvelope<Value>.currentVersion
                )
            }
            return try decoder.decode(
                RecoverableStoreEnvelope<Value>.self,
                from: data
            ).value
        }

        // Data written before the envelope existed is version zero. It has one explicit
        // migration: decode the old payload itself, then write version one on the next edit.
        return try decoder.decode(Value.self, from: data)
    }
}

/// A versioned `Codable` file whose unreadable predecessor is moved aside before replacement.
final class RecoverableFileStore<Value: Codable> {

    private let url: URL
    private let fileManager: FileManager
    private let criticality: PersistenceCriticality
    private let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    private let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy
    private(set) var writesAllowed = true

    init(
        url: URL,
        fileManager: FileManager,
        criticality: PersistenceCriticality,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) {
        self.url = url
        self.fileManager = fileManager
        self.criticality = criticality
        self.dateEncodingStrategy = dateEncodingStrategy
        self.dateDecodingStrategy = dateDecodingStrategy
    }

    func load(
        defaultValue: @autoclosure () -> Value,
        validate: (Value) throws -> Void = { _ in }
    ) -> RecoverableStoreLoadOutcome<Value> {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing(defaultValue: defaultValue())
        }

        do {
            let value = try decode(Data(contentsOf: url))
            try validate(value)
            return .loaded(value)
        } catch {
            let fallback = defaultValue()
            if criticality == .rebuildableCache {
                try? fileManager.removeItem(at: url)
                return .unreadable(fallback: fallback, recovery: nil)
            }

            let recoveryURL = quarantine()
            writesAllowed = recoveryURL != nil
            ThreadingLogger.session.error(
                """
                Could not load \(self.url.lastPathComponent, privacy: .public) as \
                \(self.criticality.rawValue, privacy: .public) state: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .unreadable(
                fallback: fallback,
                recovery: recoveryURL.map(PersistenceRecoveryLocation.file)
            )
        }
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        guard writesAllowed else {
            ThreadingLogger.session.error(
                "Refusing to save \(self.url.lastPathComponent, privacy: .public): recovery copy was not verified"
            )
            return false
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = dateEncodingStrategy
            let data = try encoder.encode(RecoverableStoreEnvelope(value: value))
            try data.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == data else {
                writesAllowed = false
                ThreadingLogger.session.error(
                    "Could not verify saved \(self.url.lastPathComponent, privacy: .public); later writes are disabled"
                )
                return false
            }
            return true
        } catch {
            writesAllowed = false
            ThreadingLogger.session.error(
                "Could not save \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func decode(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        if let probe = try? decoder.decode(RecoverableStoreEnvelopeProbe.self, from: data),
           probe.containsValue {
            guard probe.formatVersion == RecoverableStoreEnvelope<Value>.currentVersion else {
                throw RecoverableStoreError.unsupportedVersion(
                    found: probe.formatVersion,
                    current: RecoverableStoreEnvelope<Value>.currentVersion
                )
            }
            return try decoder.decode(
                RecoverableStoreEnvelope<Value>.self,
                from: data
            ).value
        }
        return try decoder.decode(Value.self, from: data)
    }

    private func quarantine() -> URL? {
        let baseName = "\(url.lastPathComponent).unreadable"
        var destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
        while fileManager.fileExists(atPath: destination.path) {
            destination = url.deletingLastPathComponent()
                .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
        }

        do {
            try fileManager.moveItem(at: url, to: destination)
            guard fileManager.fileExists(atPath: destination.path) else { return nil }
            ThreadingLogger.session.error(
                "Kept unreadable \(self.url.lastPathComponent, privacy: .public) at \(destination.path, privacy: .public)"
            )
            return destination
        } catch {
            ThreadingLogger.session.error(
                "Could not quarantine \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
