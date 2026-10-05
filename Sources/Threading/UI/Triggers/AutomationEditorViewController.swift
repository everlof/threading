import AppKit
import ThreadingController

/// Host-only editor. Both destinations submit value models to the same operations as MCP.
@MainActor
final class AutomationEditorViewController: NSViewController {
    var configuration: AutomationConfiguration?
    var remoteSpec: ControllerAutomationSpec?
    var onSave: ((AutomationConfiguration?, ControllerAutomationSpec?) async throws -> Void)?
    private let name = ThemedTextField()
    private let instructions = ThemedTextView.scrolling()
    private let target = ThemedPopUp()
    private let worker = ThemedTextField()
    private let workerChoice = ThemedPopUp()
    private let workers: [ControllerWorker]
    private var workerIDs: [WorkerID] = []
    private let agent = ThemedPopUp()
    private let mode = ThemedPopUp()
    private let checkout = ThemedPopUp()
    private let account = ThemedTextField()
    private let model = ThemedTextField()
    private let effort = ThemedTextField()
    private let runtime = ThemedTextField()
    private let scheduleFields: AutomationScheduleFields
    private let unattended = ThemedPopUp()
    private let rules = ThemedTextView.scrolling()
    private let source = ThemedPopUp()
    private let eventKind = ThemedTextField()
    private let sources: [TriggerSourceInstallation]
    private let missed = ThemedPopUp()
    private let archive = ThemedToggle()
    private let save = ThemedButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let projects: [Project]
    private let agents = AgentKind.allCases.filter { $0.supportsNativeUI && $0.supportsPermissionModes }
    private let modes = TriggerExecutionMode.allCases
    private let remoteMode: Bool
    var lockedProjectID: ProjectID?

    init(configuration: AutomationConfiguration? = nil, remoteSpec: ControllerAutomationSpec? = nil, remote: Bool = false, sources: [TriggerSourceInstallation] = [], workers: [ControllerWorker] = [], projects: [Project]? = nil) {
        self.workers = workers
        self.sources = sources
        self.configuration = configuration; self.remoteSpec = remoteSpec; self.remoteMode = remote
        self.projects = projects ?? ProjectStore.shared.projects
        scheduleFields = AutomationScheduleFields(
            schedule: configuration?.options.schedule ?? remoteSpec?.schedule,
            alternative: remote ? L10n.string("Manual or event-driven") : L10n.string("Source event"),
            selectAlternative: remote
                ? (remoteSpec != nil && remoteSpec?.schedule == nil)
                : (configuration?.options.schedule == nil && configuration?.sourceID != nil))
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The tallest the sheet may be, from the window that presents it. Unset, the sheet keeps
    /// `Layout.preferredHeight`.
    var availableHeight: CGFloat?

    /// The sheet's measures. A field is as wide as what it holds: a name and instructions take
    /// the readable measure, a choice the width of its longest choice, and a number or a model
    /// name a short field, so the form reads down one label column instead of one ragged edge.
    enum Layout {
        static let controlWidth = Design.Size.readableWidth
        /// "Assess, then fix if straightforward", the longest choice, whole at the control size.
        static let choiceWidth: CGFloat = 320
        /// An account, a model or an effort name.
        static let fieldWidth = SettingsUIDefaults.controlWidth
        /// A time, a count of minutes.
        static let numberWidth: CGFloat = 96
        /// Room for a brief of a few paragraphs without the field scrolling.
        static let instructionsHeight: CGFloat = 220
        static let rulesHeight: CGFloat = 110
        static let preferredHeight: CGFloat = 860
        static let minimumHeight: CGFloat = 480
    }

    /// The rows a choice shows or hides, kept so a change of choice can say which apply.
    private var timeRow: NSView?
    private var zoneRow: NSView?
    private var daysRow: NSView?
    private var intervalRow: NSView?
    private var missedRow: NSView?
    private var sourceRow: NSView?
    private var eventKindRow: NSView?
    private var rulesRow: NSView?
    private var grammarRow: NSView?
    private var fullPermissionRow: NSView?
    /// Every row's label, so the column can be as wide as the widest of them.
    private var rowLabels: [NSTextField] = []

    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        view = surface

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = Design.Spacing.small
        // A field's border and a theme's glow reach a hair past its frame; the form keeps that
        // hair inside the scroll view's clip rather than shaving the trailing corners off.
        form.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.tight, bottom: Design.Spacing.large, right: Design.Spacing.tight)
        form.translatesAutoresizingMaskIntoConstraints = false
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let clip = FlippedClipView(); clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = form
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let isNew = (configuration == nil || configuration?.name.isEmpty == true) && remoteSpec == nil
        let heading = NSTextField(labelWithString: isNew ? L10n.string("New Automation") : L10n.string("Edit Automation"))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        let lede = NSTextField(wrappingLabelWithString: L10n.string(
            "Saving pauses the automation. Enable it when you are ready. Results remain in Activity after a successful run is archived."))
        lede.applyFont(.subheading)
        lede.textColor = Design.Text.secondary
        form.addArrangedSubview(heading)
        form.addArrangedSubview(lede)
        form.setCustomSpacing(Design.Spacing.tight, after: heading)

        name.setAccessibilityIdentifier("automation.name")
        instructions.textView.setAccessibilityIdentifier("automation.instructions")
        save.setAccessibilityIdentifier("automation.save")
        name.stringValue = configuration?.name ?? remoteSpec?.name ?? ""
        instructions.textView.string = configuration?.instructions ?? remoteSpec?.instruction ?? ""
        instructions.heightAnchor.constraint(equalToConstant: Layout.instructionsHeight).isActive = true
        Self.applyFieldSurface(to: instructions, font: .body)

        // Task: what it is called, where it runs, and what it is asked to do.
        addSection("Task", to: form)
        addRow("Name", name, width: Layout.controlWidth, to: form)
        if remoteMode {
            for entry in workers { workerChoice.addItem(withTitle: entry.name); workerIDs.append(entry.id) }
            if let id = remoteSpec?.workerID {
                if !workerIDs.contains(id) { workerChoice.addItem(withTitle: id.description); workerIDs.append(id) }
                workerChoice.selectItem(at: workerIDs.firstIndex(of: id)!)
            }
            if workerIDs.isEmpty { addRow("Worker ID", worker, width: Layout.fieldWidth, to: form) }
            else { addRow("Worker", workerChoice, width: Layout.choiceWidth, to: form) }
            worker.stringValue = remoteSpec?.workerID.description ?? ""
        } else {
            for project in projects { target.addItem(withTitle: project.name) }
            if let id = configuration?.projectID {
                // A project that has left the sidebar stays visibly unchosen. Falling back to the
                // first row would quietly move the automation, and its edits, to another repository.
                if let index = projects.firstIndex(where: { $0.id == id }) { target.selectItem(at: index) }
                else { target.addItem(withTitle: L10n.string("Unavailable project")); target.selectItem(at: projects.count) }
            }
            target.isEnabled = lockedProjectID == nil
            addRow("Project", target, width: Layout.choiceWidth, to: form)
        }
        addRow("Instructions", instructions, width: Layout.controlWidth, to: form)

        // When: the schedule, or the event it waits for. Only the controls the choice reads
        // are on the sheet; the rest leave it rather than standing there disabled.
        addSection("When", to: form)
        let fields = scheduleFields
        fields.onChange = { [weak self] in self?.cadenceChanged() }
        addRow("Repeat", fields.cadence, width: Layout.choiceWidth, to: form)
        timeRow = addRow("Time (HH:mm)", fields.time, width: Layout.numberWidth, to: form)
        zoneRow = addRow("Time zone", fields.zone, width: Layout.fieldWidth, to: form)
        daysRow = addRow("Days", fields.days, to: form)
        intervalRow = addRow("Interval (minutes)", fields.interval, width: Layout.numberWidth, to: form)
        if !remoteMode {
            for entry in sources { source.addItem(withTitle: entry.displayName) }
            if let id = configuration?.sourceID {
                if let index = sources.firstIndex(where: { $0.id == id }) { source.selectItem(at: index) }
                else { source.addItem(withTitle: L10n.string("Unavailable source")); source.selectItem(at: sources.count) }
            }
            eventKind.stringValue = configuration?.eventKind ?? ""
            sourceRow = addRow("Event source", source, width: Layout.choiceWidth, to: form)
            eventKindRow = addRow("Event kind", eventKind, width: Layout.fieldWidth, to: form)
        }
        missed.addItem(withTitle: L10n.string("Skip missed runs"))
        missed.addItem(withTitle: L10n.string("Run once on return"))
        missed.selectItem(at: configuration?.options.missedRunPolicy == .latest || remoteSpec?.missedPolicy == .latest ? 1 : 0)
        missedRow = addRow("When offline", missed, width: Layout.choiceWidth, to: form)

        if !remoteMode {
            // Agent: who runs it, as which login, on which model.
            addSection("Agent", to: form)
            for value in agents { agent.addItem(withTitle: value.displayName) }
            agent.selectItem(at: agents.firstIndex(of: configuration?.agent ?? .codex) ?? 0)
            addRow("Agent", agent, width: Layout.choiceWidth, to: form)
            account.stringValue = configuration?.account ?? ""
            model.stringValue = configuration?.model ?? ""
            effort.stringValue = configuration?.reasoningEffort ?? ""
            account.placeholderString = L10n.string("Default login")
            model.placeholderString = L10n.string("Default model")
            effort.placeholderString = L10n.string("Default effort")
            addRow("Account", account, width: Layout.fieldWidth, to: form)
            addRow("Model", model, width: Layout.fieldWidth, to: form)
            addRow("Reasoning effort", effort, width: Layout.fieldWidth, to: form)

            // Permissions: what a run may do with nobody there to ask.
            addSection("Permissions", to: form)
            for title in ["Assess only", "Assess, then fix if straightforward", "Read-only task", "Task with local edits"] { mode.addItem(withTitle: L10n.string(title)) }
            mode.selectItem(at: modes.firstIndex(of: configuration?.executionMode ?? .taskReadOnly) ?? 0)
            addRow("Permissions", mode, width: Layout.choiceWidth, to: form)
            checkout.addItem(withTitle: L10n.string("Existing project checkout"))
            checkout.addItem(withTitle: L10n.string("Isolated managed worktree"))
            checkout.addItem(withTitle: L10n.string("Automation workspace"))
            checkout.selectItem(at: configuration?.checkoutPolicy == .automationWorkspace ? 2 : configuration?.checkoutPolicy == .managedWorktree ? 1 : 0)
            addRow("Checkout", checkout, width: Layout.choiceWidth, to: form)
            // Unattended runs never ask, so what they may do is decided here and approved with
            // the revision. Remote workers own their permissions and are not offered this.
            unattended.addItem(withTitle: L10n.string("Allow-list"))
            unattended.addItem(withTitle: L10n.string("Full permission"))
            let policy = configuration?.permissions ?? .readOnly
            unattended.selectItem(at: policy.isFull ? 1 : 0)
            unattended.target = self; unattended.action = #selector(unattendedChanged)
            addRow("Without asking", unattended, width: Layout.choiceWidth, to: form)
            rules.textView.string = policy.rules.map(\.text).joined(separator: "\n")
            rules.textView.setAccessibilityIdentifier("automation.rules")
            rules.heightAnchor.constraint(equalToConstant: Layout.rulesHeight).isActive = true
            Self.applyFieldSurface(to: rules, font: .code())
            rulesRow = addRow("Rules (one per line)", rules, width: Layout.controlWidth, to: form)
            grammarRow = addRow(nil, note(
                "Unattended runs never ask. Bash(command) or Bash(command *), Write(/folder/**), WebFetch(domain:example.com), mcp__server__tool. Reads and read-only commands are always allowed; anything else is refused.",
                color: Design.Text.secondary), width: Layout.controlWidth, to: form)
            fullPermissionRow = addRow(nil, note(
                "Every command runs without asking. A call that would raise a macOS permission prompt is still refused.",
                color: Design.Status.warning), width: Layout.controlWidth, to: form)
        }

        // After: how long a run may take and what happens to its chat.
        addSection("After a run", to: form)
        if !remoteMode {
            runtime.stringValue = String(configuration?.maximumRuntimeMinutes ?? 60)
            addRow("Maximum runtime (minutes)", runtime, width: Layout.numberWidth, to: form)
        }
        archive.state = (configuration?.options.archiveOnSuccess ?? remoteSpec?.archiveOnSuccess ?? true) ? .on : .off
        addRow("Archive successful runs", archive, to: form)

        // Every label takes the widest one's measure, so the controls start on one line.
        let labelWidth = ceil(rowLabels.map(\.fittingSize.width).max() ?? 0)
        for label in rowLabels { label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true }
        let formWidth = labelWidth + Design.Spacing.medium + Layout.controlWidth + Design.Spacing.tight * 2
        lede.preferredMaxLayoutWidth = formWidth

        errorLabel.applyFont(.detail())
        errorLabel.textColor = Design.Status.negative
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = ThemedButton(); cancel.title = L10n.string("Cancel"); cancel.target = self; cancel.action = #selector(cancelPressed)
        cancel.keyEquivalent = "\u{1b}"
        save.title = L10n.string("Save automation"); save.emphasis = .primary; save.target = self; save.action = #selector(savePressed)
        // A refusal stands beside the button that was refused, not at the end of a form that
        // may be scrolled away from it.
        let buttons = NSStackView(views: [errorLabel, NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = Design.Spacing.medium
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        let separator = SeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        let height = max(Layout.minimumHeight, min(Layout.preferredHeight, availableHeight ?? Layout.preferredHeight))
        view.frame = NSRect(x: 0, y: 0, width: formWidth + (Design.Spacing.pane - Design.Spacing.tight) * 2, height: height)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane - Design.Spacing.tight),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -(Design.Spacing.pane - Design.Spacing.tight)),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            form.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -Design.Spacing.medium),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.inset),
        ])
        for child in form.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -Design.Spacing.tight * 2).isActive = true
        }
        cadenceChanged()
        unattendedChanged()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(name) }

    /// A quiet caption over a group of rows, a section's breath above it.
    private func addSection(_ title: String, to form: NSStackView) {
        if let last = form.arrangedSubviews.last { form.setCustomSpacing(Design.Spacing.large, after: last) }
        form.addArrangedSubview(SettingsUI.caption(title))
    }

    /// One labelled row: the label in the shared column, trailing so it sits against its
    /// control, and the control at the width of what it holds. A nil title is a row of the
    /// control alone on the control column, for a note that belongs to the row above it.
    @discardableResult
    private func addRow(_ title: String?, _ control: NSView, width: CGFloat? = nil, to form: NSStackView) -> NSView {
        let label = NSTextField(labelWithString: title.map { L10n.string($0) } ?? "")
        label.applyFont(.detail())
        label.textColor = Design.Text.secondary
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        if let title { control.setAccessibilityLabel(L10n.string(title)) }
        rowLabels.append(label)
        control.translatesAutoresizingMaskIntoConstraints = false
        if let width { control.widthAnchor.constraint(equalToConstant: width).isActive = true }
        // A one-line control stands level with its label. Its drawn text reports no baseline a
        // stack can align on, and a baseline row put every label half a line above its field.
        // A block — the instructions, the weekday run — starts level with the top of its label.
        let isBlock = control is NSScrollView || control is NSStackView
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = isBlock ? .top : .centerY
        row.spacing = Design.Spacing.medium
        form.addArrangedSubview(row)
        return row
    }

    /// A multi-line field drawn as a field — the same plate and hairline as a one-line one, with
    /// its text inset from the edge — rather than text loose on the sheet.
    private static func applyFieldSurface(to field: ThemedTextScrollView, font: Design.FontRole) {
        field.applySurface(fill: Design.Surface.controlResting, radius: .control, border: Design.Surface.border)
        field.textView.textContainerInset = NSSize(width: Design.Spacing.small, height: Design.Spacing.small)
        field.textView.applyFont(font)
    }

    private func note(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L10n.string(text))
        label.applyFont(.detail())
        label.textColor = color
        label.preferredMaxLayoutWidth = Layout.controlWidth
        return label
    }

    private func cadenceChanged() {
        scheduleFields.updateEnabled()
        let fields = scheduleFields
        let isEvent = fields.isAlternativeSelected
        timeRow?.isHidden = !fields.readsTime
        zoneRow?.isHidden = !fields.readsZone
        daysRow?.isHidden = !fields.readsDays
        intervalRow?.isHidden = !fields.readsInterval
        // A missed time is a schedule's question; an event is delivered when it arrives.
        missedRow?.isHidden = isEvent && !remoteMode
        sourceRow?.isHidden = !isEvent
        eventKindRow?.isHidden = !isEvent
        source.isEnabled = isEvent; eventKind.isEnabled = isEvent
    }
    @objc private func unattendedChanged() {
        let isAllowList = unattended.indexOfSelectedItem == 0
        rules.textView.isEditable = isAllowList
        rulesRow?.isHidden = !isAllowList
        grammarRow?.isHidden = !isAllowList
        fullPermissionRow?.isHidden = isAllowList
    }
    @objc private func cancelPressed() { presentingViewController?.dismiss(self) }
    @objc private func savePressed() {
        errorLabel.stringValue = ""
        do {
            let (configuration, remoteSpec) = try submission()
            save.isEnabled = false
            Task { @MainActor in
                do { try await onSave?(configuration, remoteSpec); presentingViewController?.dismiss(self) }
                catch { errorLabel.stringValue = error.localizedDescription; save.isEnabled = true }
            }
        } catch { errorLabel.stringValue = error.localizedDescription }
    }

    /// Reads the form into the value the save operation receives, refusing a choice the form
    /// could only have made by default. Kept apart from presentation so it can be tested.
    func submission() throws -> (AutomationConfiguration?, ControllerAutomationSpec?) {
        let schedule = try scheduleFields.schedule(
            anchor: configuration?.options.schedule?.anchor ?? remoteSpec?.schedule?.anchor)
        let isEvent = scheduleFields.isAlternativeSelected
        if !isEvent { try schedule.validate() }
        if remoteMode {
            remoteSpec = ControllerAutomationSpec(name: name.stringValue, workerID: workerIDs.indices.contains(workerChoice.indexOfSelectedItem) ? workerIDs[workerChoice.indexOfSelectedItem] : try WorkerID(worker.stringValue),
                instruction: instructions.textView.string, schedule: isEvent ? nil : schedule,
                missedPolicy: missed.indexOfSelectedItem == 1 ? .latest : .skip, archiveOnSuccess: archive.state == .on)
            return (nil, remoteSpec)
        }
        guard projects.indices.contains(target.indexOfSelectedItem) else { throw AutomationEditorError.projectUnavailable }
        guard let maximum = Int(runtime.stringValue) else { throw TriggerStore.StoreError.invalidRecord("maximum runtime") }
        var config = configuration ?? AutomationConfiguration(projectID: projects[target.indexOfSelectedItem].id)
        config.name = name.stringValue; config.projectID = projects[target.indexOfSelectedItem].id
        config.instructions = instructions.textView.string; config.agent = agents[agent.indexOfSelectedItem]
        config.executionMode = modes[mode.indexOfSelectedItem]
        config.checkoutPolicy = checkout.indexOfSelectedItem == 2 ? .automationWorkspace : checkout.indexOfSelectedItem == 1 ? .managedWorktree : .projectCheckout
        config.maximumRuntimeMinutes = maximum
        config.account = account.stringValue.isEmpty ? nil : account.stringValue
        config.model = model.stringValue.isEmpty ? nil : model.stringValue
        config.reasoningEffort = effort.stringValue.isEmpty ? nil : effort.stringValue
        config.permissions = unattended.indexOfSelectedItem == 1
            ? .full
            : try AutomationPermissionPolicy.allowList(parsing: rules.textView.string.components(separatedBy: .newlines))
        config.options = .init(schedule: schedule, missedRunPolicy: missed.indexOfSelectedItem == 1 ? .latest : .skip, archiveOnSuccess: archive.state == .on)
        if isEvent {
            guard sources.indices.contains(source.indexOfSelectedItem) else { throw AutomationEditorError.sourceUnavailable }
            config.options.schedule = nil
            config.sourceID = sources[source.indexOfSelectedItem].id
            config.eventKind = eventKind.stringValue
        } else { config.sourceID = nil; config.eventKind = nil; config.conditions = [] }
        configuration = config
        return (config, nil)
    }
}

enum AutomationEditorError: LocalizedError {
    case projectUnavailable
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .projectUnavailable: L10n.string("Choose a project that is still in the sidebar.")
        case .sourceUnavailable: L10n.string("Choose an event source that is still connected.")
        }
    }
}
