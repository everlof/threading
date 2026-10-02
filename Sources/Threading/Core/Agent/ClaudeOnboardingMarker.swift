import Darwin
import Foundation

/// Marks Claude Code's own first-run walkthrough finished in a home whose login was just verified.
///
/// `claude auth login` stores the credential and writes `oauthAccount` into `<home>/.claude.json`,
/// but its browser path never sets `hasCompletedOnboarding` — only its refresh-token path does
/// (read from the 2.1.287 bundle). The first interactive `claude` in that home then runs the
/// walkthrough, and for a subscription install the walkthrough's sign-in step is unconditional:
/// whoever just signed in from Settings was asked to pick a login method and sign in a second
/// time. Setting the one key the CLI's other login path sets is what makes Add Login one sign-in.
///
/// This is the only write Threading makes into a provider-owned file, so it is as narrow as it can
/// be: one key, only after the provider's own status command verified the login, never creating
/// the file, never touching anything else in it, and atomic so the CLI can never read half of it.
/// See [`accounts.md`](../../../../docs/architecture/accounts.md).
enum ClaudeOnboardingMarker {

    enum Outcome: Equatable, Sendable {
        case marked
        case alreadyComplete
        case skipped(SkipReason)
    }

    enum SkipReason: Equatable, Sendable {
        /// The login left no state file. Nothing is invented in its place.
        case missing
        case unreadable
        case tooLarge
        case notAnObject
        case writeFailed
        /// A running CLI holds the file's lock. Its next save rewrites the file from memory anyway,
        /// so writing now could only be lost or lose its write.
        case busy
    }

    enum Defaults {
        static let completedKey = "hasCompletedOnboarding"

        /// A freshly signed-in home is a few kilobytes and a busy one ~100 KiB. The bound keeps a
        /// corrupt or hostile file from becoming an unbounded read on a reconnect.
        static let maximumBytes = 4 * 1_024 * 1_024

        /// What the CLI creates the file with, used only if the original's mode cannot be read.
        static let fallbackPermissions: mode_t = 0o600
        static let temporaryPrefix = ".claude.json.threading-"

        /// The CLI serializes its own writes with `proper-lockfile`: a directory named after the
        /// file plus `.lock`, whose mtime the holder refreshes every five seconds and which counts
        /// as abandoned after ten. Taking the same lock keeps this write out of a save in flight.
        static let lockSuffix = ".lock"
        static let lockStaleness: TimeInterval = 10
        static let lockPermissions: mode_t = 0o755
    }

    /// Sets `hasCompletedOnboarding` in `<directory>/.claude.json`, leaving every other key as the
    /// CLI wrote it. Does file I/O; call it off the main actor.
    static func markComplete(inConfigDirectory directory: String) -> Outcome {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(AgentDefaults.claudeStateFile)

        var status = stat()
        guard lstat(url.path, &status) == 0 else { return .skipped(.missing) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { return .skipped(.unreadable) }

        let lock = url.path + Defaults.lockSuffix
        let ownsLock: Bool
        if mkdir(lock, Defaults.lockPermissions) == 0 {
            ownsLock = true
        } else if errno == EEXIST, !isFresh(lock: lock) {
            // Left behind by a CLI that exited without releasing it; not ours to remove.
            ownsLock = false
        } else {
            return .skipped(.busy)
        }
        defer { if ownsLock { rmdir(lock) } }
        return rewrite(url, status: status)
    }

    private static func isFresh(lock path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        let modified = TimeInterval(status.st_mtimespec.tv_sec)
            + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date().timeIntervalSince1970 - modified < Defaults.lockStaleness
    }

    private static func rewrite(_ url: URL, status: stat) -> Outcome {
        guard status.st_size <= off_t(Defaults.maximumBytes) else { return .skipped(.tooLarge) }

        guard let data = try? Data(contentsOf: url) else { return .skipped(.unreadable) }
        guard data.count <= Defaults.maximumBytes else { return .skipped(.tooLarge) }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return .skipped(.unreadable)
        }
        guard var object = parsed as? [String: Any] else { return .skipped(.notAnObject) }
        if object[Defaults.completedKey] as? Bool == true { return .alreadyComplete }

        object[Defaults.completedKey] = true
        guard let updated = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ) else { return .skipped(.writeFailed) }

        let permissions = status.st_mode & 0o777
        return replace(
            url,
            with: updated,
            permissions: permissions == 0 ? Defaults.fallbackPermissions : permissions
        ) ? .marked : .skipped(.writeFailed)
    }

    /// Writes beside the target and renames over it, so a reader sees the old file or the new one
    /// and nothing between. The temporary file is created with the original's mode rather than the
    /// process umask, since the state file names the signed-in account.
    private static func replace(_ url: URL, with data: Data, permissions: mode_t) -> Bool {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(Defaults.temporaryPrefix + UUID().uuidString)
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            permissions
        )
        guard descriptor >= 0 else { return false }

        let wrote = data.withUnsafeBytes { buffer -> Bool in
            guard var cursor = buffer.baseAddress else { return buffer.isEmpty }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
            return true
        }
        // `open` applies the umask to the mode it is given; set it outright.
        let settled = wrote && fchmod(descriptor, permissions) == 0 && fsync(descriptor) == 0
        close(descriptor)

        guard settled, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}
