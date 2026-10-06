import AppKit
import ThreadingController
import ThreadingDomain

/// What the Sources page and the approval sheet say about one probe source, built as values so
/// the choice of words is testable without drawing anything.
@MainActor
enum TriggerProbePresentation {
    /// The row's state, from the stored approval and the daemon's latest receipt.
    enum State: Equatable {
        case needsApproval
        case changed
        case listening(TriggerSourceHealth)
        case paused
    }

    struct Row: Equatable {
        let title: String
        let detail: String
        let state: State
        /// The primary action: approve, pause or resume.
        let primaryTitle: String
        /// "Run now" exists only for an approved probe.
        let canRunNow: Bool
        let hasSecrets: Bool
    }

    static func state(of source: TriggerSourceInstallation, daemonStatus: TriggerDaemonSourceStatus?) -> State {
        guard let probe = source.probe else { return .needsApproval }
        guard probe.isApproved else { return .needsApproval }
        if daemonStatus?.health == .changed { return .changed }
        guard source.enabled else { return .paused }
        return .listening(daemonStatus?.health ?? source.health)
    }

    /// `listener` decides whether an approved, enabled probe is checked at all: while the
    /// listener is not running its last receipt (or "Checking") would claim more than is true.
    static func row(
        _ source: TriggerSourceInstallation,
        daemonStatus: TriggerDaemonSourceStatus?,
        listener: TriggerListenerState = .running,
        relativeTo now: Date = Date()
    ) -> Row {
        let state = state(of: source, daemonStatus: daemonStatus)
        let probe = source.probe
        let stateWords: String
        let primary: String
        switch state {
        case .needsApproval:
            stateWords = L10n.string("Needs approval")
            primary = L10n.string("Review & Approve…")
        case .changed:
            stateWords = L10n.string("Changed since approval")
            primary = L10n.string("Review & Approve…")
        case .paused:
            stateWords = L10n.string("Paused")
            primary = L10n.string("Resume")
        case .listening(let health):
            stateWords = listener.isListening ? health.displayTitle : L10n.string("Not checked")
            primary = L10n.string("Pause")
        }
        var facts = [timing(probe?.spec), stateWords]
        if let hash = probe?.hash { facts.append(L10n.format("SHA-256 %@", String(hash.prefix(12)))) }
        if let checked = daemonStatus?.lastCheckedAt ?? source.lastCheckedAt {
            facts.append(relative.localizedString(for: checked, relativeTo: now))
        }
        var detail = facts.joined(separator: "  ·  ")
        if case .listening = state, !listener.isListening {
            detail += "\n" + listener.sourceConsequence
        } else if let diagnostic = daemonStatus?.boundedDiagnostic ?? source.boundedDiagnostic, !diagnostic.isEmpty {
            detail += "\n" + diagnostic
        }
        return Row(
            title: source.displayName,
            detail: detail,
            state: state,
            primaryTitle: primary,
            canRunNow: probe?.isApproved == true && state != .changed,
            hasSecrets: probe?.spec.secrets.isEmpty == false
        )
    }

    static func timing(_ spec: ControllerSourceSpec?) -> String {
        guard let spec else { return L10n.string("No schedule") }
        if let schedule = spec.schedule { return schedule.summary }
        let seconds = spec.intervalSeconds ?? 600
        if seconds % 3_600 == 0 { return L10n.format("Every %lld h", Int64(seconds / 3_600)) }
        if seconds % 60 == 0 { return L10n.format("Every %lld min", Int64(seconds / 60)) }
        return L10n.format("Every %lld s", Int64(seconds))
    }

    // MARK: - Approval

    /// The facts a person approves: the exact files and their hash, when it runs, what it is
    /// given, and the bounds the host enforces. Secret values are never shown; a secret with no
    /// stored value is called out, since the probe would fail authentication.
    static func reviewFacts(_ source: TriggerSourceInstallation, storedSecrets: Set<String>) -> [FactSheetView.Fact] {
        guard let probe = source.probe else { return [] }
        let spec = probe.spec
        var facts: [FactSheetView.Fact] = [
            .init(label: L10n.string("Executable"), value: spec.executable, identifier: "executable"),
            .init(label: L10n.string("Script"), value: spec.script ?? L10n.string("None"), identifier: "script"),
            .init(label: L10n.string("SHA-256"), value: probe.hash,
                  detail: L10n.string("Checked before every run; a change pauses the probe until you approve it again."),
                  identifier: "hash"),
            .init(label: L10n.string("When"), value: timing(spec), identifier: "when"),
        ]
        let arguments = spec.arguments.dropFirst(spec.script == nil ? 0 : 1)
        facts.append(.init(label: L10n.string("Arguments"),
                           value: arguments.isEmpty ? L10n.string("None") : arguments.joined(separator: "\n"),
                           identifier: "arguments"))
        facts.append(.init(label: L10n.string("Environment"),
                           value: spec.environment.isEmpty
                               ? L10n.string("Nothing inherited, nothing added")
                               : spec.environment.keys.sorted().joined(separator: ", "),
                           detail: spec.environment.isEmpty ? nil : L10n.string("Nothing else is inherited."),
                           identifier: "environment"))
        if spec.secrets.isEmpty {
            facts.append(.init(label: L10n.string("Secrets"), value: L10n.string("None"), identifier: "secrets"))
        } else {
            let missing = spec.secrets.values.filter { !storedSecrets.contains($0) }.sorted()
            facts.append(.init(
                label: L10n.string("Secrets"),
                value: spec.secrets.sorted { $0.key < $1.key }.map { "\($0.key) ← \($0.value)" }.joined(separator: "\n"),
                detail: missing.isEmpty
                    ? L10n.string("Read from Keychain at each poll, only into the probe's environment.")
                    : L10n.format("Not set yet: %@", missing.joined(separator: ", ")),
                tone: missing.isEmpty ? .normal : .caution,
                identifier: "secrets"))
        }
        facts.append(.init(
            label: L10n.string("Limits"),
            value: L10n.format("Stops after %lld seconds", Int64(spec.timeoutSeconds)),
            detail: L10n.format("At most %lld events per poll", Int64(spec.limit)),
            identifier: "limits"))
        facts.append(.init(label: L10n.string("Revision"), value: String(probe.revision), identifier: "revision"))
        return facts
    }

    static let authorityWarning = L10n.string(
        "This probe is not sandboxed. It runs as you, with your account's authority: it can read, change and send anything you can. Approve it only if you trust these exact files. Its events start agents only through automations you activate separately, and their content is shown to agents as untrusted evidence."
    )

    static func approvalRequest(_ source: TriggerSourceInstallation, storedSecrets: Set<String>) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .approveTriggerActivation,
            title: L10n.format("Approve the probe “%@”?", source.displayName),
            message: L10n.string(
                "Threading will run this program on its schedule, without asking again, until you pause it or its files change."
            ),
            confirmTitle: L10n.string("Approve and Enable"),
            accessory: AutomationReviewView(
                review: AutomationReview(facts: reviewFacts(source, storedSecrets: storedSecrets),
                                         instructions: authorityWarning),
                instructionsTitle: L10n.string("Runs unsandboxed")
            )
        )
    }

    /// The editor sheet: the form, and the reminder that saving never approves.
    static func editorRequest(_ form: TriggerProbeEditorForm, editing name: String?) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .connectTriggerSource,
            title: name.map { L10n.format("Edit “%@”", $0) } ?? L10n.string("New Probe Source"),
            message: L10n.string(
                "Saving leaves the probe paused. You approve its exact files before it runs; any later edit needs approval again."
            ),
            confirmTitle: L10n.string("Save"),
            accessory: form.makeView()
        )
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// The fields a person fills in to configure a probe, and their one parse into a spec.
@MainActor
final class TriggerProbeEditorForm {
    enum Layout {
        static let fieldWidth: CGFloat = 420
        static let listHeight: CGFloat = 60
    }

    let name = ThemedTextField()
    let executable = ThemedTextField()
    let script = ThemedTextField()
    let arguments = ThemedTextView.scrolling()
    let environment = ThemedTextView.scrolling()
    let secrets = ThemedTextView.scrolling()
    /// The automation editor's own schedule controls. "Fixed interval" is the spec's
    /// `intervalSeconds`; the calendar kinds are its `schedule`.
    let timing: AutomationScheduleFields
    let timeout = ThemedTextField()
    let limit = ThemedTextField()
    private let anchor: Date?

    init(spec: ControllerSourceSpec?) {
        anchor = spec?.schedule?.anchor
        timing = AutomationScheduleFields(schedule: spec?.schedule ?? AutomationSchedule(
            kind: .interval, timeZone: TimeZone.current.identifier,
            intervalMinutes: max(1, (spec?.intervalSeconds ?? 600) / 60)))
        timing.updateEnabled()
        name.placeholderString = L10n.string("Support mailbox")
        executable.placeholderString = L10n.string("Executable, e.g. /usr/bin/python3")
        script.placeholderString = L10n.string("Script it runs (optional)")
        timeout.placeholderString = L10n.string("Timeout in seconds (default 30)")
        limit.placeholderString = L10n.string("Events per poll (default 50)")
        guard let spec else { return }
        name.stringValue = spec.name
        executable.stringValue = spec.executable
        script.stringValue = spec.script ?? ""
        arguments.textView.string = spec.arguments.dropFirst(spec.script == nil ? 0 : 1).joined(separator: "\n")
        environment.textView.string = spec.environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        secrets.textView.string = spec.secrets.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        timeout.stringValue = String(spec.timeoutSeconds)
        limit.stringValue = String(spec.limit)
    }

    func makeView() -> NSView {
        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.applyFont(.detail())
            label.textColor = Design.Text.secondary
            return label
        }
        let views: [NSView] = [
            name, executable, script,
            caption(L10n.string("Arguments after the script, one per line")), arguments,
            caption(L10n.string("Environment, one NAME=value per line; nothing else is inherited")), environment,
            caption(L10n.string("Secrets, one NAME=secret-name per line; values go in Keychain")), secrets,
            caption(L10n.string("Repeat")), timing.cadence,
            caption(L10n.string("Time (HH:mm)")), timing.time,
            caption(L10n.string("Time zone")), timing.zone,
            caption(L10n.string("Days")), timing.days,
            caption(L10n.string("Interval (minutes)")), timing.interval,
            // Captioned like every other field: a filled field shows no placeholder to name it.
            caption(L10n.string("Timeout in seconds (default 30)")), timeout,
            caption(L10n.string("Events per poll (default 50)")), limit,
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        for view in [name, executable, script, timing.cadence, timing.time, timing.zone, timing.interval, timeout, limit] as [NSView]
            + [arguments, environment, secrets] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: Layout.fieldWidth).isActive = true
        }
        for view in [arguments, environment, secrets] {
            view.heightAnchor.constraint(equalToConstant: Layout.listHeight).isActive = true
        }
        return stack
    }

    func spec() throws -> ControllerSourceSpec {
        try Self.spec(
            name: name.stringValue, executable: executable.stringValue, script: script.stringValue,
            arguments: arguments.textView.string, environment: environment.textView.string,
            secrets: secrets.textView.string, timing: try timing.schedule(anchor: anchor),
            timeoutSeconds: timeout.stringValue, limit: limit.stringValue
        )
    }

    /// The parse, separate from the fields so it is testable. The script, when given, becomes the
    /// first argument: the file the approval hashes is the file the executable is handed.
    nonisolated static func spec(
        name: String, executable: String, script: String, arguments: String, environment: String,
        secrets: String, timing: AutomationSchedule, timeoutSeconds: String, limit: String
    ) throws -> ControllerSourceSpec {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { trimmed(String($0)) }.filter { !$0.isEmpty }
        }
        func pairs(_ text: String) throws -> [String: String] {
            var result: [String: String] = [:]
            for line in lines(text) {
                guard let equals = line.firstIndex(of: "="), equals != line.startIndex else {
                    throw TriggerProbeSourceCommands.Failure.invalid("expected NAME=value: \(line)")
                }
                result[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
            return result
        }
        let scriptPath = trimmed(script)
        // A fixed interval is the spec's interval; a calendar rule is its schedule.
        let intervalSeconds: Int? = timing.kind == .interval ? timing.intervalMinutes * 60 : nil
        if intervalSeconds == nil {
            do { try timing.validate() } catch { throw TriggerProbeSourceCommands.Failure.invalid("schedule") }
        }
        let spec = ControllerSourceSpec(
            name: trimmed(name),
            executable: trimmed(executable),
            script: scriptPath.isEmpty ? nil : scriptPath,
            arguments: (scriptPath.isEmpty ? [] : [scriptPath]) + lines(arguments),
            environment: try pairs(environment),
            secrets: try pairs(secrets),
            intervalSeconds: intervalSeconds,
            schedule: intervalSeconds == nil ? timing : nil,
            timeoutSeconds: Int(trimmed(timeoutSeconds)) ?? 30,
            limit: Int(trimmed(limit)) ?? 50
        )
        try TriggerProbeSourceCommands.validate(spec)
        return spec
    }
}
