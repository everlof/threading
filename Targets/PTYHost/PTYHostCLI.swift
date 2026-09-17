#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import ThreadingPTYHostKit

// MARK: - Defaults

/// Everything the command-line client needs a number or a name for.
///
/// Separate from `PTYHostDefaults` because the two answer different questions. That one is the
/// daemon's own behaviour — how much it buffers, how long it holds an exited session, how fast it
/// escalates a kill — and every constant in it is load-bearing for a process holding somebody's
/// agents. These are the bounds on a tool that connects, asks one question and exits, and none of
/// them outlives the invocation.
enum PTYHostCLIDefaults {

    // MARK: - Waits

    /// How long a connect is given. A unix socket answers immediately or not at all; the deadline
    /// exists so a listener that has stopped accepting costs a bounded wait rather than a hang.
    static let connectTimeout: TimeInterval = 2

    /// How long the greeting is given. `hello` is the first frame in both directions, so a daemon
    /// that does not answer this is one nothing else can be asked of.
    static let helloTimeout: TimeInterval = 3

    /// How long any one answer is given: a session list, a journal tail, an attach.
    static let answerTimeout: TimeInterval = 5

    /// How long `stop` waits for the ending.
    ///
    /// Comfortably past the daemon's own arithmetic: `SIGTERM`, a two-second escalation grace,
    /// `SIGKILL`, and up to half a second letting the last of the child's output drain ahead of
    /// the `exited` frame. A shorter bound would report "it did not say so" about a child that
    /// was in the middle of dying.
    static let stopTimeout: TimeInterval = 10

    /// How long `launchctl` is given to answer before it is terminated and the line reads
    /// "could not be read".
    static let registrationTimeout: TimeInterval = 5

    // MARK: - Sizes

    static let readBufferBytes = 64 * 1024

    /// One read of `launchctl`'s output.
    static let processReadBufferBytes = 4 * 1024

    /// Journal lines shown when the caller names no number.
    static let defaultJournalLines = 50

    /// What one journal line is assumed to cost when turning a line count into the byte tail the
    /// wire actually carries.
    ///
    /// Generous: a line is a flat JSON object of tokens and numbers with one bounded path field,
    /// so a kilobyte apiece asks for several times what is needed and the surplus is discarded
    /// locally. The product is still clamped by the daemon's own `maximumJournalTailBytes`, which
    /// is the bound that matters — "the tail of the log" must not be a way to ask for the log.
    static let journalBytesPerLine = 1024

    /// How much of a session id a row shows. `stop` still matches a prefix of any length against
    /// the whole id, so this shortens the display and never the vocabulary.
    static let shortIdentifierLength = 8

    static let columnGap = "  "

    // MARK: - launchd

    /// The label in `codes.threading.ptyd.plist`, which ships beside this file.
    ///
    /// Restated rather than shared, for `PTYHostProcessStartTime`'s reason: the app spells it in
    /// `PTYHostRegistrationDefaults`, and a Foundation-only binary that could see that enum could
    /// see the rest of the app with it. The plist it has to agree with is in this same directory.
    static let launchAgentLabel = "codes.threading.ptyd"
    static let launchAgentPlistName = "codes.threading.ptyd.plist"

    /// Where the bundle keeps the plist, relative to `Contents`. This binary lives in
    /// `Contents/Helpers`, so the directory holding it is one level down from the same `Contents`.
    static let launchAgentsSubdirectory = "Library/LaunchAgents"

    static let launchctlPath = "/bin/launchctl"

    /// A test seam, never a user setting: the program `status` asks about the login item.
    ///
    /// The same kind of seam as `PTYHostDefaults.ringBudgetEnvironmentKey`, and for a sharper
    /// reason. There is one registered label on a machine and it belongs to the developer's own
    /// Threading, so a test that ran the real `launchctl print` against it would be reporting on
    /// whatever their app had registered — an answer that changes with their login items rather
    /// than with this code. Pointed at a script that replays a captured answer, the parser is
    /// exercised over the text it actually has to read.
    static let launchctlEnvironmentKey = "THREADING_PTY_HOST_LAUNCHCTL"

    /// What `launchctl print` says about a label it has never been given. Matched as text because
    /// the exit status does not distinguish it from a malformed domain, and those are not the
    /// same finding.
    static let launchctlMissingServiceMarker = "Could not find service"

    // MARK: - Exit codes

    /// A daemon answered.
    static let answeredExitCode = PTYHostDefaults.successExitCode

    /// Nothing answered, or the one thing that was asked for could not be done. Never used for a
    /// malformed command line, which is `EX_USAGE`.
    static let silentExitCode: Int32 = 1

    /// `EX_USAGE`, the daemon's own.
    static let usageExitCode = PTYHostDefaults.usageExitCode
}

// MARK: - Verbs

/// What the tool was asked to do.
enum PTYHostCLIVerb: String, CaseIterable {
    case status
    case sessions
    case journal
    case stop
    case help
}

/// One parsed invocation.
struct PTYHostCLIInvocation: Equatable {
    let verb: PTYHostCLIVerb
    /// The rendezvous the caller named, or nil for the one the app uses.
    let socketPath: String?
    /// The state directory the caller named, or nil for the one the app uses.
    let stateDirectory: String?
    let wantsJSON: Bool
    /// Whatever followed the verb and was not a flag.
    let positional: [String]
}

/// What a command line turned out to be.
enum PTYHostCLIParse: Equatable {
    /// A verb to run.
    case run(PTYHostCLIInvocation)
    /// Print the usage. A message means it was a mistake and the exit code is `EX_USAGE`; nil
    /// means somebody asked for help, which is not a failure.
    case usage(String?)
}

// MARK: - The client

/// `threading-ptyd <verb>`: the same daemon binary, asked about the daemon that is running.
///
/// **One binary rather than a second tool.** The client has to speak the framing, the frames and
/// the version gate exactly as the daemon does, and a separate executable would be a second place
/// for all three to drift — and a second thing to sign, embed and keep in the bundle. The daemon
/// path is unchanged: a command line that names `--socket`/`--state` or `--default-locations`
/// still starts a daemon, and only a bare verb reaches any of this.
///
/// **What it will not do.** It never sends `retire`: retirement is the app's upgrade policy, it
/// unlinks the socket, and the sessions being drained are somebody's working agents. It never
/// sends `spawn`: a session belongs to a conversation the app owns, and a child spawned from a
/// shell would be one no surface could ever show. `stop` is the one thing here that changes
/// anything, and it is the Background Sessions list's own attach-then-kill.
enum PTYHostCLI {

    // MARK: - Usage

    /// The whole of what this binary accepts, verbs and daemon forms together.
    ///
    /// One text rather than two, because the two halves are one command line: somebody who ran
    /// `threading-ptyd` by mistake needs to see that it is both a daemon and a way to ask the
    /// daemon questions.
    static let usage = """
        usage: threading-ptyd <verb> [--socket <path>] [--state <dir>]

        Verbs, spoken to the background host that is already running:
          status              whether a socket is there, whether a daemon answers, what it holds,
                              and on macOS whether launchd has the login item
          sessions [--json]   one row per held session
          journal [N]         the last N journal lines (default \
        \(PTYHostCLIDefaults.defaultJournalLines)), bounded by the daemon's own cap
          stop <id-prefix>    attach to one held session and end it
          help                this text

        Options:
          --socket <path>     the rendezvous to speak to, instead of the one the app uses
          --state <dir>       the daemon's state directory, instead of the one the app uses

        There is no follow mode. The journal is an ordinary file under the state directory, one
        JSON object per line, and `threading-ptyd status` prints its path; tail that.

        Exit codes: 0 a daemon answered, 1 none did or the session could not be ended, \
        \(PTYHostCLIDefaults.usageExitCode) this usage.

        Running the daemon itself:
               threading-ptyd --socket <path> --state <dir>
               threading-ptyd \(PTYHostDefaultLocations.defaultLocationsArgument)
        """

    // MARK: - Parsing

    /// Reads a command line, or declines it.
    ///
    /// **Nil means "this is the daemon's".** A first argument that starts with `-` belongs to the
    /// daemon's own parser, unchanged, and so does an empty command line — which that parser
    /// already refuses with this usage and `EX_USAGE`. Only a bare word reaches the verb table,
    /// so no flag the daemon takes can ever be shadowed by a verb added later.
    static func parse(_ arguments: [String]) -> PTYHostCLIParse? {
        guard let first = arguments.first else { return nil }
        if first == "--help" || first == "-h" || first == "help" { return .usage(nil) }
        guard !first.hasPrefix("-") else { return nil }

        guard let verb = PTYHostCLIVerb(rawValue: first) else {
            return .usage("threading-ptyd: \(first) is not a verb.")
        }

        var socketPath: String?
        var stateDirectory: String?
        var wantsJSON = false
        var positional: [String] = []

        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let token = arguments[index]
            switch token {
            case "--socket", "--state":
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex else {
                    return .usage("threading-ptyd: \(token) needs a value.")
                }
                let value = arguments[valueIndex]
                guard !value.isEmpty else {
                    return .usage("threading-ptyd: \(token) needs a value.")
                }
                if token == "--socket" {
                    guard socketPath == nil else {
                        return .usage("threading-ptyd: \(token) was given twice.")
                    }
                    socketPath = value
                } else {
                    guard stateDirectory == nil else {
                        return .usage("threading-ptyd: \(token) was given twice.")
                    }
                    stateDirectory = value
                }
                index = arguments.index(after: valueIndex)
            case "--json":
                guard verb == .sessions else {
                    return .usage("threading-ptyd: only `sessions` prints JSON.")
                }
                wantsJSON = true
                index = arguments.index(after: index)
            case "-f", "--follow":
                return .usage(
                    "threading-ptyd: there is no follow mode; `threading-ptyd status` prints the "
                        + "journal's path and it is an ordinary file to tail."
                )
            default:
                guard !token.hasPrefix("-") else {
                    return .usage("threading-ptyd: \(token) is not an option.")
                }
                positional.append(token)
                index = arguments.index(after: index)
            }
        }

        switch verb {
        case .status, .sessions, .help:
            guard positional.isEmpty else {
                return .usage("threading-ptyd: \(verb.rawValue) takes no arguments.")
            }
        case .journal:
            guard positional.count <= 1 else {
                return .usage("threading-ptyd: journal takes one line count at most.")
            }
            if let raw = positional.first, Int(raw).map({ $0 <= 0 }) ?? true {
                return .usage("threading-ptyd: \(raw) is not a line count.")
            }
        case .stop:
            guard positional.count == 1 else {
                return .usage("threading-ptyd: stop takes one session id prefix.")
            }
        }

        return .run(PTYHostCLIInvocation(
            verb: verb,
            socketPath: socketPath,
            stateDirectory: stateDirectory,
            wantsJSON: wantsJSON,
            positional: positional
        ))
    }

    // MARK: - Running

    /// Runs one parsed command line and answers the process's exit code.
    static func run(_ parsed: PTYHostCLIParse, build: String) -> Int32 {
        switch parsed {
        case .usage(let message):
            if let message {
                write(message, to: FileHandle.standardError)
                write(usage, to: FileHandle.standardError)
                return PTYHostCLIDefaults.usageExitCode
            }
            write(usage, to: FileHandle.standardOutput)
            return PTYHostCLIDefaults.answeredExitCode
        case .run(let invocation):
            return run(invocation, build: build)
        }
    }

    private static func run(_ invocation: PTYHostCLIInvocation, build: String) -> Int32 {
        if invocation.verb == .help {
            write(usage, to: FileHandle.standardOutput)
            return PTYHostCLIDefaults.answeredExitCode
        }

        guard let locations = Locations(invocation) else {
            write(PTYHostCLIError.noDefaultLocation.sentence, to: FileHandle.standardError)
            return PTYHostCLIDefaults.silentExitCode
        }

        switch invocation.verb {
        case .status:
            return status(locations, build: build)
        case .sessions:
            return sessions(locations, build: build, asJSON: invocation.wantsJSON)
        case .journal:
            let lines = invocation.positional.first.flatMap(Int.init)
                ?? PTYHostCLIDefaults.defaultJournalLines
            return journal(locations, build: build, lines: lines)
        case .stop:
            return stop(locations, build: build, prefix: invocation.positional[0])
        case .help:
            return PTYHostCLIDefaults.answeredExitCode
        }
    }

    // MARK: - Locations

    /// Where this invocation is pointed.
    private struct Locations {
        let socketPath: String
        let stateDirectory: String

        init?(_ invocation: PTYHostCLIInvocation) {
            let fallback = PTYHostDefaultLocations.directory()
            guard let socketPath = invocation.socketPath
                ?? fallback?
                    .appendingPathComponent(
                        PTYHostDefaultLocations.socketFileName,
                        isDirectory: false
                    )
                    .path,
                let stateDirectory = invocation.stateDirectory ?? fallback?.path
            else { return nil }
            self.socketPath = socketPath
            self.stateDirectory = stateDirectory
        }

        /// Today's journal file, named the way the daemon names it.
        var journalPath: String {
            URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent(
                    PTYHostDefaults.journalFilePrefix
                        + PTYHostCLI.day.string(from: Date())
                        + PTYHostDefaults.journalFileSuffix,
                    isDirectory: false
                )
                .path
        }
    }

    // MARK: - status

    /// What is there, in the order somebody debugging asks: the file, then whether anything
    /// answers on it, then what it holds, then whether the system was ever told to start it.
    ///
    /// Exit 0 means a daemon answered and the version gate admitted it. A refused handshake exits
    /// 1 with the reason: something is listening, but nothing here can ask it anything.
    private static func status(_ locations: Locations, build: String) -> Int32 {
        var rows: [[String]] = []
        let socketExists = FileManager.default.fileExists(atPath: locations.socketPath)
        rows.append([
            "socket",
            locations.socketPath + (socketExists ? " (present)" : " (absent)")
        ])

        var answered = false
        var client: PTYHostCLIClient?
        defer { client?.hangUp() }

        do {
            let connected = try PTYHostCLIClient.connect(
                socketPath: locations.socketPath,
                build: build
            )
            client = connected
            let hello = try connected.greet()
            answered = true
            rows.append([
                "daemon",
                "build \(hello.build), pid \(hello.pid), protocol \(hello.protocolVersion) "
                    + "(minimum \(hello.minimumSupported))"
            ])

            let summaries = try connected.list()
            let attached = summaries.filter { $0.exit == nil && $0.isAttached }.count
            let exited = summaries.filter { $0.exit != nil }.count
            let detached = summaries.count - attached - exited
            rows.append([
                "held",
                "\(summaries.count) sessions: \(attached) attached, \(detached) detached, "
                    + "\(exited) exited"
            ])

            // Ordered delivery makes this safe to read rather than wait for: the daemon queues
            // `lost` immediately behind the greeting, so an answer that has already come back
            // proves whether one was sent.
            if let lost = connected.reportedLoss(), !lost.ids.isEmpty {
                rows.append([
                    "lost",
                    "\(lost.ids.count) sessions a restart could not account for, since "
                        + iso.string(from: lost.since)
                ])
            }
        } catch let failure as PTYHostCLIError {
            rows.append(["daemon", sentenceForStatus(failure, socketExists: socketExists)])
        } catch {
            rows.append(["daemon", "nothing is listening"])
        }

        #if os(Linux)
        // A Linux host is installed and started over SSH by the Mac that uses it, not registered
        // by a bundle, so there is no login item to report. See
        // `docs/feature-drafts/remote-execution-hosts.md`, slice 2.
        rows.append(["service", "not registered by this binary on Linux"])
        #else
        if let plist = launchAgentPlistURL {
            let present = FileManager.default.fileExists(atPath: plist.path)
            rows.append(["plist", plist.path + (present ? " (present)" : " (absent)")])
        } else {
            rows.append(["plist", "not found beside this binary"])
        }
        rows.append([
            "launchd",
            PTYHostCLIDefaults.launchAgentLabel + " " + registration().sentence
        ])
        #endif
        rows.append(["journal", locations.journalPath])

        for line in PTYHostCLIFormatting.table(rows) {
            write(line, to: FileHandle.standardOutput)
        }
        return answered ? PTYHostCLIDefaults.answeredExitCode : PTYHostCLIDefaults.silentExitCode
    }

    /// `status` reports a missing socket on its own line, so the daemon line says the thing that
    /// line does not: nothing is listening there.
    private static func sentenceForStatus(
        _ failure: PTYHostCLIError,
        socketExists: Bool
    ) -> String {
        switch failure {
        case .socketMissing:
            return "nothing is listening: no socket at that path"
        case .connectFailed where socketExists:
            return "nothing is listening: the socket file is stale"
        default:
            return failure.sentence
        }
    }

    // MARK: - sessions

    private static func sessions(
        _ locations: Locations,
        build: String,
        asJSON: Bool
    ) -> Int32 {
        guard let summaries = held(locations, build: build) else {
            return PTYHostCLIDefaults.silentExitCode
        }

        if asJSON {
            write(json(for: summaries), to: FileHandle.standardOutput)
            return PTYHostCLIDefaults.answeredExitCode
        }

        guard !summaries.isEmpty else {
            write("no sessions", to: FileHandle.standardOutput)
            return PTYHostCLIDefaults.answeredExitCode
        }

        let now = Date()
        var rows: [[String]] = [["ID", "CHANNEL", "PID", "STARTED", "GRID", "STATE", "EXIT",
                                 "COMMAND"]]
        rows.append(contentsOf: summaries.map { summary in
            [
                PTYHostCLIFormatting.shortIdentifier(summary.id),
                summary.resolvedChannel.rawValue,
                String(summary.pid),
                PTYHostCLIFormatting.elapsed(since: summary.startedAt, now: now),
                PTYHostCLIFormatting.grid(summary.grid),
                PTYHostCLIFormatting.state(summary),
                PTYHostCLIFormatting.exitStatus(summary),
                PTYHostCLIFormatting.command(summary.executable)
            ]
        })
        for line in PTYHostCLIFormatting.table(rows) {
            write(line, to: FileHandle.standardOutput)
        }
        return PTYHostCLIDefaults.answeredExitCode
    }

    /// The summaries as JSON, for whatever is reading this in a script.
    ///
    /// Composed here rather than by re-encoding `PTYHostSessionSummary`, because the wire shape is
    /// the wire's: its identity is a nested `kind`/`id` object and its date is a number of seconds
    /// since a reference date neither `jq` nor a person would recognise. The keys here are the
    /// tool's own contract and are meant to stay put.
    private static func json(for summaries: [PTYHostSessionSummary]) -> String {
        let now = Date()
        let objects: [[String: Any]] = summaries.map { summary in
            [
                "id": summary.id.description,
                "shortId": PTYHostCLIFormatting.shortIdentifier(summary.id),
                "channel": summary.resolvedChannel.rawValue,
                "pid": Int(summary.pid),
                "startedAt": iso.string(from: summary.startedAt),
                "uptimeSeconds": Int(max(now.timeIntervalSince(summary.startedAt), 0).rounded()),
                "executable": summary.executable,
                "command": PTYHostCLIFormatting.command(summary.executable),
                "cols": summary.grid.cols,
                "rows": summary.grid.rows,
                "attached": summary.isAttached,
                "state": PTYHostCLIFormatting.state(summary),
                "exit": summary.exit.map { Int($0) as Any } ?? NSNull()
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: objects,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - journal

    private static func journal(_ locations: Locations, build: String, lines: Int) -> Int32 {
        do {
            let client = try PTYHostCLIClient.connect(
                socketPath: locations.socketPath,
                build: build
            )
            defer { client.hangUp() }
            try client.greet()
            // The ask is a byte tail, so the line count is turned into bytes generously and the
            // surplus is dropped here. The daemon clamps the number again on its side, which is
            // the bound that matters.
            let tail = try client.journalTail(
                maxBytes: min(
                    max(lines, 1) * PTYHostCLIDefaults.journalBytesPerLine,
                    PTYHostDefaults.maximumJournalTailBytes
                )
            )
            for line in tail.suffix(lines) {
                write(line, to: FileHandle.standardOutput)
            }
            return PTYHostCLIDefaults.answeredExitCode
        } catch let failure as PTYHostCLIError {
            write(failure.sentence, to: FileHandle.standardError)
            return PTYHostCLIDefaults.silentExitCode
        } catch {
            write(PTYHostCLIError.connectionClosed.sentence, to: FileHandle.standardError)
            return PTYHostCLIDefaults.silentExitCode
        }
    }

    // MARK: - stop

    /// Ends one held session, named by any unambiguous prefix of its id.
    ///
    /// **An ambiguous prefix is refused rather than resolved.** The alternative is picking one of
    /// them, and the two sessions a prefix reaches are two different people's turns.
    private static func stop(_ locations: Locations, build: String, prefix: String) -> Int32 {
        do {
            let client = try PTYHostCLIClient.connect(
                socketPath: locations.socketPath,
                build: build
            )
            defer { client.hangUp() }
            try client.greet()
            let summaries = try client.list()

            let needle = prefix.lowercased()
            let matches = summaries.filter { $0.id.description.lowercased().hasPrefix(needle) }
            guard let match = matches.first, matches.count == 1 else {
                if matches.isEmpty {
                    write(
                        "No session the background host holds starts with \(prefix).",
                        to: FileHandle.standardError
                    )
                } else {
                    let names = matches
                        .map { PTYHostCLIFormatting.shortIdentifier($0.id) }
                        .joined(separator: ", ")
                    write(
                        "\(matches.count) sessions start with \(prefix), so name more of the id "
                            + "(\(names)).",
                        to: FileHandle.standardError
                    )
                }
                return PTYHostCLIDefaults.silentExitCode
            }

            let short = PTYHostCLIFormatting.shortIdentifier(match.id)
            if let already = match.exit {
                write(
                    "\(short) had already ended with status \(already)",
                    to: FileHandle.standardOutput
                )
                return PTYHostCLIDefaults.answeredExitCode
            }

            guard let ending = try client.stop(match.id) else {
                write(
                    "The background host did not report \(short) ending; it may still be running.",
                    to: FileHandle.standardError
                )
                return PTYHostCLIDefaults.silentExitCode
            }
            let how = ending.signalled ? "signal \(ending.status)" : "status \(ending.status)"
            write("stopped \(short) (pid \(match.pid), \(how))", to: FileHandle.standardOutput)
            return PTYHostCLIDefaults.answeredExitCode
        } catch let failure as PTYHostCLIError {
            write(failure.sentence, to: FileHandle.standardError)
            return PTYHostCLIDefaults.silentExitCode
        } catch {
            write(PTYHostCLIError.connectionClosed.sentence, to: FileHandle.standardError)
            return PTYHostCLIDefaults.silentExitCode
        }
    }

    // MARK: - Shared steps

    /// Connect, greet, list, close. Nil once the reason has been written to standard error.
    private static func held(_ locations: Locations, build: String) -> [PTYHostSessionSummary]? {
        do {
            let client = try PTYHostCLIClient.connect(
                socketPath: locations.socketPath,
                build: build
            )
            defer { client.hangUp() }
            try client.greet()
            return try client.list()
        } catch let failure as PTYHostCLIError {
            write(failure.sentence, to: FileHandle.standardError)
            return nil
        } catch {
            write(PTYHostCLIError.connectionClosed.sentence, to: FileHandle.standardError)
            return nil
        }
    }

    // MARK: - launchd

    /// Asks launchd about the registered label.
    ///
    /// **This is the only way the daemon binary can ask.** `SMAppService` lives in the app, and
    /// the boundary lint holds this target to Foundation, Darwin, Dispatch and the wire package —
    /// which is the rule that keeps "it owns the child, the ring, the grid and the exit status,
    /// and parses nothing" true. So the tool asks the way a person at a prompt would, and reads
    /// the answer.
    ///
    /// The answer is about the label rather than about whichever socket this invocation was
    /// pointed at, and the line says so by naming the label. That is deliberate: somebody who
    /// named a socket by hand is usually asking why the ordinary one is silent.
    private static func registration() -> PTYHostCLIRegistration {
        let target = "gui/\(getuid())/\(PTYHostCLIDefaults.launchAgentLabel)"
        let program = ProcessInfo.processInfo
            .environment[PTYHostCLIDefaults.launchctlEnvironmentKey]
            ?? PTYHostCLIDefaults.launchctlPath
        guard let answer = ask(
            program,
            ["print", target],
            timeout: PTYHostCLIDefaults.registrationTimeout
        ) else {
            return .unreadable("launchctl did not run")
        }
        return PTYHostCLIRegistration.parse(output: answer.output, status: answer.status)
    }

    /// The plist this binary's own bundle ships, if it is inside one.
    ///
    /// Derived from the executable rather than from a hard-coded application path: the point of
    /// the line is "does the copy of Threading this daemon came from carry the login item", and
    /// a binary run out of a build directory should say it does not rather than answer about
    /// whatever is in `/Applications`.
    private static var launchAgentPlistURL: URL? {
        guard let executable = Bundle.main.executablePath else { return nil }
        return URL(fileURLWithPath: executable)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                PTYHostCLIDefaults.launchAgentsSubdirectory,
                isDirectory: true
            )
            .appendingPathComponent(
                PTYHostCLIDefaults.launchAgentPlistName,
                isDirectory: false
            )
    }

    /// Runs one short-lived program and collects what it said, with a deadline.
    ///
    /// Polled rather than handed to a queue with a watchdog closure, so nothing here has to be
    /// carried across a concurrency boundary; the tool is a straight line and this is one step in
    /// it. Standard output and standard error are one pipe on purpose: `launchctl` has moved its
    /// refusal between the two across releases, and the shape of the text is what decides.
    private static func ask(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        var collected = Data()
        let reader = pipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: PTYHostCLIDefaults.processReadBufferBytes)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var poller = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(remaining * 1000)) > 0 else { break }
            let count = buffer.withUnsafeMutableBytes {
                PTYHostPOSIX.read(reader, $0.baseAddress, $0.count)
            }
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        return (process.terminationStatus, String(decoding: collected, as: UTF8.self))
    }

    // MARK: - Output

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data((text + "\n").utf8))
    }

    /// Timestamps a person and a script can both read. The daemon's journal uses the same shape.
    ///
    /// Confined to this one straight-line invocation, which is what the annotation says; the
    /// daemon's journal makes the same statement about its own formatter one file over.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The daemon's own journal-file day, so `status` names the file that exists rather than one
    /// derived from a different calendar.
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
