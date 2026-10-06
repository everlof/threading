import AppKit

/// What the Automations page says about one automation — whether it runs, when, with what
/// authority, and how its last run went — built as values so the words are testable without
/// drawing anything. The list row and the detail page's header read the same summary, so the
/// two cannot describe one automation differently.
@MainActor
struct AutomationSummary: Equatable {
    enum State: Equatable {
        /// Saved but never activated: nothing runs until a person reviews it.
        case draft
        case active
        case paused
    }

    let name: String
    let state: State
    /// When it runs: its schedule, or the event it waits for.
    let timing: String
    /// What a run may do, in the editor's words.
    let mode: String
    /// When it runs next, already in display words; nil when nothing is due.
    let nextRun: String?
    /// How the most recent run went, already in display words.
    let lastRun: String
    let lastRunTone: AutomationInk.Tone?

    var stateWords: String {
        switch state {
        case .draft: L10n.string("Draft — not active")
        case .active: L10n.string("Active")
        case .paused: L10n.string("Paused")
        }
    }

    var stateTone: AutomationInk.Tone {
        switch state {
        case .draft: .attention
        case .active: .positive
        case .paused: .quiet
        }
    }

    /// The one action that changes whether it runs.
    var stateActionTitle: String {
        switch state {
        case .draft: L10n.string("Review & Activate")
        case .active: L10n.string("Pause")
        case .paused: L10n.string("Resume")
        }
    }

    /// The schedule line and the authority line, as the row's second line.
    var timingAndMode: String { "\(timing)  ·  \(mode)" }

    /// Next run and last run, as the row's third line.
    var runs: String {
        [nextRun.map { L10n.format("Next run: %@", $0) }, lastRun]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }

    static func make(
        definition: TriggerDefinition,
        revision: TriggerRevision,
        nextRun: Date?,
        lastRun: TriggerRun?,
        now: Date = Date()
    ) -> AutomationSummary {
        let state: State
        if definition.draftRevisionID == revision.id {
            state = .draft
        } else {
            state = definition.enabled ? .active : .paused
        }
        let timing = revision.automation?.schedule?.summary
            ?? L10n.format("“%@” arrives", revision.eventKind)
        let last = lastRun.map {
            L10n.format(
                "Last run: %@, %@",
                $0.state.displayTitle,
                AutomationInk.relativeDate.localizedString(for: $0.queuedAt, relativeTo: now)
            )
        } ?? L10n.string("Not run yet")
        return AutomationSummary(
            name: definition.name,
            state: state,
            timing: timing,
            mode: revision.executionMode.displayTitle,
            nextRun: state == .active
                ? nextRun.map { $0.formatted(date: .abbreviated, time: .shortened) }
                : nil,
            lastRun: last,
            lastRunTone: lastRun?.state.tone
        )
    }
}

/// The few inks the Automations destination speaks state in. One owner, so an automation's
/// state and a run's result never pick two different greens for the same meaning.
@MainActor
enum AutomationInk {
    enum Tone: Equatable {
        /// Running as it should, or finished well.
        case positive
        /// Wants a person: a draft to review, a run that needs attention.
        case attention
        /// Did not finish.
        case failure
        /// Under way.
        case working
        /// Paused, suppressed or cancelled: true, but nothing to act on.
        case quiet
    }

    static func color(_ tone: Tone) -> NSColor {
        switch tone {
        case .positive: Design.Status.positive
        case .attention: Design.Status.warning
        case .failure: Design.Status.negative
        case .working: Design.Text.secondary
        case .quiet: Design.Text.tertiary
        }
    }

    static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

extension TriggerRunState {
    var displayTitle: String {
        switch self {
        case .received: return L10n.string("Received")
        case .suppressed: return L10n.string("Suppressed")
        case .queued: return L10n.string("Queued")
        case .assessing: return L10n.string("Assessing")
        case .fixQueued: return L10n.string("Queued")
        case .fixing: return L10n.string("Fixing")
        case .running: return L10n.string("Running")
        case .finishing: return L10n.string("Finishing")
        case .needsAttention: return L10n.string("Needs attention")
        case .completed: return L10n.string("Ready to verify")
        case .failed: return L10n.string("Failed")
        case .cancelled: return L10n.string("Cancelled")
        }
    }

    @MainActor var tone: AutomationInk.Tone {
        switch self {
        case .completed: .positive
        case .needsAttention: .attention
        case .failed: .failure
        case .received, .queued, .assessing, .fixQueued, .fixing, .running, .finishing: .working
        case .suppressed, .cancelled: .quiet
        }
    }
}

/// What a run's Details sheet shows: when it ran and what it reported, as the same fact sheet
/// an approval uses, with the agent's own summary as the long text under it.
@MainActor
enum AutomationRunReview {
    static func make(_ run: TriggerRun, automationName: String?) -> AutomationReview {
        var facts: [FactSheetView.Fact] = []
        if let automationName {
            facts.append(.init(label: L10n.string("Automation"), value: automationName, identifier: "automation"))
        }
        facts.append(.init(
            label: L10n.string("Result"),
            value: run.state.displayTitle,
            detail: run.boundedDiagnostic,
            tone: run.state.tone == .failure || run.state.tone == .attention ? .caution : .normal,
            identifier: "result"
        ))
        facts.append(.init(
            label: L10n.string("Started"),
            value: (run.startedAt ?? run.queuedAt).formatted(date: .abbreviated, time: .shortened),
            detail: run.initiatedManually == true ? L10n.string("Started by hand") : nil,
            identifier: "started"
        ))
        if let settled = run.settledAt {
            facts.append(.init(
                label: L10n.string("Finished"),
                value: settled.formatted(date: .abbreviated, time: .shortened),
                identifier: "finished"
            ))
        }
        if let result = run.result, !result.changedPaths.isEmpty {
            facts.append(.init(
                label: L10n.string("Changed"),
                value: result.changedPaths.joined(separator: "\n"),
                identifier: "changed"
            ))
        }
        if let result = run.result, !result.tests.isEmpty {
            facts.append(.init(
                label: L10n.string("Tests"),
                value: result.tests.joined(separator: "\n"),
                identifier: "tests"
            ))
        }
        let summary = run.result?.summary
            ?? L10n.string("The run has not reported a result.")
        return AutomationReview(facts: facts, instructions: summary)
    }
}

/// The top of one automation's page: the way back, its name and state, when it runs, and every
/// action on it as a button of its own.
///
/// It replaced a "Manage…" alert that held a 120-point window onto the instructions and a pop-up
/// of three verbs behind a Continue button: to delete an automation a person had to choose
/// "Delete" from a menu and then press a button that said something else.
@MainActor
final class AutomationDetailHeaderView: NSView {
    var onBack: (() -> Void)?
    var onStateAction: (() -> Void)?
    var onRunNow: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    let summary: AutomationSummary

    /// `backTitle` names the list the way back returns to: the app-wide page's, or a project's.
    init(summary: AutomationSummary, backTitle: String = L10n.string("All automations")) {
        self.summary = summary
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("automation.detail")

        let back = ThemedButton(
            symbol: "chevron.left",
            accessibility: backTitle,
            target: self,
            action: #selector(backPressed)
        )
        back.title = backTitle
        back.emphasis = .tertiary
        back.setAccessibilityIdentifier("automation.detail.back")

        let name = NSTextField(wrappingLabelWithString: summary.name)
        name.applyFont(.heading)
        name.textColor = Design.Text.label
        name.isSelectable = true

        let state = NSTextField(labelWithString: summary.stateWords)
        state.applyFont(.detail(weight: .semibold))
        state.textColor = AutomationInk.color(summary.stateTone)
        state.setContentHuggingPriority(.required, for: .horizontal)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.setAccessibilityIdentifier("automation.detail.state")

        let timing = NSTextField(wrappingLabelWithString: summary.timingAndMode)
        timing.applyFont(.subheading)
        timing.textColor = Design.Text.secondary

        let stateLine = NSStackView(views: [state, timing])
        stateLine.orientation = .horizontal
        stateLine.alignment = .firstBaseline
        stateLine.spacing = Design.Spacing.medium

        let runs = NSTextField(wrappingLabelWithString: summary.runs)
        runs.applyFont(.detail())
        runs.textColor = Design.Text.tertiary

        let stateAction = Self.button(summary.stateActionTitle, emphasis: summary.state == .draft ? .primary : .secondary)
        stateAction.target = self
        stateAction.action = #selector(statePressed)
        stateAction.setAccessibilityIdentifier("automation.detail.state-action")
        let runNow = Self.button(
            summary.state == .draft ? L10n.string("Run once…") : L10n.string("Run now"),
            emphasis: .secondary
        )
        runNow.target = self
        runNow.action = #selector(runPressed)
        runNow.setAccessibilityIdentifier("automation.detail.run")
        let edit = Self.button(L10n.string("Edit…"), emphasis: .secondary)
        edit.target = self
        edit.action = #selector(editPressed)
        edit.setAccessibilityIdentifier("automation.detail.edit")
        let delete = Self.button(L10n.string("Delete…"), emphasis: .tertiary)
        delete.target = self
        delete.action = #selector(deletePressed)
        delete.setAccessibilityIdentifier("automation.detail.delete")

        // Delete stands a group's breath apart, so the action a person reaches for least is not
        // the neighbour of the one they reach for most — but on the same run, not at the far
        // end of a wide page where it read as belonging to nothing.
        let actions = NSStackView(views: [stateAction, runNow, edit, delete, NSView()])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small
        actions.setCustomSpacing(Design.Spacing.large, after: edit)

        // The back control sits on the column by its glyph, not by the hover plate it draws only
        // under the pointer, so it lines up with the name under it.
        let backSlot = NSView()
        back.translatesAutoresizingMaskIntoConstraints = false
        backSlot.addSubview(back)
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: backSlot.topAnchor),
            back.bottomAnchor.constraint(equalTo: backSlot.bottomAnchor),
            back.leadingAnchor.constraint(equalTo: backSlot.leadingAnchor, constant: -back.opticalHorizontalInset),
            back.trailingAnchor.constraint(lessThanOrEqualTo: backSlot.trailingAnchor),
        ])

        let column = NSStackView(views: [backSlot, name, stateLine, runs, actions])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.small
        column.setCustomSpacing(Design.Spacing.medium, after: backSlot)
        column.setCustomSpacing(Design.Spacing.large, after: runs)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // A wrapping label has no width of its own to claim; each one asks for the column.
        for line in [backSlot, name, stateLine, runs, actions] as [NSView] {
            line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func button(_ title: String, emphasis: ThemedButton.Emphasis) -> ThemedButton {
        let button = ThemedButton()
        button.title = title
        button.emphasis = emphasis
        return button
    }

    @objc private func backPressed() { onBack?() }
    @objc private func statePressed() { onStateAction?() }
    @objc private func runPressed() { onRunNow?() }
    @objc private func editPressed() { onEdit?() }
    @objc private func deletePressed() { onDelete?() }
}
