import Foundation

/// Reads a test-account credential out of 1Password through its own `op` command line.
///
/// **What this provider is honestly worth.** `op read` is exactly as available from the agent's
/// own shell as it is from Threading, so this buys convenience and a no-plaintext-at-rest story —
/// **not a new boundary**. The fence is 1Password's own per-process authorization, which is
/// 1Password's to enforce and not something this file can strengthen. It is written down here
/// because the alternative is a future reader assuming the `op://` indirection is itself a
/// security property.
///
/// It exists because a person who already keeps throwaway logins in 1Password should not have to
/// copy them into a second, weaker vault to let an agent use them. The stored reference
/// (`op://Private/staging-admin`) is not a secret; the value never touches Threading's disk.
///
/// 1Password ships no WebKit extension a third-party app's `WKWebView` can load, and its macOS
/// Universal Autofill fills the *frontmost app's focused field* — which is what
/// `beginPasswordTakeover` already sets up and is a human touch, not automation. So the CLI is the
/// only honest unattended path. `browser_attach_chrome` keeps the real extension.
enum OnePasswordCLI {

    // MARK: - Defaults

    private enum Defaults {
        /// Long enough for a Touch ID prompt the user has to physically answer, short enough that
        /// a wedged `op` cannot pin the fill forever. The agent is blocked while this runs.
        static let timeout: TimeInterval = 45

        /// A reference names an item; the field is appended by us. Accepting a full field path
        /// from the user would let one entry read `.../password` for its username.
        static let usernameField = "username"
        static let passwordField = "password"

        static let scheme = "op://"

        /// How long a terminated `op` is given to close the pipe before its reader is abandoned.
        static let terminationGrace: TimeInterval = 2
    }

    // MARK: - Errors

    enum CLIError: LocalizedError {
        case notInstalled
        case timedOut
        case readFailed(String)
        case emptyPassword

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return L10n.string("The 1Password command line (op) is not installed.")
            case .timedOut:
                return L10n.string("1Password did not answer in time.")
            case .readFailed(let detail):
                return L10n.format("1Password could not read the item: %@", detail)
            case .emptyPassword:
                return L10n.string("The 1Password item has no password field.")
            }
        }
    }

    // MARK: - Availability

    /// Whether `op` is on the user's interactive `PATH`.
    ///
    /// Resolved once per process: it shells out, and the answer is drawn on every render of the
    /// Tools page. Deliberately `op --version` and **not** `op account list` — the latter can
    /// raise 1Password's own authorization prompt, and probing must never make a window appear
    /// for a settings page the user is merely looking at. An unauthorized `op` fails at fill time
    /// with its own message, which is the moment the user expects to be asked.
    nonisolated(unsafe) static let isInstalled: Bool = {
        guard let output = run(["--version"], timeout: 5) else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }()

    // MARK: - References

    /// Whether a user-typed reference is one this can use.
    ///
    /// Checked before storing rather than at fill time, so a typo is a settings error instead of
    /// a sign-in that silently hands over to the user weeks later. A field path is refused: the
    /// item is what gets stored, and the field names are ours to append.
    static func isValidItemReference(_ reference: String) -> Bool {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Defaults.scheme) else { return false }
        let path = trimmed.dropFirst(Defaults.scheme.count)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // vault/item, and nothing after it.
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }

    // MARK: - Reading

    /// One item's username and password.
    ///
    /// Two `op read` calls rather than one `op item get --format json`: the JSON form returns the
    /// item's *every* field, including ones that are none of Threading's business, and this only
    /// ever wants two. A missing username is not an error — some staging sign-ins take one field.
    static func secret(forItem reference: String) throws -> BrowserCredentialSecret {
        guard isInstalled else { throw CLIError.notInstalled }
        let item = reference.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let password = read(field: Defaults.passwordField, of: item) else {
            throw CLIError.readFailed(L10n.string("no password could be read for that item"))
        }
        guard !password.isEmpty else { throw CLIError.emptyPassword }

        let username = read(field: Defaults.usernameField, of: item)
        return BrowserCredentialSecret(
            username: username?.isEmpty == false ? username : nil,
            password: password
        )
    }

    private static func read(field: String, of item: String) -> String? {
        run(["read", "\(item)/\(field)"], timeout: Defaults.timeout)?
            .trimmingCharacters(in: .newlines)
    }

    // MARK: - Process

    /// The user's login shell, resolved without touching the main actor.
    ///
    /// `AgentLauncher.loginShellPath` is the same answer but is `@MainActor`, and this runs from a
    /// detached task so a Touch ID prompt cannot freeze the window. It deliberately does not fall
    /// back to `ProfileStorage`'s configured shell for that reason — the environment's `SHELL` is
    /// what a login shell invocation actually needs, and the terminal profile's shell is a
    /// different setting that happens to usually agree.
    private static var loginShell: String {
        ProcessInfo.processInfo.environment[EnvironmentKeys.shell] ?? "/bin/zsh"
    }

    /// Runs `op` under that login shell, for the reason `AgentLauncher.loginShellPath` states: a
    /// GUI app does not inherit the interactive `PATH`, and `op` lives wherever Homebrew or the
    /// 1Password app put it.
    ///
    /// The consequence is worth naming: the user's rc files and any `op` alias are on this value's
    /// path. That is inherent to needing their `PATH` and is stated in `agent-browser.md` rather
    /// than hidden.
    ///
    /// Standard error goes to `nullDevice` and nothing here is logged. `op` writes the value to
    /// stdout, and a diagnostic that echoed a failing command would be the one place a password
    /// could reach a log file.
    private static func run(_ arguments: [String], timeout: TimeInterval) -> String? {
        let quoted = arguments
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        // `exec`, so the process this holds *is* `op` rather than a shell that spawned it.
        // Without it `terminate()` kills the shell and leaves `op` running with the write end of
        // the pipe still open — which is both an orphaned process sitting on a Touch ID prompt
        // and a reader that never sees end-of-file.
        process.arguments = ["-l", "-c", "exec op \(quoted)"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Draining has to happen *concurrently with* the timeout, not before it.
        //
        // A pipe nothing drains fills and deadlocks the child, so the read cannot simply wait for
        // exit. But `readDataToEndOfFile` blocks until `op` closes stdout — which is to say until
        // it exits — so reading first made the deadline below unreachable: an `op` sitting on an
        // unanswered authorization prompt hung the agent's call forever, which is the one outcome
        // a timeout existed to prevent.
        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            collected.set(handle.readDataToEndOfFile())
            finished.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            // Briefly, so the pipe closes and the reader returns rather than being abandoned
            // mid-read. Its result is discarded either way: a timed-out read is not an answer.
            _ = finished.wait(timeout: .now() + Defaults.terminationGrace)
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = collected.take() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Carries the drained bytes back from the reader thread.
    ///
    /// A lock rather than a queue hop because exactly two threads touch it once each, and the
    /// timeout path has to be able to walk away from a reader that is still blocked.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        func set(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func take() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}

// MARK: - Stored References

/// Which 1Password item stands for which origin.
///
/// Threading stores **no secret** here — an `op://` reference is a name, not a credential — which
/// is why this lives in `PreferenceStore` beside the provider choice rather than in the Keychain
/// beside the test-credential vault. The same known limit applies: an agent with shell access can
/// `defaults write` it. Pointing an entry at a different item is not a way to *learn* a password,
/// and reading any item still goes through 1Password's own authorization.
enum OnePasswordItemStore {

    private static let key = "browser.onePasswordItems"

    /// Keyed by `BrowserCredentialIdentity.account`, so one origin can hold several named accounts
    /// exactly as the built-in vault does and `browser_fill_credentials` needs no second shape.
    static var items: [String: String] {
        get { PreferenceStore.shared.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { PreferenceStore.shared.set(newValue, forKey: key) }
    }

    static func identities() -> [BrowserCredentialIdentity] {
        items.keys
            .compactMap(BrowserCredentialIdentity.init(account:))
            .sorted { ($0.originKey, $0.label) < ($1.originKey, $1.label) }
    }

    static func identities(for origin: BrowserOrigin) -> [BrowserCredentialIdentity] {
        identities().filter { $0.originKey == origin.key }
    }

    static func reference(for identity: BrowserCredentialIdentity) -> String? {
        items[identity.account]
    }

    static func setReference(_ reference: String, for identity: BrowserCredentialIdentity) {
        var current = items
        current[identity.account] = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        items = current
    }

    static func remove(_ identity: BrowserCredentialIdentity) {
        var current = items
        current.removeValue(forKey: identity.account)
        items = current
    }

    static func removeAll() {
        PreferenceStore.shared.removeObject(forKey: key)
    }
}
