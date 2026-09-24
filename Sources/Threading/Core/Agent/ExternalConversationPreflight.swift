import Darwin
import Foundation
import ThreadingPTYHostKit

/// Refuses a resume whose provider identifier is already owned by another live CLI process.
///
/// The process-table walk is deliberately separate from the launch controller: it runs off the
/// main actor, reads argument vectors only for processes whose executable name matches, and
/// returns no command-line text. A conversation identifier is user data; it is used for the exact
/// comparison and never copied into logs or the failure shown in the pane.
enum ExternalConversationPreflight {
    static func runningProcessID(
        executableName: String,
        transcriptID: String,
        sessionID: SessionID? = nil,
        hostedSessions: () -> [PTYHostSessionSummary] = { [] },
        processTable: () -> [pid_t: ProcessSummary] = ProcessUtility.processTable,
        commandLine: (pid_t) -> ProcessCommandLine? = {
            ProcessUtility.commandLine(forPid: $0)
        }
    ) -> pid_t? {
        let expectedExecutable = (executableName as NSString).lastPathComponent
        guard !expectedExecutable.isEmpty, !transcriptID.isEmpty else { return nil }

        let table = processTable()
        var sameSessionHostedRoots: Set<pid_t>?
        for pid in table.keys.sorted() {
            guard let summary = table[pid],
                  (summary.command as NSString).lastPathComponent == expectedExecutable,
                  let invocation = commandLine(pid),
                  invocationNamesExecutable(invocation, expected: expectedExecutable),
                  resumes(transcriptID, in: invocation.arguments)
            else { continue }

            // A checkout move or startup recovery can relaunch while threading-ptyd still owns
            // this row's previous process. That process is not an external owner: the persistent
            // spawn's `replaceExisting` request is the authority that orders its exit before the
            // replacement starts. Trust only a fresh daemon answer for this exact Threading row,
            // then prove the matching Codex process descends from the root it reports. Missing or
            // ambiguous evidence remains a refusal.
            if let sessionID {
                let roots: Set<pid_t>
                if let sameSessionHostedRoots {
                    roots = sameSessionHostedRoots
                } else {
                    let identity = PTYHostSessionIdentity.agentSession(sessionID)
                    roots = Set(hostedSessions().compactMap { hosted in
                        guard hosted.id == identity, hosted.exit == nil else { return nil }
                        return hosted.pid
                    })
                    sameSessionHostedRoots = roots
                }
                if descendsFromHostedRoot(pid, roots: roots, processTable: table) {
                    continue
                }
            }
            return pid
        }
        return nil
    }

    static func launchFailure(kind: AgentKind, transcriptPath: String?) -> SessionLaunchFailure {
        let diagnosis = SessionLaunchDiagnosis.identifierInUse(kind: kind)
        return SessionLaunchFailure(
            origin: .preflight,
            summary: diagnosis.summary,
            transcriptPath: transcriptPath,
            knownCause: diagnosis.knownCause
        )
    }

    private static func invocationNamesExecutable(
        _ invocation: ProcessCommandLine,
        expected: String
    ) -> Bool {
        let executable = (invocation.executablePath as NSString).lastPathComponent
        let argumentZero = invocation.arguments.first.map { ($0 as NSString).lastPathComponent }
        return executable == expected || argumentZero == expected
    }

    /// Flags may precede `resume`, but the identifier remains its immediate operand in the
    /// measured Codex launch contract. Requiring the pair avoids treating an identifier merely
    /// mentioned in a prompt or configuration value as ownership of the conversation.
    private static func resumes(_ transcriptID: String, in arguments: [String]) -> Bool {
        guard arguments.count >= 2 else { return false }
        for index in arguments.indices.dropLast()
            where arguments[index] == "resume" && arguments[index + 1] == transcriptID
        {
            return true
        }
        return false
    }

    private static func descendsFromHostedRoot(
        _ pid: pid_t,
        roots: Set<pid_t>,
        processTable: [pid_t: ProcessSummary]
    ) -> Bool {
        guard !roots.isEmpty else { return false }

        var current = pid
        var visited = Set<pid_t>()
        while current > 0, visited.insert(current).inserted {
            if roots.contains(current) { return true }
            guard let summary = processTable[current] else { return false }
            current = summary.parentPid
        }
        return false
    }
}
