import AppKit
import ThreadingExtensionKit

/// Shown when a project is selected: choose how a session should start, then start it.
///
/// A project has no terminal of its own, so selecting one offers the decisions that are only
/// made once — agent, account, model, which checkout — rather than an empty pane.
final class SessionComposerViewController: NSViewController {

    // MARK: - Properties

    private(set) var projectID: ProjectID?

    private let headingLabel = NSTextField(labelWithString: "")
    private let subheadingLabel = NSTextField(labelWithString: "")

    private let agentChip = ChipView()
    private let accountChip = ChipView()
    private let modelChip = ChipView()
    private let branchChip = ChipView()
    private let surfaceChip = ChipView()
    private let modeChip = ChipView()
    private lazy var importButton = ThemedButton(
        symbol: ComposerDefaults.importSymbol,
        accessibility: L10n.string("Import conversation"),
        target: self,
        action: #selector(importTapped)
    )

    /// The one thing this screen is for, stated as a button rather than as a glyph in the
    /// corner of the prompt.
    ///
    /// A composer's prompt is a *brief* — several lines, often a pasted paragraph — so Return
    /// belongs to the text and the send has to live somewhere else. Out here it is also the
    /// only primary on the page, which is what makes the row underneath read as one loud
    /// action and one quiet one instead of two equal offers.
    private lazy var startButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Start session"),
            target: self,
            action: #selector(startTapped)
        )
        button.emphasis = .primary
        button.shortcut = ComposerDefaults.startShortcut
        button.setAccessibilityIdentifier("composer.session-start.submit")
        return button
    }()

    /// Conversations found on disk for the current project, once discovery has finished.
    ///
    /// Scanning a busy project takes a couple of seconds, so it runs when the composer is
    /// shown and the chip stays hidden until there is something to offer.
    private var importable: [ImportableSession] = []

    /// Whether the next session is rendered by Threading rather than shown as a terminal.
    /// Experimental, and offered only for agents with a structured headless transport.
    private var usesNativeUI = false
    private let promptView = PromptView()
    private lazy var promptContentContainer = ComponentContentContainer(defaultContent: promptView)
    private lazy var promptCustomizationHost = ComponentCustomizationHost(
        target: .sessionStartComposer(),
        contentContainer: promptContentContainer,
        lookup: customizationLookup,
        imageResolver: ExtensionComponentResourceResolver.image,
        onAction: { [weak self] action in
            guard let self else { return }
            if let onCustomizationAction {
                onCustomizationAction(action)
            } else {
                ComponentCustomizationProviderSlot.shared.perform(action)
            }
        }
    )
    private let customizationLookup: ComponentCustomizationHost.Lookup

    /// Invoked for semantic actions in extension-provided prompt accessories.
    var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?

    /// What is left of the account the chips currently name.
    private let usagePanel = AccountUsagePanelView()
    private let appEvents = AppEventObservations()

    private var selectedAgent: AgentKind = AgentDefaults.defaultKind
    private var selectedAccountHandle: AccountHandle = .standard
    private var selectedModel: String?
    private var selectedBranch: String?

    /// How much the session may do before it has to ask. Nil follows
    /// `AppSettings.defaultPermissionMode`, and the CLI's own configuration beyond that.
    private var selectedPermissionMode: AgentPermissionMode?

    weak var delegate: SessionComposerViewControllerDelegate?

    // MARK: - Initialization

    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
    ) {
        self.customizationLookup = customizationLookup
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        headingLabel.applyFont(.heading)
        headingLabel.textColor = Design.Text.label

        subheadingLabel.applyFont(.subheading)
        subheadingLabel.textColor = Design.Text.secondary

        importButton.emphasis = .secondary

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        // The choices, then what they will cost, then the task. Reading down the column is
        // the decision in order — which is the whole reason a session starts here rather than
        // from a menu item that picked all four defaults silently.
        let chips = NSStackView(views: [
            agentChip, accountChip, modelChip, modeChip, branchChip, surfaceChip
        ])
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = Design.Spacing.small

        // Chips shrink their labels to fit a tight row, which with six of them left a row of
        // bare icons naming nothing. They hold their size here and the row stays short.
        for chip in [agentChip, accountChip, modelChip, modeChip, branchChip, surfaceChip] {
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        wirePrompt()
        setupPromptCustomization()

        // The action and the alternative to it, in that order: pressing Start is what this
        // screen is for, and adopting a conversation that already exists is the other way to
        // arrive at the same place. Import keeps the secondary shape it already had — beside
        // a primary it now reads as the quieter of two, which is what it always was.
        let actions = NSStackView(views: [startButton, importButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let stack = NSStackView(
            views: [headings, chips, usagePanel, promptContentContainer, actions]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.setCustomSpacing(Design.Spacing.large, after: usagePanel)
        stack.setCustomSpacing(Design.Spacing.large, after: promptContentContainer)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        // Sits above centre rather than dead centre: a composer reads as the top of the work
        // about to happen, not as a dialog floating in the middle of an empty pane.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: ComposerDefaults.topOffset
            ),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: ComposerDefaults.contentWidth),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            promptContentContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            usagePanel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        wireChips()
        observeUsage()
    }

    /// Places the protected native prompt behind the generic around-hook host. The contract only
    /// accepts horizontal hooks containing exactly one `.proceed`, so this container can gain
    /// leading/trailing accessories but can never lose the text field. The send is outside the
    /// container entirely — an extension cannot reach the action row at all, which is a stronger
    /// guarantee than the one the `.proceed` rule gives the field.
    private func setupPromptCustomization() {
        promptContentContainer.setAccessibilityIdentifier("composer.session-start.content")
        // A family-wide patch must not appear before the composer has a real project context.
        promptCustomizationHost.deactivate()
    }

    /// A reading arriving after the composer is on screen redraws the panel in place, rather
    /// than waiting for the next time an account is picked.
    private func observeUsage() {
        appEvents.observe(AccountUsageDidChange.self) { [weak self] _ in
            self?.refreshUsagePanel()
        }
    }

    private func wirePrompt() {
        promptView.showsImageAttachments = true
        promptView.placeholder = ComposerDefaults.promptPlaceholder
        promptView.minimumHeight = ComposerDefaults.promptHeight
        // Return belongs to the text here; `startButton` sends. See `PromptView.SubmitPlacement`.
        promptView.submitPlacement = .outside

        promptView.onSubmit = { [weak self] prompt in
            self?.start(with: prompt)
        }

        // Kept on disk as it is typed. Until the session starts, this text exists nowhere
        // else — no transcript, no terminal, no shell history — so an unexpected quit is
        // otherwise the end of it.
        promptView.onChange = { [weak self] text in
            guard let self, let projectID = self.projectID else { return }
            DraftStore.shared.setDraft(text, for: projectID)
        }
    }

    /// Each chip rebuilds its menu when opened, so a change of agent is reflected everywhere.
    private func wireChips() {
        agentChip.itemsProvider = { [weak self] in self?.agentItems() ?? [] }
        agentChip.onSelect = { [weak self] item in
            let kind = item.representedValue as? AgentKind ?? AgentDefaults.defaultKind
            self?.selectedAgent = kind
            self?.selectedAccountHandle = AgentAccountDiscovery.preferredHandle(for: kind)
            self?.selectedModel = nil
            self?.refreshChips()
        }

        accountChip.itemsProvider = { [weak self] in self?.accountItems() ?? [] }
        accountChip.onSelect = { [weak self] item in
            self?.selectedAccountHandle = item.representedValue as? AccountHandle ?? .standard
            self?.selectedModel = nil
            self?.refreshChips()
        }

        modelChip.itemsProvider = { [weak self] in self?.modelItems() ?? [] }
        modelChip.onSelect = { [weak self] item in
            self?.selectedModel = item.representedValue as? String
            self?.refreshChips()
        }

        modeChip.itemsProvider = { [weak self] in self?.permissionModeItems() ?? [] }
        modeChip.onSelect = { [weak self] item in
            // Nil is a real answer here — the first item — so this reads "not a mode" as
            // inherit rather than falling back to one.
            self?.selectedPermissionMode = item.representedValue as? AgentPermissionMode
            self?.refreshChips()
        }

        surfaceChip.itemsProvider = { [weak self] in self?.surfaceItems() ?? [] }
        surfaceChip.onSelect = { [weak self] item in
            self?.usesNativeUI = (item.representedValue as? Bool) ?? false
            self?.refreshChips()
        }

        branchChip.itemsProvider = { [weak self] in self?.branchItems() ?? [] }
        branchChip.onSelect = { [weak self] item in
            guard let self else { return }

            switch item.representedValue as? BranchSelection {
            case .checkout(let branch):
                self.selectedBranch = branch
            case .newWorktree:
                // Leaves the selection alone: creating a worktree adds a project and moves
                // the composer to it, so this composer's branch never applies.
                self.createWorktree()
            case .thisCheckout, .none:
                self.selectedBranch = nil
            }

            self.refreshChips()
        }
    }

    // MARK: - Public Methods

    /// Points the composer at a project, resetting every choice for it.
    func show(projectID: ProjectID?) {
        self.projectID = projectID

        guard let projectID, let project = ProjectStore.shared.project(withID: projectID) else {
            updatePromptCustomization(for: nil)
            return
        }

        updatePromptCustomization(for: projectID)

        selectedAgent = AppSettings.shared.defaultAgentKind
        // The login this agent offers rather than the standard handle: the standard one may be
        // exactly the account the user switched off, and a composer that still starts there
        // would launch on it while naming it in the chip.
        selectedAccountHandle = AgentAccountDiscovery.preferredHandle(for: selectedAgent)
        selectedModel = nil
        selectedBranch = nil
        selectedPermissionMode = nil

        // The choices reset per project; what was typed does not. A half-written prompt is
        // the user's work, and it is restored whether it was left behind by switching
        // projects or by the app going away underneath it.
        promptView.clearAttachments()
        promptView.stringValue = DraftStore.shared.draft(for: projectID)

        // Warmed as the composer appears, not as its account menu opens: a fetch started on
        // the click lands after the menu has been read and dismissed.
        AccountUsageMenu.prefetch()

        headingLabel.stringValue = project.name
        subheadingLabel.stringValue = subheading(for: project)

        refreshChips()
        discoverImportable(for: project)
    }

    /// Puts the caret in the prompt.
    ///
    /// The pane hands focus to whatever it puts on screen — a terminal takes it in `attach`, a
    /// native conversation's prompt in `attachConversation` — and this is the same surface for a
    /// session that does not exist yet. Arriving here by ⌘N or by selecting a project, the only
    /// thing being asked for is what to type, so the field should not have to be clicked first.
    ///
    /// Skipped when an extension has replaced the prompt: the native editor is hidden then, and
    /// AppKit answers `makeFirstResponder` for a hidden view by clearing the window's instead.
    func focusPrompt() {
        guard !promptView.isHiddenOrHasHiddenAncestor else { return }
        promptView.focusAtEnd()
    }

    /// Re-reads everything the chips *derive* — the app-wide defaults they name, the account
    /// they resolve, what is left of it — while leaving every choice and the prompt untouched.
    ///
    /// For a composer coming back into view without having been re-configured. Settings is
    /// where those defaults are changed, so a composer restored from it must state them again.
    func refreshDerivedState() {
        refreshChips()
    }

    /// Keeps component targeting separate from project lookup so the shell can be exercised
    /// without manufacturing persisted project state. Product navigation calls it through
    /// `show(projectID:)`.
    func updatePromptCustomization(for projectID: ProjectID?) {
        guard let projectID else {
            promptCustomizationHost.deactivate()
            return
        }
        promptCustomizationHost.updateTarget(
            .sessionStartComposer(projectID: projectID.uuidString.lowercased())
        )
    }

    /// Looks for conversations this project could adopt, revealing the chip if any are found.
    ///
    /// The result is checked against the project it was requested for: scanning takes long
    /// enough that the user can select another project before it finishes.
    private func discoverImportable(for project: Project) {
        importable = []
        importButton.isHidden = true

        SessionImporter.discover(for: project) { [weak self] found in
            guard let self, self.projectID == project.id else { return }

            self.importable = found
            self.refreshImportChip()
        }
    }

    private func refreshImportChip() {
        importButton.isHidden = importable.isEmpty
        importButton.title = ComposerDefaults.importTitle(count: importable.count)
    }

    // MARK: - Chip State

    private func refreshChips() {
        agentChip.configure(icon: selectedAgent.icon, title: selectedAgent.displayName)

        let accounts = AgentAccountDiscovery.accounts(for: selectedAgent)
        let account = AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)

        // A menu of one is noise: the chip only appears when there is a choice to make.
        accountChip.isHidden = accounts.count < 2
        accountChip.configure(
            symbolName: ComposerDefaults.accountSymbol,
            title: account.map(AccountName.display) ?? ""
        )

        let models = AgentModels.available(for: selectedAgent, account: account)
        modelChip.isHidden = models.isEmpty
        modelChip.configure(
            symbolName: ComposerDefaults.modelSymbol,
            title: modelChipTitle(for: account)
        )

        // Names the mode that will actually apply, not only the one chosen here: with no
        // choice of its own the chip shows the app-wide default, and falls back to naming
        // where the decision goes when there is no default either.
        modeChip.configure(
            symbolName: ComposerDefaults.permissionModeSymbol,
            title: (selectedPermissionMode ?? AppSettings.shared.defaultPermissionMode)?
                .displayName ?? ComposerDefaults.followsCLIPermissionModeTitle
        )

        // Offered only for agents whose conversation Threading may render itself — both real
        // agents, not shells. See `AgentKind.supportsNativeUI`.
        surfaceChip.isHidden = !selectedAgent.supportsNativeUI
        if surfaceChip.isHidden { usesNativeUI = false }
        surfaceChip.configure(
            symbolName: ComposerDefaults.surfaceSymbol,
            title: usesNativeUI ? ComposerDefaults.nativeTitle : selectedAgent.originalUITitle
        )

        refreshUsagePanel(account: account)

        let isRepository = projectFolder.map { GitInfo.repositoryRoot(for: $0) != nil } ?? false
        branchChip.isHidden = !isRepository
        branchChip.configure(
            symbolName: ComposerDefaults.branchSymbol,
            title: selectedBranch ?? currentBranchTitle
        )
    }

    /// Draws the chosen account's usage, fetching when the reading has aged out.
    ///
    /// The account is passed in when the caller has already resolved it, since resolving one
    /// scans the filesystem and `refreshChips` runs on every chip change.
    private func refreshUsagePanel(account: AgentAccount? = nil) {
        let account = account ?? AgentAccountDiscovery.account(
            for: selectedAgent,
            handle: selectedAccountHandle
        )

        guard let account else {
            usagePanel.isHidden = true
            return
        }

        AccountUsageService.shared.refresh(account)

        usagePanel.show(
            accountName: AccountName.display(for: account),
            usage: AccountUsageService.shared.usage(for: account),
            error: AccountUsageService.shared.errorMessage(for: account),
            account: account
        )
    }

    private var projectFolder: String? {
        projectID.flatMap { ProjectStore.shared.project(withID: $0)?.folderPath }
    }

    private var currentBranchTitle: String {
        projectFolder.flatMap { GitInfo.currentBranch(for: $0) } ?? ComposerDefaults.noBranchTitle
    }

    /// Where the session will run, which is the one thing not otherwise visible.
    private func subheading(for project: Project) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = project.folderPath
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Menus

    private func agentItems() -> [ThemedMenuEntry] {
        AgentKind.allCases.map { kind in
            .item(
                ThemedMenuItem(
                    title: kind.displayName,
                    representedValue: kind,
                    isSelected: kind == selectedAgent
                )
            )
        }
    }

    private func accountItems() -> [ThemedMenuEntry] {
        AgentAccountDiscovery.accounts(for: selectedAgent).map { account in
            let name = AccountName.display(for: account)
            var item = ThemedMenuItem(
                // The emoji when the account has one: it is how the same login is identified in
                // the sidebar, and a menu that names it differently makes the user learn it
                // twice.
                title: account.emoji.map { "\($0)  \(name)" } ?? name,
                representedValue: account.handle,
                isSelected: account.handle == selectedAccountHandle
            )

            // Which login to start on is decided here, so this is where what is left of each
            // one belongs — not only in the toolbar, which speaks after the choice is made.
            // Read against the model this session will run, since the account's own windows are
            // not the whole story when the plan meters that model separately.
            AccountUsageMenu.decorate(&item, for: account, metering: modelToLaunch(on: account))
            return .item(item)
        }
    }

    /// The model a session started now would run on `account`: an explicit choice, else what
    /// that account is configured to use. Resolved per account, because the configured default
    /// is the account's own setting rather than a global one.
    private func modelToLaunch(on account: AgentAccount) -> String? {
        selectedModel ?? AgentModels.defaultModel(for: selectedAgent, account: account)
    }

    /// What the chip says: the chosen model, else the one the account is configured to use,
    /// else "Default".
    ///
    /// Naming the resolved model is the point. "Default model" answers a question nobody asked
    /// — the user knows they have not chosen one — while the thing they actually want to know
    /// is what this session will run on, which the account's own settings already state.
    private func modelChipTitle(for account: AgentAccount?) -> String {
        if let selectedModel { return ModelName.display(for: selectedModel) }

        guard let configured = AgentModels.defaultModel(for: selectedAgent, account: account) else {
            return ComposerDefaults.defaultModelTitle
        }
        return ModelName.display(for: configured)
    }

    private func modelItems() -> [ThemedMenuEntry] {
        let account = AgentAccountDiscovery.account(for: selectedAgent, handle: selectedAccountHandle)
        let configured = AgentModels.defaultModel(for: selectedAgent, account: account)

        // The first item is "leave it to the CLI", so it names what the CLI would pick rather
        // than leaving the user to find out by starting a session.
        let defaultTitle = configured.map {
            "\(ModelName.display(for: $0))\(ComposerDefaults.accountDefaultSuffix)"
        } ?? ComposerDefaults.defaultModelTitle

        // Where a scoped limit is finally actionable: a spent Fable window is escaped by
        // picking another model, and this is the menu that does it. Each row states its own
        // window rather than the account's, which every row would otherwise repeat.
        var defaultItem = ThemedMenuItem(
            title: defaultTitle,
            representedValue: nil,
            isSelected: selectedModel == nil
        )
        if let account, let configured {
            AccountUsageMenu.decorate(&defaultItem, forModel: configured, on: account)
        }

        var items: [ThemedMenuEntry] = [.item(defaultItem)]

        items += AgentModels.available(for: selectedAgent, account: account).map { model in
            var item = ThemedMenuItem(
                title: ModelName.display(for: model),
                representedValue: model,
                isSelected: model == selectedModel
            )
            if let account {
                AccountUsageMenu.decorate(&item, forModel: model, on: account)
            }
            return .item(item)
        }
        return items
    }

    /// Where the session will run: this checkout, another checkout already added, or one
    /// created now.
    ///
    /// Only checkouts are listed, not branches. A branch with nothing standing on it is not a
    /// place a session can run — offering the repository's whole `git branch` output invited
    /// picking one that resolved to nothing, and the session then ran here anyway while its
    /// record claimed otherwise.
    private func branchItems() -> [ThemedMenuEntry] {
        guard let projectID, let project = ProjectStore.shared.project(withID: projectID) else {
            return []
        }

        let current = GitInfo.currentBranch(for: project.folderPath)

        var items: [ThemedMenuEntry] = [
            .item(
                ThemedMenuItem(
                    title: current.map {
                        "\($0) — \(ComposerDefaults.thisCheckoutSuffix)"
                    } ?? project.name,
                    representedValue: BranchSelection.thisCheckout,
                    isSelected: selectedBranch == nil
                )
            )
        ]

        items += ProjectStore.shared.siblingCheckouts(of: projectID).map { sibling in
            .item(
                ThemedMenuItem(
                    title: sibling.branch,
                    representedValue: BranchSelection.checkout(sibling.branch),
                    isSelected: sibling.branch == selectedBranch
                )
            )
        }
        items.append(.separator)
        items.append(
            .item(
                ThemedMenuItem(
                    title: ComposerDefaults.newWorktreeTitle,
                    representedValue: BranchSelection.newWorktree
                )
            )
        )
        return items
    }

    // MARK: - Actions

    private func start(with prompt: String) {
        guard let projectID else { return }

        delegate?.sessionComposer(
            self,
            startSessionIn: projectID,
            kind: selectedAgent,
            accountHandle: selectedAccountHandle,
            model: selectedModel,
            branch: selectedBranch,
            usesNativeUI: usesNativeUI,
            permissionMode: selectedPermissionMode,
            prompt: prompt
        )
    }

    /// How much the session may do before it has to ask.
    ///
    /// The first item inherits, and names what it would inherit — the app-wide default where
    /// there is one, and otherwise the CLI's own configuration, which Threading cannot read.
    /// Each mode carries what it means, and where the chosen agent expresses it imperfectly it
    /// says so: Codex has no plan mode, and a menu that offered "Plan" without that sentence
    /// would be promising something it cannot deliver.
    private func permissionModeItems() -> [ThemedMenuEntry] {
        let inherited = AppSettings.shared.defaultPermissionMode

        var items: [ThemedMenuEntry] = [
            .item(
                ThemedMenuItem(
                    title: ComposerDefaults.inheritedPermissionModeTitle(inherited),
                    representedValue: nil,
                    isSelected: selectedPermissionMode == nil
                )
            )
        ]

        items += AgentPermissionMode.allCases.map { mode in
            .item(
                ThemedMenuItem(
                    title: mode.displayName,
                    subtitle: [mode.menuDescription, mode.caveat(for: selectedAgent)]
                        .compactMap { $0 }
                        .joined(separator: " "),
                    representedValue: mode,
                    isSelected: mode == selectedPermissionMode
                )
            )
        }

        return items
    }

    /// The choice of surface: the agent's own terminal, or Threading's conversation view.
    private func surfaceItems() -> [ThemedMenuEntry] {
        [false, true].map { isNative in
            .item(
                ThemedMenuItem(
                    title: isNative ? ComposerDefaults.nativeTitle : selectedAgent.originalUITitle,
                    representedValue: isNative,
                    isSelected: isNative == usesNativeUI
                )
            )
        }
    }

    /// Offers the conversations found on disk, adopting whichever is chosen.
    private func presentImportPicker() {
        guard let projectID, !importable.isEmpty else { return }

        let picker = SessionImportViewController(sessions: importable)
        picker.onPick = { [weak self, weak picker] chosen in
            guard let self, let picker else { return }
            self.dismiss(picker)

            guard let chosen else { return }

            // Dropped from the list as well as adopted: the project now tracks it, and
            // offering it again would only be refused as a duplicate.
            self.importable.removeAll { $0.id == chosen.id }
            self.refreshImportChip()

            self.delegate?.sessionComposer(self, importSession: chosen, into: projectID)
        }

        presentAsSheet(picker)
    }

    @objc private func importTapped() {
        presentImportPicker()
    }

    /// Goes through the prompt rather than reading its text, so the button and ⌘Return send
    /// the same thing — the words *and* whatever images were dropped beside them.
    @objc private func startTapped() {
        promptView.submit()
    }

    private func createWorktree() {
        guard let projectID, let project = ProjectStore.shared.project(withID: projectID) else {
            return
        }

        guard let branch = promptForBranchName() else { return }
        guard let destination = GitWorktree.suggestedLocation(forBranch: branch, in: project) else {
            present(error: GitWorktree.Failure.notARepository)
            return
        }

        do {
            let created = try GitWorktree.create(branch: branch, at: destination, from: project)
            delegate?.sessionComposer(self, didCreateWorktreeAt: created, branch: branch)
        } catch {
            present(error: error)
        }
    }

    // MARK: - Private Methods

    private func promptForBranchName() -> String? {
        let request = TextPromptRequest(
            title: L10n.string("New Worktree"),
            message: L10n.string(
                "A worktree lets a session run on its own branch without disturbing this checkout."
            ),
            confirmTitle: L10n.string("Create"),
            placeholder: L10n.string("branch name"),
            fieldSize: NSSize(
                width: ComposerDefaults.branchFieldWidth,
                height: ComposerDefaults.branchFieldHeight
            )
        )

        guard case .text(let branch)? = TextPromptAlert.ask(request) else { return nil }
        return branch
    }

    private func present(error: Error) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Could not create worktree")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }
}

// MARK: - SessionComposerViewControllerDelegate

@MainActor
protocol SessionComposerViewControllerDelegate: AnyObject {
    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        prompt: String
    )

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    )

    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSession session: ImportableSession,
        into projectID: ProjectID
    )
}

// MARK: - Branch Selection

/// What the branch chip's menu offers: a place to run, or the action that makes one.
///
/// The worktree action lived in a chip of its own, which read as a *state* — one of the
/// choices in the row, seemingly selected — when it is a thing that happens. Folded in here,
/// one control answers one question: which checkout does this session run in.
private enum BranchSelection {
    case thisCheckout
    case checkout(String)
    case newWorktree
}

// MARK: - Composer Defaults

/// Only what is specific to this screen. Everything visual comes from `Design`.
enum ComposerDefaults {
    /// Placed a little above centre, so the composer reads as the start of the work.
    static let topOffset: CGFloat = 72

    /// Wider than `readableWidth`, which paces prose. This column holds a row of controls
    /// and two usage bars, and squeezing those to a reading measure is what shrank the chips
    /// to unlabelled icons.
    static let contentWidth: CGFloat = 720

    /// The prompt opens several lines tall. The composer owns the whole pane and is replaced
    /// by the conversation the moment it is used, so there is nothing to be compact for — and
    /// the size of the box is what says how much of a description is wanted.
    static let promptHeight: CGFloat = 116

    static let branchFieldWidth: CGFloat = 260
    static let branchFieldHeight: CGFloat = 24

    /// Only shown when the account states no model of its own — otherwise the chip names the
    /// model the session will actually run on.
    static var defaultModelTitle: String { L10n.string("Default model") }

    /// Marks the CLI's own choice in the model menu, so picking it explicitly and leaving it
    /// alone are visibly the same thing.
    static var accountDefaultSuffix: String { L10n.string("  (account default)") }
    static var noBranchTitle: String { L10n.string("No branch") }
    static var newWorktreeTitle: String { L10n.string("New Worktree…") }

    /// Marks the project's own folder in the branch menu, so the default reads as a place
    /// rather than as one branch name among several.
    static var thisCheckoutSuffix: String { L10n.string("this checkout") }

    /// A session is the durable object; these names describe only the UI rendering it.
    static var nativeTitle: String { L10n.string("Native (Experimental)") }
    static let surfaceSymbol = "bubble.left.and.text.bubble.right"
    static let permissionModeSymbol = "hand.raised"

    /// What the chip says when nothing here or in Settings has chosen: it names *where* the
    /// decision is made rather than guessing what the CLI's own config says, which Threading
    /// cannot read and must not claim to know.
    static var followsCLIPermissionModeTitle: String { L10n.string("Agent's Setting") }

    /// The inherit item's wording, given the app-wide default. It names the inherited answer
    /// where there is one and defers where there is not, so choosing the default explicitly
    /// and leaving it alone are visibly the same thing.
    static func inheritedPermissionModeTitle(_ inherited: AgentPermissionMode?) -> String {
        guard let inherited else { return L10n.string("Use Agent's Setting") }
        return L10n.format("Use Default (%@)", inherited.displayName)
    }
    static var promptPlaceholder: String {
        L10n.string("Describe a task or ask a question")
    }

    static let importSymbol = "tray.and.arrow.down"

    /// What the start button names and answers to. ⌘Return rather than Return, because Return
    /// is a line break in a box this size — and the button says so on its face rather than
    /// leaving the user to discover it.
    static let startShortcut = KeyboardShortcut(key: "\r", modifiers: .command)

    /// Counted, because the number is what tells the user whether it is worth opening.
    static func importTitle(count: Int) -> String {
        count == 1
            ? L10n.string("Import 1 conversation")
            : L10n.format("Import %lld conversations", Int64(count))
    }

    static let accountSymbol = "person.crop.circle"
    static let modelSymbol = "cpu"
    static let branchSymbol = "arrow.trianglehead.branch"
}
