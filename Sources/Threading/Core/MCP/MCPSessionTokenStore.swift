import Foundation
import os

// MARK: - Durable Token Record

/// The token file's on-disk shape.
///
/// A version and a map, decoded as a value type rather than as `[String: Any]`, so a file this
/// build cannot read is *recognised* as unreadable instead of being half-interpreted.
private struct MCPSessionTokenDocument: Codable {
    let version: Int
    let tokens: [String: String]
}

// MARK: - Session Token Store

/// Reads and writes the durable per-session tokens.
///
/// A token is a **property of the session**, minted once and rotated only when the session is
/// deleted. Before it was durable, restarting the app renamed every session's endpoint: a hook
/// from a process that outlived the launch — or one that arrived during a launch, before the
/// listener was up — carried a token nothing recognised, so the session went on working while
/// the app believed it was idle.
///
/// The token deliberately stays a random UUID rather than anything derived from the session
/// identifier. `MCPSessionRegistry`'s header says why: the identifier is written to disk in
/// readable places, and the token is the only thing guarding the endpoint.
///
/// Mutation is confined to `MCPSessionRegistry`'s lock; the write itself happens on
/// `MCPSessionTokenWriter`'s serial queue so that a filesystem write never runs inside that
/// critical section.
struct MCPSessionTokenStore: Sendable {

    // MARK: - Properties

    let file: URL

    /// Set when a corrupt file could not be moved aside.
    ///
    /// `reliability-and-type-safety.md`: corrupt data is quarantined, never interpreted as an
    /// empty store and overwritten. If quarantine itself fails, the only recoverable bytes are
    /// the ones on disk — so writing is refused for the rest of the launch and the sessions
    /// simply mint fresh tokens in memory, which is a launch's worth of degradation rather than
    /// a permanent loss.
    private(set) var writesBlocked = false

    // MARK: - Initialization

    init(file: URL = MCPBridgeLocation.tokenFile) {
        self.file = file
    }

    // MARK: - Public Methods

    /// The stored tokens, or an empty map when there is nothing readable to load.
    ///
    /// Individual entries that cannot be parsed are skipped rather than failing the load: one
    /// unreadable row must not cost every other session its routing. A file that cannot be read
    /// or decoded *at all* is quarantined and reported.
    mutating func load() -> (tokens: [SessionID: String], diagnostic: Diagnostic?) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: file.path) else { return ([:], nil) }

        let data: Data
        do {
            data = try BoundedFileReader.read(
                file,
                maximumBytes: MCPBridgeDefaults.maximumTokenFileBytes
            )
        } catch {
            return ([:], quarantine(reason: "unreadable", error: error))
        }

        let document: MCPSessionTokenDocument
        do {
            document = try JSONDecoder().decode(MCPSessionTokenDocument.self, from: data)
        } catch {
            return ([:], quarantine(reason: "undecodable", error: error))
        }

        guard document.version == MCPBridgeDefaults.tokenFileVersion else {
            return ([:], quarantine(
                reason: "version \(document.version)",
                error: MCPSessionTokenStoreError.unsupportedVersion(document.version)
            ))
        }

        var tokens: [SessionID: String] = [:]
        var skipped = 0
        for (identifier, token) in document.tokens {
            guard let sessionID = SessionID(uuidString: identifier), !token.isEmpty else {
                skipped += 1
                continue
            }
            tokens[sessionID] = token
        }

        guard skipped > 0 else { return (tokens, nil) }
        return (tokens, Diagnostic(
            message: "Skipped unreadable durable MCP token entries",
            detail: ["skipped": String(skipped), "kept": String(tokens.count)]
        ))
    }

    /// Replaces the file with exactly these tokens.
    ///
    /// Whole-file rather than incremental: the map *is* the record, `retainOnly` prunes it, and
    /// an append-only file addressing deleted sessions is precisely what must not accumulate.
    func write(_ tokens: [SessionID: String]) {
        guard !writesBlocked else { return }

        guard MCPBridgeLocation.prepareDirectory(file.deletingLastPathComponent()) else { return }

        let document = MCPSessionTokenDocument(
            version: MCPBridgeDefaults.tokenFileVersion,
            tokens: Dictionary(
                uniqueKeysWithValues: tokens.map { ($0.key.uuidString, $0.value) }
            )
        )

        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: MCPBridgeDefaults.filePermissions],
                ofItemAtPath: file.path
            )
        } catch {
            ThreadingLogger.mcp.error(
                "Could not write durable MCP tokens: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    // MARK: - Private Methods

    /// Moves an unreadable file aside so the next write cannot destroy the only copy of it.
    private mutating func quarantine(reason: String, error: Error) -> Diagnostic {
        let destination = file.deletingLastPathComponent().appendingPathComponent(
            "\(file.lastPathComponent).unreadable-\(UUID().uuidString)"
        )

        do {
            try FileManager.default.moveItem(at: file, to: destination)
            ThreadingLogger.mcp.error(
                "Quarantined the durable MCP token file (\(reason, privacy: .public))"
            )
            return Diagnostic(
                message: "Quarantined an unreadable durable MCP token file",
                detail: ["reason": reason, "error": error.localizedDescription]
            )
        } catch {
            writesBlocked = true
            ThreadingLogger.mcp.error(
                "Could not quarantine the durable MCP token file; writes blocked this launch"
            )
            return Diagnostic(
                message: "Could not quarantine the durable MCP token file, writes blocked",
                detail: ["reason": reason, "error": error.localizedDescription]
            )
        }
    }

    // MARK: - Diagnostic

    /// Something worth a journal line, carried out of the load rather than recorded inside it.
    ///
    /// `EventLog.record` takes its own queue synchronously, and the load runs under the
    /// registry's unfair lock. Returning the line lets the caller record it after unlocking.
    struct Diagnostic: Sendable {
        let message: String
        let detail: [String: String]
    }
}

private enum MCPSessionTokenStoreError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported MCP token file version \(version)."
        }
    }
}

// MARK: - Session Token Writer

/// One snapshot of the durable tokens, taken under the registry's lock and written off it.
struct MCPSessionTokenSnapshot: Sendable {
    let generation: UInt64
    let tokens: [SessionID: String]
    let store: MCPSessionTokenStore
}

/// Serialises token-file writes without holding the registry's lock across a filesystem call.
///
/// Snapshots carry the generation they were taken at, because the order two threads *take* a
/// snapshot in is not the order they reach the queue in — and a stale snapshot landing last
/// would resurrect a revoked token. An older generation is dropped rather than written.
enum MCPSessionTokenWriter {

    // MARK: - Properties

    private static let queue = DispatchQueue(
        label: MCPBridgeDefaults.tokenWriteQueueLabel,
        qos: .utility
    )

    private static let lastWrittenGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // MARK: - Public Methods

    static func write(_ snapshot: MCPSessionTokenSnapshot) {
        queue.async {
            let isStale = lastWrittenGeneration.withLock { last -> Bool in
                guard snapshot.generation > last else { return true }
                last = snapshot.generation
                return false
            }
            guard !isStale else { return }
            snapshot.store.write(snapshot.tokens)
        }
    }

    /// Blocks until every enqueued write has landed.
    ///
    /// Exposed for tests, which have to observe the file a mint or a revocation produced. The
    /// app never waits: a token that has not reached disk yet is still in memory, and the only
    /// thing that reads the file is the next launch.
    static func waitForPendingWrites() {
        queue.sync {}
    }
}
