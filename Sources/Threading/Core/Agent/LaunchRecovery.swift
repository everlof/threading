import Foundation

// MARK: - Launch Recovery Brief

/// Whether a failed launch is worth handing to an agent, and what to tell it.
///
/// The offer is deliberately narrow. An agent asked to fix "the session won't start" with no
/// file to work on and no error it recognises will do something — agents always do something —
/// and what it does will be somewhere in the user's home directory. So the button only appears
/// when there is a named conversation file and a cause that is about that file. A missing
/// executable and an expired login are real diagnoses with nothing here to repair.
enum LaunchRecoveryBrief {

    // MARK: - Public Methods

    /// Whether the recovery offer belongs on this failure's surface.
    static func canAttempt(_ failure: SessionLaunchFailure) -> Bool {
        guard let path = failure.transcriptPath, !path.isEmpty else { return false }
        return failure.knownCause == SessionLaunchDiagnosis.Cause.transcriptUnreadable
    }

    /// The opening message the recovery chat is launched with.
    ///
    /// Written as instructions to an agent rather than as a description of a bug, and it states
    /// the boundary twice — once as a rule and once as the reason — because the file it names
    /// sits in a directory holding every other conversation the user has. The agent is given a
    /// copy and told the copy is the deliverable; nothing in this prompt asks it to touch the
    /// original, and `LaunchRecoveryWorkspace` is what makes that true rather than hoped for.
    static func prompt(
        conversationTitle: String,
        workingCopy: URL,
        original: URL,
        failure: SessionLaunchFailure,
        toolName: String
    ) -> String {
        let error = failure.detail.isEmpty
            ? failure.summary
            : failure.detail.joined(separator: "\n")

        return L10n.format(
            """
            A conversation in Threading called “%@” will not reopen. Its agent refused to \
            resume and stopped. Your job is to work out why and, if you can, repair it.

            What the runtime said:

            %@

            Threading has already copied the conversation file for you to work on:

              Working copy: %@
              Original:     %@ (read this if you need to; never write to it)

            Work only on the working copy. The original sits in a directory holding every \
            other conversation on this machine, and Threading — not you — will put a repaired \
            file back, keeping a backup, once the user approves it.

            When you are done, call the %@ tool with the path to your working copy and a plain \
            explanation of what was wrong and what you changed. Call it whether or not you \
            succeeded: a clear account of a conversation that cannot be saved is worth more \
            than silence, and the user is shown what you say before anything is replaced.
            """,
            conversationTitle,
            error,
            workingCopy.path,
            original.path,
            toolName
        )
    }
}

// MARK: - Launch Recovery Workspace

/// Owns the copy a recovery agent may edit, and the swap Threading performs if it works.
///
/// The split is the safety property. The agent never receives a path inside the provider's own
/// directory to write to, so no amount of confusion on its part can reach a conversation it was
/// not asked about; and the move back is Threading's, gated on a check and on the user, with the
/// displaced original kept.
struct LaunchRecoveryWorkspace {

    // MARK: - Types

    enum Failure: LocalizedError, Equatable {
        case originalMissing
        case copyFailed(underlying: String)
        case repairedFileMissing
        case repairedFileOutsideWorkspace
        case repairedFileStillUnusable(reason: String)
        case swapFailed(underlying: String)
        /// The file is a mirror of a transcript that lives on a remote host. Repairing the copy
        /// would change nothing the agent reads, and the next refresh would overwrite it.
        case remoteTranscript

        var errorDescription: String? {
            switch self {
            case .originalMissing:
                return L10n.string("The conversation file is no longer where it was.")
            case .copyFailed(let underlying):
                return L10n.format("The conversation file could not be copied: %@", underlying)
            case .repairedFileMissing:
                return L10n.string("The repaired file named by the agent is not there.")
            case .repairedFileOutsideWorkspace:
                return L10n.string(
                    "The repaired file is outside the working folder Threading prepared."
                )
            case .repairedFileStillUnusable(let reason):
                return reason
            case .remoteTranscript:
                return L10n.string(
                    "This conversation’s file is on its remote host, so it can’t be repaired from this Mac."
                )
            case .swapFailed(let underlying):
                return L10n.format("The repaired file could not be put back: %@", underlying)
            }
        }
    }

    // MARK: - Properties

    let root: URL
    private let fileManager: FileManager

    // MARK: - Initialization

    init(
        root: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                ProjectIconDefaults.applicationDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                LaunchRecoveryDefaults.directoryName,
                isDirectory: true
            ),
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
    }

    // MARK: - Public Methods

    /// The folder this session's repair attempts happen in.
    func directory(for sessionID: SessionID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Copies the conversation file somewhere the agent may edit it, and returns the copy.
    ///
    /// A fresh folder each time: a second attempt that inherited the first one's leftovers would
    /// hand the agent a directory of half-repaired files and no way to tell which was which.
    func prepare(original: URL, for sessionID: SessionID) throws -> URL {
        guard fileManager.fileExists(atPath: original.path) else {
            throw Failure.originalMissing
        }

        let directory = directory(for: sessionID)
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(original.lastPathComponent)
            try fileManager.copyItem(at: original, to: copy)
            return copy
        } catch {
            throw Failure.copyFailed(underlying: error.localizedDescription)
        }
    }

    /// Checks a repaired file well enough to put it in front of the user.
    ///
    /// Two questions, and the second is the one that matters: the file must be inside the folder
    /// Threading prepared — an agent naming any other path is answered with a refusal rather
    /// than a copy — and it must now pass the same structural check that condemned the original.
    /// That check is not a promise the runtime will accept it; it is the strongest thing that
    /// can be known without starting one, and it is exactly the assertion the agent's work is
    /// supposed to have made true.
    func verify(
        repaired: URL,
        for sessionID: SessionID,
        kind: AgentKind
    ) throws {
        let workspace = directory(for: sessionID).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = repaired.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(workspace.path + "/") else {
            throw Failure.repairedFileOutsideWorkspace
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw Failure.repairedFileMissing
        }

        if case .unusable(let reason, _) = TranscriptResumeHealth.verdict(
            for: candidate,
            kind: kind
        ) {
            throw Failure.repairedFileStillUnusable(reason: reason)
        }
    }

    /// Puts the repaired file where the runtime looks for it, keeping what was displaced.
    ///
    /// The backup is beside the working copy rather than beside the original: this writes into
    /// the provider's directory exactly once, with one file, and leaving a `.threading-backup`
    /// sibling in there would be a second write into a directory whose contents are not ours to
    /// add to — and one the provider's own session listing would then have to ignore.
    @discardableResult
    func accept(
        repaired: URL,
        replacing original: URL,
        for sessionID: SessionID
    ) throws -> URL {
        guard !RemoteTranscriptMirror.shared.contains(original) else { throw Failure.remoteTranscript }
        let backup = directory(for: sessionID)
            .appendingPathComponent(
                LaunchRecoveryDefaults.backupPrefix + original.lastPathComponent
            )

        do {
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            if fileManager.fileExists(atPath: original.path) {
                try fileManager.copyItem(at: original, to: backup)
            }
            _ = try fileManager.replaceItemAt(original, withItemAt: repaired)
            return backup
        } catch {
            throw Failure.swapFailed(underlying: error.localizedDescription)
        }
    }
}

// MARK: - Defaults

enum LaunchRecoveryDefaults {

    static let directoryName = "ConversationRepairs"

    static let backupPrefix = "before-repair-"

    static let ticketFile = "repair.json"

    /// What the recovery chat is called in the sidebar. It names the conversation it is about,
    /// because a row called "Recovery" beside twenty others says nothing.
    static func chatTitle(for conversationTitle: String) -> String {
        L10n.format("Recovering %@", conversationTitle)
    }
}

// MARK: - Launch Recovery Ticket

/// The link between a recovery chat and the conversation it was created to repair.
///
/// **The recovery agent never names its target.** It calls the repair tool with a path and an
/// explanation; which conversation is being repaired is read from here, by the recovery chat's
/// own session id. That is the whole authority model: a chat can only ever propose a repair for
/// the one conversation Threading made it for, and an agent that decides to be helpful about a
/// different conversation has no way to say so.
///
/// Written into the repair folder rather than held in memory, because the work takes as long as
/// it takes: a repair conversation that spans an app restart must not come back with its tool
/// pointing at nothing.
struct LaunchRecoveryTicket: Codable, Equatable {

    let targetSessionID: SessionID
    let recoverySessionID: SessionID
    let originalPath: String
    let workingCopyPath: String
    let kind: AgentKind

    var original: URL { URL(fileURLWithPath: originalPath) }
    var workingCopy: URL { URL(fileURLWithPath: workingCopyPath) }
}

/// Finds the ticket a repair tool call belongs to.
struct LaunchRecoveryRegistry {

    // MARK: - Properties

    private let workspace: LaunchRecoveryWorkspace
    private let fileManager: FileManager

    // MARK: - Initialization

    init(
        workspace: LaunchRecoveryWorkspace = LaunchRecoveryWorkspace(),
        fileManager: FileManager = .default
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    // MARK: - Public Methods

    func write(_ ticket: LaunchRecoveryTicket) throws {
        let url = ticketURL(for: ticket.targetSessionID)
        let data = try JSONEncoder().encode(ticket)
        try data.write(to: url, options: .atomic)
    }

    /// The ticket this recovery chat holds, or nil if it holds none.
    ///
    /// Scans the repair folders rather than keeping an index: there is one folder per repair
    /// ever attempted on this machine, a number bounded by how often conversations break, and
    /// the scan happens once per tool call rather than on any interactive path.
    func ticket(forRecoverySession sessionID: SessionID) -> LaunchRecoveryTicket? {
        tickets().first { $0.recoverySessionID == sessionID }
    }

    func ticket(forTargetSession sessionID: SessionID) -> LaunchRecoveryTicket? {
        read(at: ticketURL(for: sessionID))
    }

    func forget(targetSessionID: SessionID) {
        try? fileManager.removeItem(at: ticketURL(for: targetSessionID))
    }

    // MARK: - Private Methods

    private func tickets() -> [LaunchRecoveryTicket] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: workspace.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return folders.compactMap { folder in
            read(at: folder.appendingPathComponent(LaunchRecoveryDefaults.ticketFile))
        }
    }

    private func read(at url: URL) -> LaunchRecoveryTicket? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LaunchRecoveryTicket.self, from: data)
    }

    private func ticketURL(for targetSessionID: SessionID) -> URL {
        workspace.directory(for: targetSessionID)
            .appendingPathComponent(LaunchRecoveryDefaults.ticketFile)
    }
}
