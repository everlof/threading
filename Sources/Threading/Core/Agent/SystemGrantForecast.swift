import Foundation

// MARK: - System Grant Forecast

/// Which macOS privacy prompt a tool call is about to raise, read *before* the call runs.
///
/// macOS attributes a directly spawned child to the responsible parent, so when an agent runs
/// `screencapture` the system alert says **Threading** would like to record this computer's
/// screen. From the user's side that dialog arrives out of nowhere: it names an app that is not
/// doing the thing, it does not say which of six open sessions asked, and it does not say why.
///
/// Nothing in-process can intercept a TCC prompt — it is presented by another process, after the
/// child has already made the call. The only place to explain it is *before* the command runs,
/// and `PermissionBroker` is already standing there holding every tool call open.
///
/// **The rules only fire where the answer is knowable.** A forecast is worth acting on when
/// Threading can also confirm the grant is missing, because only then is the system prompt
/// certain to follow. Screen Recording and Accessibility can be read without prompting
/// (`SystemPrivacyStatusReader`); Files & Folders cannot, and guessing at it would put a card on
/// screen for a folder the user approved two years ago — the same unearned interruption this
/// exists to remove, wearing our own badge instead of the system's. That is why
/// `filesAndFolders` is absent below rather than forgotten, and it is the same reason
/// `SystemPrivacyStatus.askedWhenNeeded` exists.
///
/// The rules are read the way `ShellCommandPolicy` reads a command — naively, on purpose. Being
/// wrong here costs one explanatory card that turns out to be unnecessary, or a system prompt
/// that arrives unexplained as it does today; neither is a security decision, so the matching is
/// kept simple enough to be obviously correct.
enum SystemGrantForecast {

    // MARK: - Public Methods

    /// The grant a tool call is about to need, or nil when it needs none we can foresee.
    static func grant(for request: PermissionRequest) -> SystemPrivacyPermission? {
        // Only a shell call reaches a binary of its own. Every other tool runs inside the CLI,
        // whose file access is the folder grant this deliberately does not guess at.
        guard let command = request.shellCommand else { return nil }
        return grant(forCommand: command)
    }

    /// The grant a command line is about to need. Split out so the table can be tested against
    /// real command strings without building a request around each one.
    static func grant(forCommand command: String) -> SystemPrivacyPermission? {
        segments(of: command)
            .lazy
            .compactMap(grant(inSegment:))
            .first
    }

    // MARK: - Private Methods

    /// One command line broken at every operator that starts a new command, so `cd /tmp &&
    /// screencapture x.png` is seen as the two commands it is. The same naive split
    /// `ShellCommandPolicy` uses, and naive for the same reason: a `;` inside a quoted argument
    /// yields a segment whose first word is not one of these binaries, which forecasts nothing.
    private static func segments(of command: String) -> [String] {
        command
            .components(separatedBy: CharacterSet(charactersIn: "&|;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func grant(inSegment segment: String) -> SystemPrivacyPermission? {
        var tokens = segment.split(separator: " ").map(String.init)

        // `sudo screencapture`, `env screencapture`, `xargs screencapture` all run the binary
        // that matters one word along. A short list rather than a scan of every token: matching
        // anywhere would forecast on `grep screencapture notes.txt`, which touches nothing.
        while let first = tokens.first, Rule.wrappers.contains(name(of: first)) {
            tokens.removeFirst()
        }

        guard let executable = tokens.first.map(name(of:)) else { return nil }

        if Rule.screenCaptureCommands.contains(executable) { return .screenRecording }
        if Rule.inputControlCommands.contains(executable) { return .accessibility }

        // AppleScript is the one that has to be read further in. `osascript` is how an agent
        // reads a window title as readily as how it clicks a button, and only the second needs
        // Accessibility — so the script itself has to name both System Events and something it
        // would drive.
        if Rule.appleScriptCommands.contains(executable), drivesInput(segment) {
            return .accessibility
        }

        return nil
    }

    /// A command as the allowlist spells it: `/usr/sbin/screencapture` is `screencapture`.
    private static func name(of token: String) -> String {
        String(token.split(separator: "/").last ?? "").lowercased()
    }

    /// Whether an AppleScript would drive the pointer or keyboard, which is what needs the
    /// grant. Reading a process list through System Events asks macOS for Automation instead —
    /// a different gate, with no readable status, and so not one this forecasts.
    private static func drivesInput(_ segment: String) -> Bool {
        let lowered = segment.lowercased()
        guard Rule.inputControlHosts.contains(where: lowered.contains) else { return false }
        return Rule.inputControlVerbs.contains(where: lowered.contains)
    }

    // MARK: - Rules

    private enum Rule {
        /// Commands that run another command, so the binary that matters is the next word.
        static let wrappers: Set<String> = ["sudo", "env", "nohup", "time", "xargs", "command"]

        static let screenCaptureCommands: Set<String> = ["screencapture"]

        /// Third-party pointer and keyboard drivers an agent is likely to reach for. Each needs
        /// Accessibility to do anything at all, so naming the binary is enough.
        static let inputControlCommands: Set<String> = ["cliclick"]

        static let appleScriptCommands: Set<String> = ["osascript"]

        /// The applications a script drives input through.
        static let inputControlHosts = ["system events", "systemuiserver"]

        /// …and the verbs that make it input rather than inspection.
        static let inputControlVerbs = [
            "keystroke", "key code", "key down", "key up", "click", "perform action",
            "set value of attribute", "drag"
        ]
    }
}
