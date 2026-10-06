import Foundation

/// All file/codec work is actor-isolated away from the UI. A corrupt new record never grants
/// permission to reimport old preferences or silently overwrite the user's preserved choices.
actor AppearanceActivationStore: AppearanceActivationPersisting {
    private let persistence: RecoverableFileStore<AppearanceActivationState>
    private let url: URL
    private let markerURL: URL
    private var writable = false

    init(url: URL) {
        self.url = url
        markerURL = url.appendingPathExtension("initialized")
        persistence = RecoverableFileStore(
            url: url,
            fileManager: .default,
            criticality: .userAuthored,
            sizePolicy: .compactMetadata
        )
    }

    func load(migrating legacy: AppearanceActivationState, persistMigration: Bool = true) throws -> AppearanceActivationState {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        if !exists, fileManager.fileExists(atPath: markerURL.path) {
            throw AppearanceActivationError.recoveryRequired
        }
        if !persistMigration {
            do {
                let state = try persistence.readPreservingOriginal { try $0.validate() } ?? legacy
                try state.validate()
                writable = true
                return state
            } catch { throw AppearanceActivationError.recoveryRequired }
        }
        // Leave a durable marker before the reader can quarantine a corrupt record. A later
        // launch must not mistake the now-missing original for a first-run migration.
        if exists { try markInitialized() }
        let outcome = persistence.load(defaultValue: legacy) { try $0.validate() }
        switch outcome {
        case .loaded(let state):
            writable = true
            return state
        case .missing:
            try legacy.validate()
            if persistMigration {
                try markInitialized()
                guard persistence.save(legacy) else { throw AppearanceActivationError.persistenceFailed }
            }
            writable = true
            return legacy
        case .unreadable:
            throw AppearanceActivationError.recoveryRequired
        }
    }

    func save(_ state: AppearanceActivationState) throws {
        guard writable else { throw AppearanceActivationError.recoveryRequired }
        try state.validate()
        try markInitialized()
        guard persistence.save(state) else { throw AppearanceActivationError.persistenceFailed }
    }

    private func markInitialized() throws {
        guard !FileManager.default.fileExists(atPath: markerURL.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: markerURL, options: .atomic)
    }
}
