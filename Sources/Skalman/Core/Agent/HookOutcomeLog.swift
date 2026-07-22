import Foundation

// MARK: - Hook Outcome Log

/// Records hooks that failed, from the CLI's own account of running them.
///
/// This exists for the one failure the app cannot otherwise see. Every other problem with a hook
/// leaves a trace here — a report that arrived and was refused is logged where it was refused,
/// and a decision that was made is logged by the permission route. But a hook that **never
/// reaches this app** — curl refused, the listener gone, the request timed out — produces
/// nothing at all on this side, because nothing arrived. Meanwhile the agent has silently had a
/// tool blocked and is waiting.
///
/// `--include-hook-events` is the answer, and it is the only reason that flag is passed: Claude
/// emits a `hook_response` per hook it ran, carrying the `outcome` and `exit_code` this app
/// never got to observe. Deliberately *not* routed through `StreamEvent`, which is a pure
/// function feeding the conversation's rendering — a diagnostic that nothing draws does not
/// belong in the model the views are built from.
enum HookOutcomeLog {

    // MARK: - Public Methods

    /// Inspects one raw `stream-json` line and records it if it reports a hook that failed.
    static func note(line: String, sessionID: SessionID) {
        guard let failure = failure(inLine: line) else { return }

        SkalmanLogger.agent.error(
            """
            Hook \(failure.hookName, privacy: .public) \(failure.outcome, privacy: .public) \
            (exit \(failure.exitCode, privacy: .public))
            """
        )
        EventLog.shared.record(.hooks, "Agent reported a hook failure", [
            "session": sessionID.uuidString,
            "hook": failure.hookName,
            "outcome": failure.outcome,
            "exitCode": failure.exitCode,
            "stderr": failure.stderr
        ])
    }

    /// The failure a line describes, or nil for every line that is not one.
    ///
    /// Split out from `note` so the decisions here can be tested without standing up a stream
    /// or reading a journal — which of these lines matter is the whole of the logic, and the
    /// logging around it is not.
    ///
    /// The substring test comes first because this runs on every line of every stream, and
    /// almost none of them are about hooks — decoding each one to find that out would make the
    /// diagnostic cost more than the thing it diagnoses.
    static func failure(inLine line: String) -> Failure? {
        guard line.contains(Key.subtypeMarker) else { return nil }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object[Key.subtype] as? String == Key.hookResponse else {
            return nil
        }

        // A missing outcome is treated as a failure rather than ignored: this runs against a
        // schema owned by someone else, and a release that renames the field should make the
        // journal noisy rather than make it silently stop reporting.
        let outcome = object[Key.outcome] as? String ?? "unknown"
        guard outcome != Key.success else { return nil }

        return Failure(
            hookName: object[Key.hookName] as? String ?? "unknown",
            outcome: outcome,
            exitCode: (object[Key.exitCode] as? Int).map(String.init) ?? "none",
            stderr: String(
                (object[Key.stderr] as? String ?? "")
                    .prefix(HookOutcomeDefaults.maximumStderrCharacters)
            )
        )
    }

    // MARK: - Types

    struct Failure: Equatable {
        let hookName: String
        let outcome: String
        let exitCode: String
        let stderr: String
    }

    // MARK: - Private Types

    private enum Key {
        /// Cheap pre-filter, matched before anything is decoded.
        static let subtypeMarker = "hook_response"

        static let subtype = "subtype"
        static let hookResponse = "hook_response"
        static let hookName = "hook_name"
        static let outcome = "outcome"
        static let exitCode = "exit_code"
        static let stderr = "stderr"
        static let success = "success"
    }
}

// MARK: - Defaults

enum HookOutcomeDefaults {
    /// A failing hook's stderr can be arbitrarily long, and the journal is appended
    /// synchronously — enough to identify the failure, not enough to bury the record after it.
    static let maximumStderrCharacters = 500
}
