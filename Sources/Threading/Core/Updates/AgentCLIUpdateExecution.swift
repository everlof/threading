import Foundation

/// The update-time answer for one tool. Discovery is repeated after the user presses Update so a
/// daily notice never assumes that yesterday's executable path or version still describes today.
enum AgentCLIUpdateExecutionItem: Equatable, Sendable {
    case ready(update: AgentCLIUpdate, resolved: ResolvedAgentCLI)
    case alreadyCurrent(update: AgentCLIUpdate, resolved: ResolvedAgentCLI)
    case failed(update: AgentCLIUpdate, reason: AgentCLIUpdateFailure.Reason)

    var update: AgentCLIUpdate {
        switch self {
        case .ready(let update, _), .alreadyCurrent(let update, _), .failed(let update, _):
            return update
        }
    }
}

/// One explicit, visible run of the provider-authored commands behind an update notice.
///
/// Preflight resolves every executable again through the shared login-environment resolver. The
/// resulting plan contains absolute paths, typed arguments and the PATH needed by `env` shebangs;
/// the visible runner therefore never sources a user profile or asks a second shell to find a CLI.
struct AgentCLIUpdateExecutionPlan: Equatable, Sendable {
    let items: [AgentCLIUpdateExecutionItem]

    init(items: [AgentCLIUpdateExecutionItem]) {
        precondition(!items.isEmpty, "An update run requires at least one tool")
        precondition(
            items.count <= AgentCLIUpdateCatalog.all.count,
            "An update run cannot exceed the fixed provider catalog"
        )
        self.items = items
    }

    var updates: [AgentCLIUpdate] { items.map(\.update) }

    var shellSource: String { shellCommand.source }

    /// Kept as words until the terminal process is launched. The complete source can exceed a
    /// tty's input queue even when every physical line is short, so it must travel in argv rather
    /// than being typed after the shell starts.
    var shellCommand: ShellCommand {
        AgentCLIUpdateShellCommand.command(for: items)
    }

    static func prepare(
        updates: [AgentCLIUpdate],
        shell: String
    ) async -> AgentCLIUpdateExecutionPlan {
        let resolver = AgentCLILocalResolver(shell: shell)
        return await prepare(updates: updates) { update in resolver.resolve(update) }
    }

    /// Injectable so the state transition can be tested without reading the developer's shell
    /// profile or launching an installed provider CLI.
    static func prepare(
        updates: [AgentCLIUpdate],
        resolve: @escaping @Sendable (
            AgentCLIUpdate
        ) -> Result<ResolvedAgentCLI?, AgentCLIUpdateFailure.Reason>
    ) async -> AgentCLIUpdateExecutionPlan {
        precondition(!updates.isEmpty, "An update run requires at least one tool")
        precondition(
            updates.count <= AgentCLIUpdateCatalog.all.count,
            "An update run cannot exceed the fixed provider catalog"
        )

        return await withTaskGroup(of: IndexedItem.self) { group in
            for (index, update) in updates.enumerated() {
                group.addTask {
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: resolve(update))
                        }
                    }
                    return IndexedItem(
                        index: index,
                        item: executionItem(for: update, resolution: result)
                    )
                }
            }

            var resolvedItems: [IndexedItem] = []
            resolvedItems.reserveCapacity(updates.count)
            for await item in group { resolvedItems.append(item) }
            resolvedItems.sort { $0.index < $1.index }
            return AgentCLIUpdateExecutionPlan(items: resolvedItems.map(\.item))
        }
    }

    private static func executionItem(
        for update: AgentCLIUpdate,
        resolution: Result<ResolvedAgentCLI?, AgentCLIUpdateFailure.Reason>
    ) -> AgentCLIUpdateExecutionItem {
        switch resolution {
        case .failure(let reason):
            return .failed(update: update, reason: reason)
        case .success(nil):
            return .failed(update: update, reason: .executableNotFound)
        case .success(.some(let resolved)):
            guard let installed = AgentCLIVersion(resolved.version),
                  let latest = AgentCLIVersion(update.latestVersion) else {
                return .failed(update: update, reason: .unreadableVersionOutput)
            }
            guard installed.isOlder(than: latest, comparison: update.comparison) else {
                return .alreadyCurrent(update: update, resolved: resolved)
            }
            return .ready(update: update, resolved: resolved)
        }
    }

    private struct IndexedItem: Sendable {
        let index: Int
        let item: AgentCLIUpdateExecutionItem
    }
}

struct AgentCLIUpdateExecutionReceipt: Equatable, Sendable {
    let terminalID: TerminalID
    let toolIDs: [String]
}

/// A stable POSIX wrapper sequences fixed host-authored commands in the visible PTY. It never
/// sources a profile: provider executables are absolute and each invocation receives the PATH
/// captured from the user's login environment. A failure remains local to its provider, and the
/// final receipt distinguishes verified updates, unexpected version changes, skips and failures.
enum AgentCLIUpdateShellCommand {
    static func command(for items: [AgentCLIUpdateExecutionItem]) -> ShellCommand {
        var wrapper = ShellCommand(word: AgentCLIUpdateExecutionDefaults.wrapperShell)
        wrapper.append(word: "-c")
        wrapper.append(word: script(for: items))
        return wrapper
    }

    /// Exposed beside `command` so tests can assert sequencing and quoting without decoding the
    /// outer command's shell argument.
    static func script(for items: [AgentCLIUpdateExecutionItem]) -> String {
        precondition(!items.isEmpty, "An update command requires at least one tool")

        var steps = [
            "__threading_agent_updated=0",
            "__threading_agent_changed=0",
            "__threading_agent_skipped=0",
            "__threading_agent_failed=0"
        ]

        for item in items {
            switch item {
            case .failed(let update, let reason):
                var receipt = ShellCommand(word: "printf")
                receipt.append(word: "[Threading] %s updater could not start: %s.\\n")
                receipt.append(word: update.displayName)
                receipt.append(word: reason.terminalDescription)
                steps.append(receipt.source)
                steps.append(increment(AgentCLIUpdateExecutionDefaults.failedVariable))

            case .alreadyCurrent(let update, let resolved):
                var receipt = ShellCommand(word: "printf")
                receipt.append(word: "[Threading] %s is already current at %s; skipping.\\n")
                receipt.append(word: update.displayName)
                receipt.append(word: resolved.version)
                steps.append(receipt.source)
                steps.append(increment(AgentCLIUpdateExecutionDefaults.skippedVariable))

            case .ready(let update, let resolved):
                steps.append(readyScript(update: update, resolved: resolved))
            }
        }

        var completion = ShellCommand(word: "printf")
        completion.append(
            word: "\\n[Threading] Agent tool update run finished: %d updated, %d changed, %d skipped, %d failed.\\n"
        )
        steps.append(
            completion.source
                + " \"$__threading_agent_updated\""
                + " \"$__threading_agent_changed\""
                + " \"$__threading_agent_skipped\""
                + " \"$__threading_agent_failed\""
        )
        return steps.joined(separator: "\n")
    }

    private static func readyScript(
        update: AgentCLIUpdate,
        resolved: ResolvedAgentCLI
    ) -> String {
        var heading = ShellCommand(word: "printf")
        heading.append(word: "\\n[Threading] Updating %s from %s to %s.\\n")
        heading.append(word: update.displayName)
        heading.append(word: resolved.version)
        heading.append(word: update.latestVersion)

        let executable = ShellCommand(word: resolved.executablePath).source
        let updateCommand = providerCommand(
            executablePath: resolved.executablePath,
            effectivePATH: resolved.effectivePATH,
            arguments: update.updateArguments
        )
        let versionCommand = providerCommand(
            executablePath: resolved.executablePath,
            effectivePATH: resolved.effectivePATH,
            arguments: update.versionArguments
        )

        var disappeared = ShellCommand(word: "printf")
        disappeared.append(word: "[Threading] %s updater could not start: the resolved executable disappeared.\\n")
        disappeared.append(word: update.displayName)

        var exited = ShellCommand(word: "printf")
        exited.append(word: "[Threading] %s updater failed with exit code %d.\\n")
        exited.append(word: update.displayName)

        var unreadable = ShellCommand(word: "printf")
        unreadable.append(word: "[Threading] %s updater exited successfully, but its installed version could not be read.\\n")
        unreadable.append(word: update.displayName)

        var unchanged = ShellCommand(word: "printf")
        unchanged.append(word: "[Threading] %s updater exited successfully, but the version remains %s.\\n")
        unchanged.append(word: update.displayName)
        unchanged.append(word: resolved.version)

        var updated = ShellCommand(word: "printf")
        updated.append(word: "[Threading] %s updated from %s to %s.\\n")
        updated.append(word: update.displayName)
        updated.append(word: resolved.version)

        var changed = ShellCommand(word: "printf")
        changed.append(word: "[Threading] %s changed from %s to %s; the announced target was %s.\\n")
        changed.append(word: update.displayName)
        changed.append(word: resolved.version)
        changed.append(word: update.latestVersion)

        let extraction = versionExtraction(command: versionCommand.source)
        let quotedExpected = ShellCommand(word: update.latestVersion).source
        let quotedPrevious = ShellCommand(word: resolved.version).source

        return """
        \(heading.source)
        if [ ! -x \(executable) ]; then
            \(disappeared.source)
            \(increment(AgentCLIUpdateExecutionDefaults.failedVariable))
        else
            \(updateCommand.source)
            __threading_agent_update_status=$?
            if [ "$__threading_agent_update_status" -ne 0 ]; then
                \(exited.source) "$__threading_agent_update_status"
                \(increment(AgentCLIUpdateExecutionDefaults.failedVariable))
            else
                \(extraction)
                if [ -z "$__threading_agent_after_version" ]; then
                    \(unreadable.source)
                    \(increment(AgentCLIUpdateExecutionDefaults.failedVariable))
                elif [ "$__threading_agent_after_version" = \(quotedPrevious) ]; then
                    \(unchanged.source)
                    \(increment(AgentCLIUpdateExecutionDefaults.failedVariable))
                elif [ "$__threading_agent_after_version" = \(quotedExpected) ]; then
                    \(updated.source) "$__threading_agent_after_version"
                    \(increment(AgentCLIUpdateExecutionDefaults.updatedVariable))
                else
                    \(changed.source) "$__threading_agent_after_version"
                    \(increment(AgentCLIUpdateExecutionDefaults.changedVariable))
                fi
            fi
        fi
        """
    }

    private static func providerCommand(
        executablePath: String,
        effectivePATH: String,
        arguments: [String]
    ) -> ShellCommand {
        var command = ShellCommand(word: AgentCLIUpdateExecutionDefaults.environmentCommand)
        command.append(word: "\(EnvironmentKeys.path)=\(effectivePATH)")
        command.append(word: executablePath)
        command.append(words: arguments)
        return command
    }

    /// Captures only the first dotted version token from a bounded prefix of stdout. A provider
    /// that emits an endless or malformed version response cannot grow a shell variable without
    /// limit, and stderr remains visible only for the updater itself rather than becoming data.
    private static func versionExtraction(command: String) -> String {
        var byteLimit = ShellCommand(word: AgentCLIUpdateExecutionDefaults.headCommand)
        byteLimit.append(
            flag: "-c",
            value: String(AgentCLIUpdateExecutionDefaults.maximumVersionBytes)
        )

        var extract = ShellCommand(word: AgentCLIUpdateExecutionDefaults.sedCommand)
        extract.append(flag: "-E")
        extract.append(flag: "-n")
        extract.append(word: AgentCLIUpdateExecutionDefaults.versionExpression)

        var firstLine = ShellCommand(word: AgentCLIUpdateExecutionDefaults.headCommand)
        firstLine.append(flag: "-n", value: "1")

        return "__threading_agent_after_version=$(\(command) 2>/dev/null"
            + " | \(byteLimit.source)"
            + " | \(extract.source)"
            + " | \(firstLine.source))"
    }

    private static func increment(_ variable: String) -> String {
        "\(variable)=$((\(variable) + 1))"
    }
}

private enum AgentCLIUpdateExecutionDefaults {
    static let wrapperShell = "/bin/sh"
    static let environmentCommand = "/usr/bin/env"
    static let headCommand = "/usr/bin/head"
    static let sedCommand = "/usr/bin/sed"
    static let maximumVersionBytes = 64 * 1_024
    static let versionExpression = #"s/^[^0-9]*([0-9]+(\.[0-9]+)+(-[0-9A-Za-z.-]+)?).*/\1/p"#
    static let updatedVariable = "__threading_agent_updated"
    static let changedVariable = "__threading_agent_changed"
    static let skippedVariable = "__threading_agent_skipped"
    static let failedVariable = "__threading_agent_failed"
}
