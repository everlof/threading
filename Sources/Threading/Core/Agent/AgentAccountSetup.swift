import Darwin
import Foundation

/// The providers whose official CLI authentication flow Threading can safely orchestrate.
///
/// This is deliberately narrower than `AgentKind.supportsAccounts`: each case below is a
/// measured provider adapter with a login command, a status command, and an isolated home.
enum AgentAccountSetupProvider: String, CaseIterable, Sendable {
    case claude
    case codex

    var kind: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    init?(kind: AgentKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .grok, .openCode, .cursor: return nil
        }
    }

    var environmentKey: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        }
    }

    var directoryPrefix: String {
        switch self {
        case .claude: return AgentAccountDefaults.claudeDirectoryPrefix
        case .codex: return AgentAccountDefaults.codexDirectoryPrefix
        }
    }

    var loginArguments: [String] {
        switch self {
        case .claude:
            return ["auth", "login"]
        case .codex:
            // App-created Codex homes use the documented file store. This preserves isolation
            // between homes and leaves the provider-owned auth marker discovery can prove.
            return ["login", "-c", "cli_auth_credentials_store=\"file\""]
        }
    }

    var statusArguments: [String] {
        switch self {
        case .claude:
            return ["auth", "status", "--json"]
        case .codex:
            return ["login", "status", "-c", "cli_auth_credentials_store=\"file\""]
        }
    }

    var installationGuide: URL {
        switch self {
        case .claude:
            return URL(string: "https://code.claude.com/docs/en/setup")!
        case .codex:
            return URL(string: "https://developers.openai.com/codex/cli")!
        }
    }

    /// Whether this CLI's printed fallback URL finishes by reading a code back from its stdin.
    ///
    /// Measured from each CLI's own output rather than assumed. Codex prints the same
    /// `http://localhost:<port>/…` redirect it handed the browser, so its link completes on its
    /// own in any browser on this Mac. Claude Code keeps the loopback redirect for the browser it
    /// launches and prints a *different* URL, one that redirects to a page displaying a code — so
    /// its link is only usable if that code has somewhere to go. See
    /// [`accounts.md`](../../../../docs/architecture/accounts.md).
    var acceptsPastedSignInCode: Bool {
        switch self {
        case .claude: return true
        case .codex: return false
        }
    }
}

struct AgentAccountSetupContext: Equatable, Sendable {
    let provider: AgentAccountSetupProvider
    let displayName: String
    let handle: AccountHandle
    let configPath: String
    let isReconnect: Bool
}

enum AgentAccountSetupFailure: Equatable, Sendable {
    case invalidName
    case locationAlreadyExists
    case couldNotPrepareLocation
    case cliMissing
    case couldNotStart
    case signInFailed
    case timedOut
    case verificationFailed
}

enum AgentAccountSetupState: Equatable, Sendable {
    case choice
    case naming(AgentAccountSetupProvider)
    /// A login in progress, plus the link it has printed for a browser of the person's choosing
    /// once the CLI has printed one. Nil is the ordinary first moment, not a failure.
    case running(AgentAccountSetupContext, prompt: AgentAccountSignInPrompt?)
    case failed(
        provider: AgentAccountSetupProvider,
        attemptedName: String,
        context: AgentAccountSetupContext?,
        failure: AgentAccountSetupFailure
    )
    case succeeded(AgentAccount)
}

enum AgentAccountSetupDefaults {
    static let loginTimeout: TimeInterval = 10 * 60
    static let verificationTimeout: TimeInterval = 10
    static let terminationGrace: TimeInterval = 2
    static let maximumStatusBytes = 64 * 1_024
    static let maximumSlugLength = 24
}

/// Coordinates one short-lived provider login without taking ownership of credentials.
///
/// The provider CLI opens its own browser flow under an isolated config home. Threading sends
/// no secret over stdin, captures no login output, and registers the location only after the
/// CLI's status command succeeds under that same environment.
@MainActor
final class AgentAccountSetupCoordinator {

    var onStateChange: ((AgentAccountSetupState) -> Void)?
    var onAccountReady: ((AgentAccount) -> Void)?

    private(set) var state: AgentAccountSetupState {
        didSet { onStateChange?(state) }
    }

    private var activeAttemptID: UUID?
    private var activeChild: SpawnedChildProcess?
    private var timeoutTask: Task<Void, Never>?

    /// The login's own output, read only until it yields the sign-in URL and drained after that
    /// so the CLI is never stopped by a pipe nobody is emptying.
    private var activeOutput: ChildOutputStream?

    /// The login's stdin, kept open for the one thing it is for: handing back the code the
    /// provider's fallback page displays.
    private var activeInput: AgentAccountSignInInput?

    private var scanner = AgentAccountSignInScanner()

    init(initialState: AgentAccountSetupState = .choice) {
        self.state = initialState
    }

    deinit {
        activeChild?.terminate()
        timeoutTask?.cancel()
        activeOutput?.cancel()
        activeInput?.close()
    }

    func choose(_ provider: AgentAccountSetupProvider) {
        guard activeChild == nil else { return }
        state = .naming(provider)
    }

    func start(provider: AgentAccountSetupProvider, displayName: String) {
        let attemptedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context = Self.newContext(
            provider: provider,
            displayName: attemptedName,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) else {
            state = .failed(
                provider: provider,
                attemptedName: attemptedName,
                context: nil,
                failure: .invalidName
            )
            return
        }

        let pathAlreadyRegistered = AgentAccountLocationRegistry.shared.contains(
            provider: provider.kind,
            configPath: context.configPath
        )
        let pathAlreadyDiscovered = AgentAccountDiscovery.allAccounts(for: provider.kind).contains {
            URL(fileURLWithPath: $0.configPath).standardizedFileURL.path == context.configPath
        }
        guard !pathAlreadyRegistered, !pathAlreadyDiscovered else {
            state = .failed(
                provider: provider,
                attemptedName: attemptedName,
                context: context,
                failure: .locationAlreadyExists
            )
            return
        }
        begin(context)
    }

    func reconnect(_ account: AgentAccount) {
        guard let provider = AgentAccountSetupProvider(kind: account.provider) else { return }
        begin(AgentAccountSetupContext(
            provider: provider,
            displayName: account.displayName,
            handle: account.handle,
            configPath: account.configPath,
            isReconnect: true
        ))
    }

    func retry() {
        guard case let .failed(provider, _, context, _) = state else { return }
        if let context {
            begin(context)
        } else {
            state = .naming(provider)
        }
    }

    /// Hands the code a provider's fallback page displayed back to the CLI waiting for it.
    ///
    /// The code is written straight through to the child and kept nowhere else: not logged, not
    /// stored, not part of any state this object publishes. It is a single-use authorization
    /// code, and the PKCE verifier that redeems it never leaves the CLI, so this remains a
    /// keystroke relay rather than Threading holding a credential.
    func submitPastedCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .running(context, prompt) = state,
              let prompt, prompt.acceptsPastedCode,
              !trimmed.isEmpty,
              activeChild?.isRunning == true,
              let input = activeInput else { return }

        input.write(Data((trimmed + "\n").utf8))
        var acknowledged = prompt
        acknowledged.hasSentCode = true
        state = .running(context, prompt: acknowledged)
    }

    func cancel() {
        let child = activeChild
        activeAttemptID = nil
        activeChild = nil
        endChildStreams()
        timeoutTask?.cancel()
        timeoutTask = nil
        state = .choice

        guard let child else { return }
        child.terminate()
        Task.detached(priority: .utility) {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(AgentAccountSetupDefaults.terminationGrace * 1_000_000_000)
                )
            } catch {
                return
            }
            if child.isRunning { child.kill() }
        }
    }

    func finish() {
        guard activeChild == nil else { return }
        state = .choice
    }

    static func newContext(
        provider: AgentAccountSetupProvider,
        displayName: String,
        homeDirectory: URL
    ) -> AgentAccountSetupContext? {
        let folded = displayName
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        var slug = ""
        var lastWasSeparator = false
        for scalar in folded.unicodeScalars {
            let isASCIIAlphaNumeric = ("a"..."z").contains(Character(String(scalar)))
                || ("0"..."9").contains(Character(String(scalar)))
            if isASCIIAlphaNumeric {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !slug.isEmpty, !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
            if slug.count >= AgentAccountSetupDefaults.maximumSlugLength { break }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }

        let directoryName = provider.directoryPrefix + slug
        let directory = homeDirectory.appendingPathComponent(directoryName, isDirectory: true)
        return AgentAccountSetupContext(
            provider: provider,
            displayName: displayName,
            handle: .named(String(directoryName.dropFirst())),
            configPath: directory.standardizedFileURL.path,
            isReconnect: false
        )
    }

    private func begin(_ context: AgentAccountSetupContext) {
        guard activeChild == nil else { return }
        let attemptID = UUID()
        let shell = AgentLauncher.loginShellPath
        activeAttemptID = attemptID
        scanner = AgentAccountSignInScanner()
        state = .running(context, prompt: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let executable = AgentCLIProbe.locate(
                context.provider.kind.executableName,
                shell: shell
            )
            let prepared: Bool
            if executable == nil {
                // Do not leave an empty provider home behind merely because the CLI is absent.
                prepared = false
            } else if FileManager.default.fileExists(atPath: context.configPath) {
                let values = try? URL(fileURLWithPath: context.configPath).resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                prepared = values?.isDirectory == true && values?.isSymbolicLink != true
            } else {
                do {
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: context.configPath),
                        withIntermediateDirectories: false
                    )
                    prepared = true
                } catch {
                    prepared = false
                }
            }

            Task { @MainActor in
                guard let self, self.activeAttemptID == attemptID else { return }
                guard let executable else {
                    self.fail(context, attemptedName: context.displayName, .cliMissing)
                    return
                }
                guard prepared else {
                    self.fail(context, attemptedName: context.displayName, .couldNotPrepareLocation)
                    return
                }
                self.launch(executable: executable, context: context, attemptID: attemptID)
            }
        }
    }

    private func launch(
        executable: String,
        context: AgentAccountSetupContext,
        attemptID: UUID
    ) {
        var environment = ProcessInfo.processInfo.environment
        environment[context.provider.environmentKey] = context.configPath

        // Three `/dev/null`s used to be the whole point: a login Threading could not read was a
        // login Threading could not leak. What it also meant was that the URL the CLI prints for
        // "if the browser didn't open" went nowhere, so the only browser this flow could ever
        // finish in was the one LaunchServices picked. The pipes below carry that one line and
        // the code that answers it; nothing read here is stored, logged or kept past the attempt.
        let inputPipe: ChildPipe
        let outputPipe: ChildPipe
        do {
            inputPipe = try ChildPipe()
            // A CLI that exits between the browser opening and a code being pasted must make the
            // write an ordinary error, not a signal that ends Threading.
            guard fcntl(inputPipe.writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
                inputPipe.closeBothEnds()
                fail(context, attemptedName: context.displayName, .couldNotStart)
                return
            }
            outputPipe = try ChildPipe(closingOnFailure: [inputPipe])
        } catch {
            fail(context, attemptedName: context.displayName, .couldNotStart)
            return
        }

        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: executable),
                arguments: context.provider.loginArguments,
                environment: environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor:
                        .inherited(inputPipe.readEnd),
                    AgentChildProcessDefaults.standardOutputDescriptor:
                        .inherited(outputPipe.writeEnd),
                    // The two adapters print their fallback URL on different streams — Claude on
                    // stdout, Codex on stderr — and nothing here parses structured output, so
                    // merging them is one reader instead of two and loses nothing.
                    AgentChildProcessDefaults.standardErrorDescriptor:
                        .inherited(outputPipe.writeEnd)
                ]
            )
        } catch {
            inputPipe.closeBothEnds()
            outputPipe.closeBothEnds()
            fail(context, attemptedName: context.displayName, .couldNotStart)
            return
        }

        // The child owns its duplicated ends now. Keeping the parent's copy of the writer would
        // hold the reader open past the child's exit and leave the stream armed forever.
        inputPipe.closeReadEnd()
        outputPipe.closeWriteEnd()
        activeInput = AgentAccountSignInInput(writeEnd: inputPipe.takeWriteDescriptor())
        activeOutput = ChildOutputStream(readEnd: outputPipe.takeReadDescriptor()) {
            [weak self] data in
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.observeSignInOutput(text, attemptID: attemptID)
            }
        }

        activeChild = child
        child.observeExit { [weak self] status in
            Task { @MainActor in
                self?.loginDidExit(
                    status: status,
                    executable: executable,
                    environment: environment,
                    context: context,
                    attemptID: attemptID
                )
            }
        }
        timeoutTask = Task.detached(priority: .utility) { [weak self, child] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(AgentAccountSetupDefaults.loginTimeout * 1_000_000_000)
                )
            } catch {
                return
            }
            child.terminate()
            try? await Task.sleep(
                nanoseconds: UInt64(AgentAccountSetupDefaults.terminationGrace * 1_000_000_000)
            )
            if child.isRunning { child.kill() }
            await self?.timedOut(context: context, attemptID: attemptID)
        }
    }

    /// Publishes the sign-in link the moment the CLI prints it, and ignores everything else the
    /// login says. The scanner stops looking after the first URL, so this is O(1) per burst from
    /// then on while the pipe keeps draining.
    private func observeSignInOutput(_ text: String, attemptID: UUID) {
        guard activeAttemptID == attemptID,
              case let .running(context, prompt) = state,
              prompt == nil,
              let url = scanner.consume(text) else { return }

        state = .running(context, prompt: AgentAccountSignInPrompt(
            url: url,
            acceptsPastedCode: context.provider.acceptsPastedSignInCode
        ))
    }

    /// Ends this attempt's pipes. Safe to call more than once, and required on every path out:
    /// a stream left armed owns a descriptor, and a writer left open is a login that never sees
    /// end-of-file.
    private func endChildStreams() {
        activeOutput?.cancel()
        activeOutput = nil
        activeInput?.close()
        activeInput = nil
    }

    private func loginDidExit(
        status: Int32,
        executable: String,
        environment: [String: String],
        context: AgentAccountSetupContext,
        attemptID: UUID
    ) {
        guard activeAttemptID == attemptID else { return }
        activeChild = nil
        endChildStreams()
        timeoutTask?.cancel()
        timeoutTask = nil
        guard status == 0 else {
            fail(context, attemptedName: context.displayName, .signInFailed)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let verified: Bool
            do {
                let result = try BoundedChildProcess.run(
                    executable: executable,
                    arguments: context.provider.statusArguments,
                    environment: environment,
                    timeout: AgentAccountSetupDefaults.verificationTimeout,
                    maximumOutputBytes: AgentAccountSetupDefaults.maximumStatusBytes
                )
                verified = result.termination == .exited(0)
            } catch {
                verified = false
            }
            Task { @MainActor in
                guard let self, self.activeAttemptID == attemptID else { return }
                if verified {
                    self.complete(context)
                } else {
                    self.fail(context, attemptedName: context.displayName, .verificationFailed)
                }
            }
        }
    }

    private func timedOut(context: AgentAccountSetupContext, attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        activeChild = nil
        timeoutTask = nil
        fail(context, attemptedName: context.displayName, .timedOut)
    }

    private func complete(_ context: AgentAccountSetupContext) {
        activeAttemptID = nil
        endChildStreams()
        guard AgentAccountLocationRegistry.shared.register(
            provider: context.provider.kind,
            handle: context.handle,
            configPath: context.configPath
        ) else {
            fail(context, attemptedName: context.displayName, .verificationFailed)
            return
        }

        let id = AccountID(provider: context.provider.kind, handle: context.handle)
        if !context.isReconnect {
            AccountPreferencesStore.shared.setDisplayNameOverride(context.displayName, for: id)
        }
        AgentAccountDiscovery.invalidate()
        let account = AgentAccountDiscovery.allAccounts(for: context.provider.kind)
            .first { $0.handle == context.handle }
            ?? AgentAccount(
                provider: context.provider.kind,
                handle: context.handle,
                configPath: context.configPath,
                displayName: context.displayName
            )
        state = .succeeded(account)
        onAccountReady?(account)
        NotificationCenter.default.post(ProjectsDidChange())
    }

    private func fail(
        _ context: AgentAccountSetupContext,
        attemptedName: String,
        _ failure: AgentAccountSetupFailure
    ) {
        activeAttemptID = nil
        activeChild = nil
        endChildStreams()
        timeoutTask?.cancel()
        timeoutTask = nil
        state = .failed(
            provider: context.provider,
            attemptedName: attemptedName,
            context: context,
            failure: failure
        )
    }
}
