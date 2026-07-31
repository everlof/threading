import Foundation

/// Keeps what has been typed into a project's composer but not yet started.
///
/// The prompt that opens a session is the one piece of text in the app that exists nowhere
/// else while it is being written: there is no transcript (the agent has not launched), no
/// terminal scrollback (there is no terminal yet), and no shell history (the login shell
/// `exec`s the agent). Until it is submitted it lives only in an `NSTextField`, and a crash
/// takes it with it — which is exactly what happened on 22 July 2026.
///
/// Written on the keystroke rather than on a timer, deliberately unlike `ProjectStore`'s
/// coalesced saves: this file exists *for* the crash that lands between two keystrokes, so a
/// coalescing window is the one interval it cannot afford. A draft is a few hundred bytes.
@MainActor
final class DraftStore {

    // MARK: - Singleton

    static let shared = DraftStore()

    // MARK: - Properties

    private var drafts: [ProjectID: String] = [:]
    private let persistence: RecoverableFileStore<DraftsFile>

    // MARK: - Initialization

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(DraftDefaults.fileName),
            fileManager: fileManager,
            criticality: .userAuthored
        )

        load()
    }

    // MARK: - Public Methods

    /// What was left in the composer for a project, or an empty string.
    func draft(for projectID: ProjectID) -> String {
        drafts[projectID] ?? ""
    }

    /// Records the composer's current text. An empty draft is removed rather than stored, so
    /// the file holds only what could still be lost.
    func setDraft(_ text: String, for projectID: ProjectID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            guard drafts.removeValue(forKey: projectID) != nil else { return }
        } else {
            guard drafts[projectID] != text else { return }
            drafts[projectID] = text
        }

        save()
    }

    /// Drops a project's draft: it has been started, or the project itself is gone.
    func clear(for projectID: ProjectID) {
        guard drafts.removeValue(forKey: projectID) != nil else { return }
        save()
    }

    // MARK: - Private Methods

    private func load() {
        let outcome = persistence.load(defaultValue: DraftsFile(drafts: [:])) { stored in
            if let invalidID = stored.drafts.keys.first(where: {
                ProjectID(uuidString: $0) == nil
            }) {
                throw DraftStoreError.invalidProjectIdentifier(invalidID)
            }
        }
        let stored = outcome.value

        drafts = stored.drafts.reduce(into: [:]) { result, entry in
            // Validation above proves every key. Keeping the guard makes this total even if
            // that validation is changed later.
            guard let id = ProjectID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    private func save() {
        let file = DraftsFile(
            drafts: drafts.reduce(into: [:]) { $0[$1.key.uuidString] = $1.value }
        )

        persistence.save(file)
    }
}

// MARK: - Stored Shape

private enum DraftStoreError: LocalizedError {
    case invalidProjectIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectIdentifier(let value):
            return "draft key '\(value)' is not a project identifier"
        }
    }
}

private struct DraftsFile: Codable {
    /// Keyed by project id as a string, since JSON object keys cannot be `UUID`.
    var drafts: [String: String]
}

// MARK: - Draft Defaults

enum DraftDefaults {
    static let fileName = "drafts.json"
}
