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

    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        surface.frame = NSRect(x: 0, y: 0, width: Design.Size.readableWidth + Design.Spacing.pane * 2, height: 720)
        view = surface
        let form = NSStackView()
        form.orientation = .vertical; form.alignment = .leading; form.spacing = Design.Spacing.medium
        form.translatesAutoresizingMaskIntoConstraints = false
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        let clip = FlippedClipView(); clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = form
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let heading = NSTextField(labelWithString: L10n.string("Automation"))
        heading.applyFont(.heading); form.addArrangedSubview(heading)
        name.setAccessibilityIdentifier("automation.name")
        instructions.textView.setAccessibilityIdentifier("automation.instructions")
        save.setAccessibilityIdentifier("automation.save")
        addRow("Name", name, to: form)
        name.stringValue = configuration?.name ?? remoteSpec?.name ?? ""
        if remoteMode {
            for entry in workers { workerChoice.addItem(withTitle: entry.name); workerIDs.append(entry.id) }
            if let id = remoteSpec?.workerID {
                if !workerIDs.contains(id) { workerChoice.addItem(withTitle: id.description); workerIDs.append(id) }
                workerChoice.selectItem(at: workerIDs.firstIndex(of: id)!)
            }
            if workerIDs.isEmpty { addRow("Worker ID", worker, to: form) }
            else { addRow("Worker", workerChoice, to: form) }
            worker.stringValue = remoteSpec?.workerID.description ?? ""
        } else {
            for project in projects { target.addItem(withTitle: project.name) }
            if let id = configuration?.projectID {
                // A project that has left the sidebar stays visibly unchosen. Falling back to the
                // first row would quietly move the automation, and its edits, to another repository.
                if let index = projects.firstIndex(where: { $0.id == id }) { target.selectItem(at: index) }
                else { target.addItem(withTitle: L10n.string("Unavailable project")); target.selectItem(at: projects.count) }
            }
            addRow("Project", target, to: form)
            for value in agents { agent.addItem(withTitle: value.displayName) }
            agent.selectItem(at: agents.firstIndex(of: configuration?.agent ?? .codex) ?? 0)
            addRow("Agent", agent, to: form)
            for title in ["Assess only", "Assess, then fix if straightforward", "Read-only task", "Task with local edits"] { mode.addItem(withTitle: L10n.string(title)) }
            mode.selectItem(at: modes.firstIndex(of: configuration?.executionMode ?? .taskReadOnly) ?? 0)
            addRow("Permissions", mode, to: form)
            checkout.addItem(withTitle: L10n.string("Existing project checkout"))
            checkout.addItem(withTitle: L10n.string("Isolated managed worktree"))
            checkout.selectItem(at: configuration?.checkoutPolicy == .managedWorktree ? 1 : 0)
            addRow("Checkout", checkout, to: form)
            account.stringValue = configuration?.account ?? ""
            model.stringValue = configuration?.model ?? ""
            effort.stringValue = configuration?.reasoningEffort ?? ""
            addRow("Account", account, to: form); addRow("Model", model, to: form); addRow("Reasoning effort", effort, to: form)
            runtime.stringValue = String(configuration?.maximumRuntimeMinutes ?? 60)
            addRow("Maximum runtime (minutes)", runtime, to: form)
            // Unattended runs never ask, so what they may do is decided here and approved with
            // the revision. Remote workers own their permissions and are not offered this.
            unattended.addItem(withTitle: L10n.string("Allow-list"))
            unattended.addItem(withTitle: L10n.string("Full permission"))
            let policy = configuration?.permissions ?? .readOnly
            unattended.selectItem(at: policy.isFull ? 1 : 0)
            unattended.target = self; unattended.action = #selector(unattendedChanged)
            addRow("Without asking", unattended, to: form)
            rules.textView.string = policy.rules.map(\.text).joined(separator: "\n")
            rules.textView.setAccessibilityIdentifier("automation.rules")
            rules.heightAnchor.constraint(equalToConstant: 90).isActive = true
            addRow("Rules (one per line)", rules, to: form)
            let grammar = NSTextField(wrappingLabelWithString: L10n.string(
                "Unattended runs never ask. Bash(command) or Bash(command *), Write(/folder/**), WebFetch(domain:example.com), mcp__server__tool. Reads and read-only commands are always allowed; anything else is refused."))
            grammar.applyFont(.detail()); grammar.textColor = Design.Text.secondary
            form.addArrangedSubview(grammar)
        }
        instructions.textView.string = configuration?.instructions ?? remoteSpec?.instruction ?? ""
        instructions.heightAnchor.constraint(equalToConstant: 100).isActive = true
        addRow("Instructions", instructions, to: form)
        let fields = scheduleFields
        fields.onChange = { [weak self] in self?.cadenceChanged() }
        addRow("Repeat", fields.cadence, to: form)
        if !remoteMode {
            for entry in sources { source.addItem(withTitle: entry.displayName) }
            if let id = configuration?.sourceID {
                if let index = sources.firstIndex(where: { $0.id == id }) { source.selectItem(at: index) }
                else { source.addItem(withTitle: L10n.string("Unavailable source")); source.selectItem(at: sources.count) }
            }
            eventKind.stringValue = configuration?.eventKind ?? ""
            addRow("Event source", source, to: form)
            addRow("Event kind", eventKind, to: form)
        }
        addRow("Time (HH:mm)", fields.time, to: form)
        addRow("Time zone", fields.zone, to: form)
        addRow("Days", fields.days, to: form)
        addRow("Interval (minutes)", fields.interval, to: form)
        missed.addItem(withTitle: L10n.string("Skip missed runs"))
        missed.addItem(withTitle: L10n.string("Run once on return"))
        missed.selectItem(at: configuration?.options.missedRunPolicy == .latest || remoteSpec?.missedPolicy == .latest ? 1 : 0)
        addRow("When offline", missed, to: form)
        archive.state = (configuration?.options.archiveOnSuccess ?? remoteSpec?.archiveOnSuccess ?? true) ? .on : .off
        addRow("Archive successful runs", archive, to: form)
        let note = NSTextField(wrappingLabelWithString: L10n.string("Saving pauses the automation. Enable it when you are ready. Results remain in Activity after a successful run is archived."))
        note.applyFont(.detail()); note.textColor = Design.Text.secondary
        form.addArrangedSubview(note)
        errorLabel.applyFont(.detail()); form.addArrangedSubview(errorLabel)
        let cancel = ThemedButton(); cancel.title = L10n.string("Cancel"); cancel.target = self; cancel.action = #selector(cancelPressed)
        cancel.keyEquivalent = "\u{1b}"
        save.title = L10n.string("Save automation"); save.emphasis = .primary; save.target = self; save.action = #selector(savePressed)
        let buttons = NSStackView(views: [NSView(), cancel, save]); buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -Design.Spacing.medium),
            form.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.pane)
        ])
        for child in form.arrangedSubviews { child.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        cadenceChanged()
        unattendedChanged()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(name) }
    private func addRow(_ title: String, _ control: NSView, to form: NSStackView) {
        let label = NSTextField(labelWithString: L10n.string(title)); label.applyFont(.detail()); label.textColor = Design.Text.secondary
        control.setAccessibilityLabel(L10n.string(title))
        let row = NSStackView(views: [label, control]); row.orientation = .vertical; row.alignment = .leading; row.spacing = Design.Spacing.tight
        if !(control is ThemedToggle) { control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
        form.addArrangedSubview(row)
    }
    private func cadenceChanged() {
        scheduleFields.updateEnabled()
        let isEvent = scheduleFields.isAlternativeSelected
        source.isEnabled = isEvent; eventKind.isEnabled = isEvent
    }
    @objc private func unattendedChanged() {
        rules.textView.isEditable = unattended.indexOfSelectedItem == 0
        rules.alphaValue = unattended.indexOfSelectedItem == 0 ? 1 : 0.5
    }
    @objc private func cancelPressed() { presentingViewController?.dismiss(self) }
    @objc private func savePressed() {
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
        config.checkoutPolicy = checkout.indexOfSelectedItem == 1 ? .managedWorktree : .projectCheckout
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
