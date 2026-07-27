import AppKit
import SkalmanExtensionKit

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
    private lazy var importButton = ThemedButton(
        symbol: ComposerDefaults.importSymbol,
        accessibility: "Import conversation",
        target: self,
        action: #selector(importTapped)
    )

    /// Conversations found on disk for the current project, once discovery has finished.
    ///
    /// Scanning a busy project takes a couple of seconds, so it runs when the composer is
    /// shown and the chip stays hidden until there is something to offer.
    private var importable: [ImportableSession] = []

    /// Whether the next session is rendered by Skalman rather than shown as a terminal.
    /// Experimental, and offered only for agents with a structured headless transport.
    private var usesNativeUI = false
    private let promptView = PromptView()
    private var promptContentContainer: ComponentContentContainer!
    private var promptCustomizationHost: ComponentCustomizationHost!
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

        importButton.isBordered = true

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        // The choices, then what they will cost, then the task. Reading down the column is
        // the decision in order — which is the whole reason a session starts here rather than
        // from a menu item that picked all four defaults silently.
        let chips = NSStackView(views: [
            agentChip, accountChip, modelChip, branchChip, surfaceChip
        ])
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = Design.Spacing.small

        // Chips shrink their labels to fit a tight row, which with six of them left a row of
        // bare icons naming nothing. They hold their size here and the row stays short.
        for chip in [agentChip, accountChip, modelChip, branchChip, surfaceChip] {
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        wirePrompt()
        setupPromptCustomization()

        let stack = NSStackView(
            views: [headings, chips, usagePanel, promptContentContainer, importButton]
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
    /// leading/trailing accessories but can never lose the text field or submit control.
    private func setupPromptCustomization() {
        promptContentContainer = ComponentContentContainer(defaultContent: promptView)
        promptContentContainer.setAccessibilityIdentifier("composer.session-start.content")
        promptCustomizationHost = ComponentCustomizationHost(
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
        promptView.placeholder = ComposerDefaults.promptPlaceholder
        promptView.minimumHeight = ComposerDefaults.promptHeight

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
            self?.selectedAgent = item.representedValue as? AgentKind ?? AgentDefaults.defaultKind
            self?.selectedAccountHandle = .standard
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
        selectedAccountHandle = .standard
        selectedModel = nil
        selectedBranch = nil

        // The choices reset per project; what was typed does not. A half-written prompt is
        // the user's work, and it is restored whether it was left behind by switching
        // projects or by the app going away underneath it.
        promptView.stringValue = DraftStore.shared.draft(for: projectID)

        // Warmed as the composer appears, not as its account menu opens: a fetch started on
        // the click lands after the menu has been read and dismissed.
        AccountUsageMenu.prefetch()

        headingLabel.stringValue = project.name
        subheadingLabel.stringValue = subheading(for: project)

        refreshChips()
        discoverImportable(for: project)
    }

    /// Keeps component targeting separate from project lookup so the shell can be exercised
    /// without manufacturing persisted project state. Product navigation calls it through
    /// `show(projectID:)`.
    func updatePromptCustomization(for projectID: ProjectID?) {
        guard let projectID else {
            promptCustomizationHost?.deactivate()
            return
        }
        promptCustomizationHost?.updateTarget(
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

        // Offered only for agents whose conversation Skalman may render itself — both real
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

        var items: [ThemedMenuEntry] = [
            .item(
                ThemedMenuItem(
                    title: defaultTitle,
                    representedValue: nil,
                    isSelected: selectedModel == nil
                )
            )
        ]

        items += AgentModels.available(for: selectedAgent, account: account).map { model in
            .item(
                ThemedMenuItem(
                    title: ModelName.display(for: model),
                    representedValue: model,
                    isSelected: model == selectedModel
                )
            )
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
            prompt: prompt
        )
    }

    /// The choice of surface: the agent's own terminal, or Skalman's conversation view.
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
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "A worktree lets a session run on its own branch without "
            + "disturbing this checkout."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = ThemedTextField(frame: NSRect(
            x: 0, y: 0,
            width: ComposerDefaults.branchFieldWidth,
            height: ComposerDefaults.branchFieldHeight
        ))
        field.placeholderString = "branch name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func present(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not create worktree"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
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
    static let defaultModelTitle = "Default model"

    /// Marks the CLI's own choice in the model menu, so picking it explicitly and leaving it
    /// alone are visibly the same thing.
    static let accountDefaultSuffix = "  (account default)"
    static let noBranchTitle = "No branch"
    static let newWorktreeTitle = "New Worktree…"

    /// Marks the project's own folder in the branch menu, so the default reads as a place
    /// rather than as one branch name among several.
    static let thisCheckoutSuffix = "this checkout"

    /// A session is the durable object; these names describe only the UI rendering it.
    static let nativeTitle = "Native (Experimental)"
    static let surfaceSymbol = "bubble.left.and.text.bubble.right"
    static let promptPlaceholder = "Describe a task or ask a question"

    static let importSymbol = "tray.and.arrow.down"

    /// Counted, because the number is what tells the user whether it is worth opening.
    static func importTitle(count: Int) -> String {
        count == 1 ? "Import 1 conversation" : "Import \(count) conversations"
    }

    static let accountSymbol = "person.crop.circle"
    static let modelSymbol = "cpu"
    static let branchSymbol = "arrow.trianglehead.branch"
}
