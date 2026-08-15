import Foundation

struct CurrentSessionUnavailableError: LocalizedError {
    let sessionID: SessionID

    var errorDescription: String? {
        "Session \(sessionID) is no longer available."
    }
}

/// The application-owned read boundary for mutable session records.
///
/// Controllers keep a stable `SessionID` and ask this projection for the current value whenever
/// they need mutable configuration. A missing value is meaningful: the session was removed, so
/// callers must not continue with the snapshot that happened to construct their surface.
@MainActor
struct CurrentSessionProjection {
    typealias Resolve = @MainActor (SessionID) -> AgentSession?
    typealias ResolveWorkingDirectory = @MainActor (SessionID) -> String?

    private let resolve: Resolve
    private let resolveWorkingDirectory: ResolveWorkingDirectory

    init(resolve: @escaping Resolve) {
        self.resolve = resolve
        resolveWorkingDirectory = { _ in nil }
    }

    init(
        resolve: @escaping Resolve,
        workingDirectory: @escaping ResolveWorkingDirectory
    ) {
        self.resolve = resolve
        self.resolveWorkingDirectory = workingDirectory
    }

    func session(for sessionID: SessionID) -> AgentSession? {
        resolve(sessionID)
    }

    func requireSession(for sessionID: SessionID) throws -> AgentSession {
        guard let session = resolve(sessionID) else {
            throw CurrentSessionUnavailableError(sessionID: sessionID)
        }
        return session
    }

    func workingDirectory(for sessionID: SessionID) -> String? {
        resolveWorkingDirectory(sessionID)
    }

    static func projectStore(_ store: ProjectStore) -> CurrentSessionProjection {
        CurrentSessionProjection(
            resolve: { sessionID in
                store.session(withID: sessionID)
            },
            workingDirectory: { sessionID in
                store.workingDirectory(forSessionID: sessionID)
            }
        )
    }
}
