import Foundation

// MARK: - Where a mirror lives

/// One remote conversation's transcript: the file on the host and its copy on this Mac.
struct RemoteTranscriptLocation: Equatable, Sendable {
    let destination: RemoteHostDestination
    /// Absolute, on the host.
    let remotePath: String
    let localURL: URL
}

/// What one refresh of a mirror came to.
enum RemoteTranscriptMirrorOutcome: Equatable, Sendable {
    /// New lines arrived; the count is bytes appended.
    case advanced(Int)
    /// The mirror was already level with the host.
    case unchanged
    /// The host has no transcript yet — a session that has not spoken.
    case missing
    case failed(String)
}

// MARK: - Fetching

/// One bounded read of a transcript on a host: its size, and up to `limit` bytes from `offset`.
struct RemoteTranscriptChunk: Equatable, Sendable {
    /// Nil when the file does not exist on the host.
    let remoteSize: Int?
    let bytes: Data
}

protocol RemoteTranscriptFetching: Sendable {
    func fetch(
        destination: RemoteHostDestination,
        remotePath: String,
        offset: Int,
        limit: Int
    ) throws -> RemoteTranscriptChunk
}

enum RemoteTranscriptFetchError: LocalizedError, Equatable {
    case unreachable(String)
    case unreadableAnswer

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): return detail
        case .unreadableAnswer: return "The host's answer about the transcript could not be read."
        }
    }
}

/// The system `ssh`: one command that states the file's size, then streams at most `limit` bytes
/// from `offset`. `head -c` is what bounds it on the host, so the capture here is exactly what was
/// asked for and never a suffix of something larger.
struct SSHTranscriptFetcher: RemoteTranscriptFetching {

    func fetch(
        destination: RemoteHostDestination,
        remotePath: String,
        offset: Int,
        limit: Int
    ) throws -> RemoteTranscriptChunk {
        let command = Self.command(remotePath: remotePath, offset: offset, limit: limit)
        let result = try BoundedChildProcess.run(
            executable: RemoteHostDefaults.sshExecutable,
            arguments: destination.sshArguments(extraOptions: RemoteHostDefaults.compressionOptions) + [command],
            timeout: RemoteTranscriptMirrorDefaults.fetchTimeout,
            maximumOutputBytes: limit + RemoteTranscriptMirrorDefaults.headerBytes,
            output: .standardOutput
        )
        guard result.termination == .exited(0) else {
            throw RemoteTranscriptFetchError.unreachable("ssh ended \(result.termination)")
        }
        return try Self.parse(result.output)
    }

    /// The command the host's login shell runs. POSIX only, the path quoted as one word: a remote
    /// launch already refuses a login shell that is not POSIX, and the path comes from the host's
    /// own home and the project's folder, neither of which is ours to trust unquoted.
    static func command(remotePath: String, offset: Int, limit: Int) -> String {
        let path = ShellCommand(word: remotePath).source
        return "f=\(path); if [ -f \"$f\" ]; then "
            + "printf 'size=%s\\n' \"$(wc -c < \"$f\" | tr -d ' ')\"; "
            + "tail -c +\(offset + 1) \"$f\" | head -c \(limit); "
            + "else printf 'missing\\n'; fi"
    }

    /// `size=<n>\n<bytes>` or `missing\n`.
    static func parse(_ output: Data) throws -> RemoteTranscriptChunk {
        guard let newline = output.firstIndex(of: UInt8(ascii: "\n")) else {
            throw RemoteTranscriptFetchError.unreadableAnswer
        }
        let header = String(decoding: output[output.startIndex..<newline], as: UTF8.self)
        let body = output[output.index(after: newline)...]
        if header == RemoteTranscriptMirrorDefaults.missingHeader {
            return RemoteTranscriptChunk(remoteSize: nil, bytes: Data())
        }
        guard header.hasPrefix(RemoteTranscriptMirrorDefaults.sizePrefix),
              let size = Int(header.dropFirst(RemoteTranscriptMirrorDefaults.sizePrefix.count)) else {
            throw RemoteTranscriptFetchError.unreadableAnswer
        }
        return RemoteTranscriptChunk(remoteSize: size, bytes: Data(body))
    }
}

// MARK: - The mirror

/// A local, read-only copy of each remote session's transcript, kept level with the host by byte
/// offset.
///
/// **Why a copy.** A remote agent's transcript is a file on its host, and some twenty readers on
/// this Mac — the title, the work log, refusal and interruption detection, run progress, the model
/// card, limit recovery, the continuation snapshot — read it as a file. Teaching each of them to ask
/// a host would be twenty remote protocols; a mirror is one, and `SessionTranscript.readRequest`
/// routes a remote session's reads to it (`docs/feature-drafts/remote-execution-hosts.md`, slice 5).
///
/// **Outside every Claude directory, on purpose.** Usage scans, import and account discovery walk
/// `~/.claude*/projects`; a mirror there would be counted as a second conversation, offered as an
/// outside session to import, or win "newest transcript" for the account. It lives under
/// Application Support instead, and the three places that *write* transcripts refuse it.
///
/// **Only whole lines, only forward.** A refresh appends what the host has beyond the mirror's
/// length, cut at the last newline, so a line the agent is still writing is never half-copied. A
/// host file shorter than the mirror was rewritten, and the mirror starts again from nothing. Each
/// round is bounded by `chunkBytes` and a refresh by `maximumRounds`, so a first copy of a very long
/// conversation catches up across refreshes rather than in one unbounded transfer.
final class RemoteTranscriptMirror: @unchecked Sendable {

    static let shared = RemoteTranscriptMirror()

    let root: URL
    private let fetcher: RemoteTranscriptFetching
    private let chunkBytes: Int
    private let maximumRounds: Int
    private let queue = DispatchQueue(label: "codes.threading.remote-transcripts", qos: .utility)
    private let lock = NSLock()
    /// One refresh per mirror at a time; a caller arriving mid-refresh is answered by the next one,
    /// so it reads a mirror at least as new as the moment it asked.
    private var waiting: [URL: [@Sendable (RemoteTranscriptMirrorOutcome) -> Void]] = [:]
    private var running: Set<URL> = []

    init(
        root: URL = PTYHostLocation.supportRoot
            .appendingPathComponent(RemoteTranscriptMirrorDefaults.directoryName, isDirectory: true),
        fetcher: RemoteTranscriptFetching = SSHTranscriptFetcher(),
        chunkBytes: Int = RemoteTranscriptMirrorDefaults.chunkBytes,
        maximumRounds: Int = RemoteTranscriptMirrorDefaults.maximumRounds
    ) {
        self.root = root
        self.fetcher = fetcher
        self.chunkBytes = chunkBytes
        self.maximumRounds = maximumRounds
    }

    // MARK: - Public Methods

    /// Where a conversation's mirror is, named by the machine and the conversation. The folder a
    /// project runs in is deliberately not part of it: a conversation is one file on one host.
    func localURL(destination: RemoteHostDestination, transcriptID: TranscriptID) -> URL {
        root
            .appendingPathComponent(destination.identifier, isDirectory: true)
            .appendingPathComponent(transcriptID.rawValue + RemoteAgentLaunchDefaults.transcriptExtension)
    }

    /// Whether a path is inside the mirror — the question the transcript writers ask before they
    /// replace, move or copy a file.
    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Brings a mirror level with its host, off the main actor, and answers on the main queue.
    func refresh(
        _ location: RemoteTranscriptLocation,
        completion: @escaping @Sendable (RemoteTranscriptMirrorOutcome) -> Void
    ) {
        lock.lock()
        waiting[location.localURL, default: []].append(completion)
        let starts = !running.contains(location.localURL)
        if starts { running.insert(location.localURL) }
        lock.unlock()
        guard starts else { return }
        queue.async { [weak self] in self?.drain(location) }
    }

    /// The same, blocking. For a caller already on a worker, and for tests.
    func synchronize(_ location: RemoteTranscriptLocation) -> RemoteTranscriptMirrorOutcome {
        do {
            return try sync(location)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    /// Runs refreshes until nobody is waiting, so every caller is answered by a refresh that began
    /// after it asked.
    private func drain(_ location: RemoteTranscriptLocation) {
        while true {
            lock.lock()
            let callers = waiting.removeValue(forKey: location.localURL) ?? []
            if callers.isEmpty {
                running.remove(location.localURL)
                lock.unlock()
                return
            }
            lock.unlock()
            let outcome = synchronize(location)
            DispatchQueue.main.async {
                for caller in callers { caller(outcome) }
            }
        }
    }

    private func sync(_ location: RemoteTranscriptLocation) throws -> RemoteTranscriptMirrorOutcome {
        let file = location.localURL
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: RemoteTranscriptMirrorDefaults.directoryPermissions]
        )
        var length = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        var appended = 0
        // The start of a line longer than one chunk, carried until its newline arrives. Without it
        // a line bigger than a chunk — a large tool result, an inlined image — has no newline in any
        // single read, and the mirror would stop at it for good (measured on the spike's VM: a
        // 32 KB chunk stalled at 56,619 of 184,407 bytes).
        var pending = Data()
        var completedRounds = 0

        while completedRounds < maximumRounds {
            let chunk = try fetcher.fetch(
                destination: location.destination,
                remotePath: location.remotePath,
                offset: length + pending.count,
                limit: chunkBytes
            )
            guard let remoteSize = chunk.remoteSize else {
                return appended > 0 ? .advanced(appended) : .missing
            }
            if remoteSize < length + pending.count {
                // Shorter than what we hold: the host rewrote it. Start again rather than append
                // onto a prefix that is no longer the host's.
                try Data().write(to: file, options: .atomic)
                length = 0
                pending = Data()
                completedRounds += 1
                continue
            }
            guard let lastNewline = chunk.bytes.lastIndex(of: UInt8(ascii: "\n")) else {
                // No line ends in this read. If it stopped short, the host has no more yet — a line
                // still being written. If it filled the chunk, the line continues past it.
                guard chunk.bytes.count == chunkBytes else { break }
                pending.append(chunk.bytes)
                guard pending.count <= RemoteTranscriptMirrorDefaults.maximumLineBytes else {
                    return .failed("a transcript line is longer than \(RemoteTranscriptMirrorDefaults.maximumLineBytes) bytes")
                }
                continue
            }
            let whole = pending + chunk.bytes[chunk.bytes.startIndex...lastNewline]
            pending = Data()
            try append(whole, to: file)
            length += whole.count
            appended += whole.count
            completedRounds += 1
            if length >= remoteSize || chunk.bytes.count < chunkBytes {
                break
            }
        }
        return appended > 0 ? .advanced(appended) : .unchanged
    }

    private func append(_ data: Data, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: RemoteTranscriptMirrorDefaults.filePermissions]
            )
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

enum RemoteTranscriptMirrorDefaults {
    static let directoryName = "remote-transcripts"
    /// One round's ceiling. Transcripts on a working Mac run to tens of megabytes (the largest
    /// measured was 88 MB), so a first copy takes several refreshes and no single one is unbounded.
    static let chunkBytes = 8 * 1024 * 1024
    static let maximumRounds = 8
    /// The longest single line a mirror will carry across reads. A line is one transcript entry,
    /// and the largest measured was far below this; the ceiling exists so a file that is not a
    /// transcript cannot grow the carried buffer without bound.
    static let maximumLineBytes = 64 * 1024 * 1024
    static let headerBytes = 64
    static let fetchTimeout: TimeInterval = 120
    static let sizePrefix = "size="
    static let missingHeader = "missing"
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600
    /// How long a remote turn's ending waits for its transcript before it is applied anyway. A
    /// host that does not answer must not hold a session's state hostage.
    static let turnEndWait: TimeInterval = 5
}

// MARK: - Sessions

extension RemoteTranscriptMirror {

    /// The host a session runs on, if it runs on one. The project's own record is the authority,
    /// with the project a caller passed in as the fallback for one not in the store.
    @MainActor
    static func host(for session: AgentSession, in project: Project?, store: ProjectStore = .shared) -> ProjectExecutionHost? {
        store.project(forSessionID: session.id)?.executionHost ?? project?.executionHost
    }

    /// Where a remote session's transcript is read from on this Mac, or nil for a local session.
    @MainActor
    func mirrorURL(for session: AgentSession, transcriptID: TranscriptID, in project: Project?) -> URL? {
        guard let host = Self.host(for: session, in: project) else { return nil }
        return localURL(destination: host.sshDestination, transcriptID: transcriptID)
    }

    /// Everything a refresh needs, or nil when there is nothing to refresh: a local session, one
    /// with no conversation yet, or a host this app has not prepared this run (its home is a fact
    /// read from the host, and nothing about the host is guessed).
    @MainActor
    func location(
        forSessionID sessionID: SessionID,
        store: ProjectStore = .shared,
        hosts: RemoteExecutionHosts = .shared
    ) -> RemoteTranscriptLocation? {
        guard let session = store.session(withID: sessionID),
              let host = Self.host(for: session, in: nil, store: store),
              let transcriptID = session.resumeState.transcriptID,
              case .ready(let context) = hosts.phase(for: host.sshDestination) else { return nil }
        return RemoteTranscriptLocation(
            destination: host.sshDestination,
            remotePath: RemoteAgentLaunch.remoteTranscriptPath(
                home: context.facts.home,
                remoteDirectory: host.remoteDirectory,
                transcriptID: transcriptID
            ),
            localURL: localURL(destination: host.sshDestination, transcriptID: transcriptID)
        )
    }

    /// Refreshes a session's mirror and then runs `then` on the main actor — or runs it at once
    /// when the session has nothing to refresh. `then` runs exactly once: after the refresh, or
    /// after `wait` if the host has not answered by then, whichever is first.
    @MainActor
    func refresh(
        sessionID: SessionID,
        wait: TimeInterval = RemoteTranscriptMirrorDefaults.turnEndWait,
        then: @escaping @MainActor () -> Void
    ) {
        guard let location = location(forSessionID: sessionID) else {
            then()
            return
        }
        let once = RemoteTranscriptOnce(then)
        refresh(location) { outcome in
            MainActor.assumeIsolated {
                if case .failed(let detail) = outcome {
                    ThreadingLogger.ptyHost.info(
                        "Remote transcript refresh failed: \(detail, privacy: .private(mask: .hash))"
                    )
                }
                once.fire()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MainActor.assumeIsolated { once.fire() }
        }
    }
}

/// Runs a closure the first time it is fired and never again: a refresh and its deadline race to
/// the same continuation.
@MainActor
private final class RemoteTranscriptOnce {
    private var body: (@MainActor () -> Void)?

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    func fire() {
        guard let body else { return }
        self.body = nil
        body()
    }
}
