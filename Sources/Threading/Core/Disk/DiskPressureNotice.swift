import Foundation

// MARK: - Disk Pressure Notice

/// Tells an agent whose tool call just failed that the disk is nearly full — at that moment.
///
/// **Why on failure, and why live.** `DiskSpace` records the rejected design: stating the free
/// space in the session's opening instructions told the agent about a disk that was fine at
/// `initialize` and full an hour later. The failing write is the right moment. What it lacked was
/// the reading, and the failing write often does not say it was a disk: measured with the data
/// volume at 99% ("Where did my disk go?", skarol.dev, 2026-10-12, and this machine on
/// 2026-10-17), a full disk surfaces from Xcode as a module-cache "has been modified since the
/// module file was built", a wall of "unexpected incomplete target" ending in "database or disk
/// is full", or a linker/`lipo` failure whose "No space left on device" is buried in a long log.
/// An agent that reads the first error retries the build, or reports a compiler bug.
///
/// So this is an **answering** `PostToolUseFailure` hook, beside the silent lifecycle ones like
/// the workroom question guard: it says nothing unless the volume holding the user's home is
/// short *now*, or the error carries one of those signatures. Then it adds one host-authored
/// paragraph naming the reading and the storage tools. It never blocks and never decides
/// anything; at most it changes what the agent looks at first.
///
/// **Bounded.** One notice per session per `repeatInterval`: a full disk fails every command
/// after the first, and a notice on each would bury the turn in the same paragraph. Claude only:
/// Codex has no failure hook whose reply reaches the model, and adding a `PostToolUse` entry to
/// its account-shared `hooks.json` would cost the user's trust decision on every machine.
@MainActor
enum DiskPressureNotice {

    nonisolated static let hookName = "PostToolUseFailure"

    /// When each session was last told, so a full disk is announced once rather than per command.
    private static var lastNotified: [SessionID: Date] = [:]

    // MARK: - Hook command

    /// Claude's entry: the token is baked into the per-session `--settings` file. Its stdout is
    /// the answer; stderr and failure are swallowed, so an absent app prints nothing and exits 0.
    nonisolated static func claudeCommand(token: String) -> String {
        let payload = "threading_hook_payload"
        return "\(payload)=$(cat); " + MCPDefaults.hookPostCommand(
            payloadVariable: payload,
            endpointSuffix: "\(MCPDefaults.diskNoticePathPrefix)\(token)",
            timeout: MCPDefaults.diskNoticeTimeout
        ) + " 2>/dev/null || true"
    }

    // MARK: - Deciding

    /// The hook's reply for this session, or nil for silence.
    ///
    /// The reading is taken by the caller, off the main actor, and passed in: a volume query is
    /// a syscall, and this runs on the agent's hot path.
    ///
    /// `isEligible` is stated for tests, so they need neither the project store nor the tool
    /// catalog.
    static func decide(
        _ sessionID: SessionID,
        failure: DiskPressureFailure,
        reading: DiskSpace.Reading?,
        now: Date = Date(),
        isEligible: (SessionID) -> Bool = DiskPressureNotice.isEligible
    ) -> [String: Any]? {
        guard !failure.isInterrupt, isEligible(sessionID) else { return nil }

        let pressured = reading?.isUnderPressure ?? false
        let signature = failure.error.flatMap { Self.signature(in: $0, includingDisguises: pressured) }
        guard pressured || signature != nil else { return nil }

        if let last = lastNotified[sessionID],
           now.timeIntervalSince(last) < DiskPressureNoticeDefaults.repeatInterval {
            return nil
        }
        lastNotified[sessionID] = now

        return ["hookSpecificOutput": [
            "hookEventName": hookName,
            "additionalContext": notice(reading: reading, signature: signature)
        ]]
    }

    /// Whether this session may be told at all: the notice points at the Disk space tools, so
    /// it needs them switched on, and the reading is this Mac's, so a session whose agent runs on
    /// a remote host would be told about the wrong disk.
    static func isEligible(_ sessionID: SessionID) -> Bool {
        MCPToolCatalog.isEnabled(MCPToolCatalog.storage)
            && !ProjectStore.shared.sessionRunsOnRemoteHost(sessionID)
    }

    /// Forgets what a session was told, so a test or a fresh session starts from silence.
    static func reset(_ sessionID: SessionID? = nil) {
        if let sessionID {
            lastNotified[sessionID] = nil
        } else {
            lastNotified.removeAll()
        }
    }

    // MARK: - Words

    /// What the model is told. Pure, so its wording is tested.
    nonisolated static func notice(reading: DiskSpace.Reading?, signature: String?) -> String {
        let room = reading.map { reading in
            let free = ByteCountFormatter.string(fromByteCount: reading.available, countStyle: .file)
            let used = Int((reading.usedFraction * 100).rounded())
            return "this Mac's data volume has \(free) free (\(used)% used)"
        }

        guard reading?.isUnderPressure ?? false else {
            // The error looks like a full disk but the disk has room now: space may have been
            // freed since, or the failing write went to another volume. Say both facts.
            let now = room.map { " Right now \($0)." } ?? ""
            return """
                Threading: this failure reads like a full disk (“\(signature ?? "")”).\(now) If \
                retrying fails the same way, call list_reclaimable_storage before reporting it.
                """
        }

        let seen = signature.map { " The error itself says “\($0)”." } ?? ""
        return """
            Threading: \(room ?? "this Mac's data volume is nearly full"), so this failure may be \
            the disk running out of space.\(seen) Build tools often report that as something \
            else — “database or disk is full”, “has been modified since the module file was \
            built”, “unexpected incomplete target”, a linker or lipo failure — so read the last \
            error, not the first. Before retrying or reporting failure, call \
            list_reclaimable_storage, lead with what it marks ORPHANED, and put what to free to \
            the user with propose_storage_cleanup. Do not delete build output yourself.
            """
    }

    /// The disk-full message an error carries, or nil. Lowercased comparison over a bounded
    /// suffix: the payload's error is a tool's whole output, and the cause is printed last.
    ///
    /// The disguises count only while the disk is short. A module file modified mid-build or an
    /// incomplete target also happens on a disk with plenty of room, and calling that a full disk
    /// would send an agent to the storage tools for a compiler error.
    nonisolated static func signature(in error: String, includingDisguises: Bool) -> String? {
        let tail = error.suffix(DiskPressureNoticeDefaults.errorBytes).lowercased()
        let candidates = DiskPressureNoticeDefaults.statements
            + (includingDisguises ? DiskPressureNoticeDefaults.disguises : [])
        return candidates.first { tail.contains($0) }
    }
}

/// The few payload fields the notice reads, copied out of the untyped hook JSON so only Sendable
/// values cross into the main actor.
struct DiskPressureFailure: Sendable, Equatable {
    let error: String?
    let isInterrupt: Bool

    init(error: String?, isInterrupt: Bool) {
        self.error = error
        self.isInterrupt = isInterrupt
    }

    init(_ payload: [String: Any]) {
        let error = payload["error"] as? String
            ?? (payload["tool_response"] as? String)
        self.init(
            error: error.map { String($0.suffix(DiskPressureNoticeDefaults.errorBytes)) },
            isInterrupt: payload["is_interrupt"] as? Bool ?? false
        )
    }
}

enum DiskPressureNoticeDefaults {
    /// How long one session hears nothing more after being told.
    static let repeatInterval: TimeInterval = 10 * 60

    /// How much of a failure's output is searched: the cause is printed last.
    static let errorBytes = 16_384

    /// Lowercased messages that say the disk is full in so many words. Each is enough on its own.
    static let statements = [
        "no space left on device",
        "enospc",
        "disk quota exceeded",
        "database or disk is full",
        "not enough space"
    ]

    /// Lowercased messages Xcode prints when a full disk left a cache or build database half
    /// written, without saying why. Evidence only alongside a short disk.
    static let disguises = [
        "has been modified since the module file",
        "unexpected incomplete target"
    ]
}
