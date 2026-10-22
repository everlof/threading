#if os(Linux)
import AppKit
import Foundation
import Glibc
import LinuxWindowBridge
@testable import CoreSlice

@MainActor
private final class ComposerChipChoiceSession: ChipChoicePresentationSession {
    private var didDismiss: (() -> Void)?

    init(didDismiss: @escaping () -> Void) { self.didDismiss = didDismiss }

    func dismissChipChoicePresentation() {
        let callback = didDismiss
        didDismiss = nil
        callback?()
    }
}

/// A host-resolved runtime and login. An empty account name represents a runtime's plain
/// default login, while `id` always identifies both runtime and account for launch routing.
struct ComposerIdentityChoice {
    let id: String
    let providerName: String
    let accountName: String
    let icon: NSImage?

    var title: String {
        accountName.isEmpty ? providerName : "\(providerName) · \(accountName)"
    }
}

struct ComposerCheckoutChoice: Equatable {
    let id: String
    let title: String
    let detail: String
}

struct ComposerPermissionChoice {
    let id: String
    let title: String
    let detail: String
}

/// The idle workspace's bounded production content view. It keeps one view tree and texture
/// while project rows change, and repaints only for resize or interaction.
@MainActor
final class WorkspacePlaceholderPane {
    private(set) var title = ""
    private(set) var detail = ""
    private(set) var actionTitle = ""

    private let window = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
    private let composerRoot = NSView(frame: .zero)
    private let composerHero = ComposerWelcomeView(frame: .zero)
    private let composerColumn = NSStackView()
    private let destinationRow = NSStackView()
    private let actionRow = NSView(frame: .zero)
    private let composerSurface = PromptView(frame: .zero)
    private let composerStartButton = ThemedButton()
    private lazy var projectChip = ChipView()
    private lazy var providerChip = ChipView()
    private let modelChip = ChipView()
    private let speedChip = ChipView()
    private let surfaceChip = ChipView()
    private var modelSelectionValid = true
    private var modelPresentation: ModelEffortPickerPresentation?
    private var modelContent: ModelEffortPickerContentView?
    private var modelContentConstraints: [NSLayoutConstraint] = []
    private var modelShowHiddenButton: ThemedButton?
    private var modelMenuToken = ""
    private var selectedModelTitle = "Default model"
    private var hiddenModelCount = 0
    private var onModelChoice: ((String?, String?) -> Void)?
    private var onModelRefresh: (() -> Void)?
    private var onHideModel: ((String) -> Void)?
    private var onShowHiddenModels: (() -> Void)?
    private let permissionChip = ChipView()
    private let choiceSurface = ThemedMenuPanelView(frame: .zero)
    private enum ChoiceKind: Int { case project = 1, identity = 2, permission = 3, model = 4, surface = 5, speed = 6 }
    private struct ChoiceOption {
        let id: String
        let name: String
        let icon: NSImage?
        var detail: String? = nil
    }
    private var choiceKind: ChoiceKind?
    private var choiceSession: ComposerChipChoiceSession?
    private var choiceRows: [ThemedMenuRowView] = []
    private var choiceFirst = 0
    private var choiceSelected = 0
    private var choiceVisibleCount = 0
    private var choiceOptions: [ChoiceOption] = []
    private var projectOptions: [(id: String, name: String)] = []
    private var checkoutOptions: [ComposerCheckoutChoice] = []
    private var selectedCheckoutID = ""
    private var showingProjectNavigation = false
    private var identityOptions: [ComposerIdentityChoice] = []
    private var permissionOptions: [ComposerPermissionChoice] = []
    private var surfaceOptions: [ChoiceOption] = []
    private var speedOptions: [ChoiceOption] = []
    private var selectedSpeedID = "inherit"
    private var selectedSpeedTitle = "Agent's Setting"
    private var onSpeedChoice: ((Bool?) -> Void)?
    private var selectedSurfaceID = "terminal"
    private var selectedSurfaceTitle = ""
    private var onSurfaceChoice: ((Bool) -> Void)?
    private var selectedPermissionID = "inherit"
    private var selectedPermissionTitle = "Agent's Setting"
    private var onPermissionChoice: ((String) -> Void)?
    private var choiceRowHeight: CGFloat = 26
    private var choiceWidth: CGFloat = 180
    private var choiceScrollRemainder: CGFloat = 0
    private var selectedProjectID = ""
    private var selectedIdentityID = ""
    private var selectedProjectName = ""
    private var selectedLocationTitle = ""
    private var selectedProviderName = ""
    private var selectedIdentityName = ""
    private var onProjectChoice: ((String) -> Void)?
    private var onCheckoutChoice: ((String) -> Void)?
    private var onNewWorktree: (() -> Void)?
    private var onIdentityChoice: ((String) -> Void)?
    private let showsComposer = true
    private(set) var composerIdentity: String?
    private var root: NSView { composerRoot }
    private var actionAnchor: ThemedButton { composerStartButton }
    private var hasLaunchProject = false
    private var hasLaunchIdentity = false
    private var launchBlocked = false
    private var presentedSize = NSSize.zero
    private var needsPresentation = true
    private var composerBottom: NSLayoutConstraint!

    init(onSubmit: @escaping () -> Void) {
        LinuxSymbols.install()
        composerRoot.addSubview(composerHero)
        composerHero.translatesAutoresizingMaskIntoConstraints = false
        let destinationSpacer = NSView()
        PromptChrome.configureOpeningChoices(destinationRow,
            choices: [projectChip, providerChip], spacer: destinationSpacer)
        projectChip.setContentCompressionResistancePriority(.init(239), for: .horizontal)
        providerChip.setContentCompressionResistancePriority(.required, for: .horizontal)

        actionRow.addSubview(composerStartButton)
        composerStartButton.translatesAutoresizingMaskIntoConstraints = false
        PromptChrome.configureOpeningColumn(composerColumn, choices: destinationRow,
            prompt: composerSurface, actionRow: actionRow)
        composerSurface.minimumHeight = PromptChrome.openingMinimumHeight
        composerSurface.submitPlacement = .outside
        composerSurface.showsImageAttachments = true
        composerSurface.placeholder = "Describe a task or ask a question"
        composerSurface.onChange = { [weak self] _ in
            self?.refreshStartButton()
            self?.needsPresentation = true
        }
        composerSurface.onSubmissionAvailabilityChange = { [weak self] _ in
            self?.refreshStartButton()
            self?.needsPresentation = true
        }
        composerSurface.onContentHeightChange = { [weak self] _ in
            self?.needsPresentation = true
        }
        composerSurface.onSubmit = { [weak self] _ in
            guard let self, self.composerStartButton.isEnabled else { return }
            onSubmit()
        }
        composerSurface.setFooterControls(leading: [modelChip, permissionChip, speedChip],
                                          trailing: [surfaceChip])
        for (chip, priority) in [
            (modelChip, 239), (permissionChip, 263),
            (speedChip, 261), (surfaceChip, 260)
        ] {
            chip.setContentCompressionResistancePriority(.init(Float(priority)), for: .horizontal)
        }
        composerBottom = PromptChrome.mountOpeningColumn(composerColumn, in: composerRoot,
            prompt: composerSurface, actionRow: actionRow)
        composerRoot.addSubview(choiceSurface)
        NSLayoutConstraint.activate([
            destinationRow.widthAnchor.constraint(equalTo: composerColumn.widthAnchor),
            composerStartButton.trailingAnchor.constraint(equalTo: actionRow.trailingAnchor),
            composerStartButton.topAnchor.constraint(equalTo: actionRow.topAnchor),
            composerStartButton.bottomAnchor.constraint(equalTo: actionRow.bottomAnchor),
            composerStartButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: actionRow.leadingAnchor),
            composerHero.topAnchor.constraint(equalTo: composerRoot.topAnchor),
            composerHero.bottomAnchor.constraint(equalTo: composerColumn.topAnchor),
            composerHero.leadingAnchor.constraint(equalTo: composerRoot.leadingAnchor),
            composerHero.trailingAnchor.constraint(equalTo: composerRoot.trailingAnchor)
        ])
        choiceSurface.isHidden = true
        projectChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.project, didDismiss: didDismiss)
        }
        providerChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.identity, didDismiss: didDismiss)
        }
        modelChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.model, didDismiss: didDismiss)
        }
        modelChip.configure(symbolName: "cpu", title: selectedModelTitle)
        modelChip.isEnabled = false
        permissionChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.permission, didDismiss: didDismiss)
        }
        permissionChip.configure(symbolName: PermissionModeLabels.symbol, title: selectedPermissionTitle)
        permissionChip.isEnabled = false
        speedChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.speed, didDismiss: didDismiss)
        }
        speedChip.configure(symbolName: "gauge", title: selectedSpeedTitle)
        speedChip.isHidden = true
        surfaceChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.surface, didDismiss: didDismiss)
        }
        surfaceChip.configure(symbolName: "bubble.left.and.text.bubble.right", title: "Native (Experimental)")
        surfaceChip.isHidden = true
        projectChip.configure(symbolName: "folder", title: "Project")
        providerChip.configure(symbolName: "terminal", title: "Choose an agent…")
        composerStartButton.title = "Start Session"
        composerStartButton.isProminent = true
        composerStartButton.shortcut = KeyboardShortcut(key: "\r", modifiers: .command)
        composerStartButton.setAccessibilityIdentifier("composer.session-start.submit")
        composerStartButton.action = { [weak self] in
            guard let self, self.showsComposer, self.composerIdentity != nil,
                  self.composerStartButton.isEnabled else { return }
            onSubmit()
        }
        composerStartButton.isEnabled = false
        projectChip.nextKeyView = providerChip
        providerChip.nextKeyView = composerSurface.linuxEditor
        composerSurface.linuxEditor.nextKeyView = modelChip
        modelChip.nextKeyView = permissionChip
        permissionChip.nextKeyView = speedChip
        speedChip.nextKeyView = surfaceChip
        surfaceChip.nextKeyView = composerStartButton
        composerStartButton.nextKeyView = projectChip
        window.initialFirstResponder = composerSurface.linuxEditor
        window.contentView = composerRoot
        setThemeAppearance()
        showComposer(projectName: "Choose a project…", providerName: "Choose an agent…")
        window.makeFirstResponder(nil)
        window.isKeyWindow = false
    }

    func setThemeAppearance() {
        composerRoot.appearance = LinuxTheme.appearance
        choiceSurface.appearance = LinuxTheme.appearance
        refreshComposerSurface()
        if choiceKind != nil { rebuildChoiceRows() }
        needsPresentation = true
    }

    private func refreshComposerSurface() {
        needsPresentation = true
    }

    func showComposer(projectName: String, providerName: String) {
        dismissChoice()
        composerIdentity = UUID().uuidString
        title = ComposerGreeting.message()
        detail = ""
        actionTitle = "Start Session"
        composerHero.configure(greeting: title)
        projectChip.configure(symbolName: "folder", title: projectName)
        providerChip.configure(symbolName: "terminal", title: providerName)
        selectedProjectName = projectName
        selectedLocationTitle = projectName
        selectedProviderName = providerName
        selectedIdentityName = providerName
        composerSurface.clear()
        refreshStartButton()
        window.contentView = composerRoot
        _ = window.makeFirstResponder(composerSurface.linuxEditor)
        needsPresentation = true
    }

    /// Choices are host-owned identities. This pane only presents a bounded visible page.
    func configureComposerChoices(
        projects: [(id: String, name: String)], selectedProjectID: String,
        checkouts: [ComposerCheckoutChoice], selectedCheckoutID: String,
        locationTitle: String, locationDetail: String?,
        identities: [ComposerIdentityChoice], selectedIdentityID: String,
        onProjectChoice: @escaping (String) -> Void,
        onCheckoutChoice: @escaping (String) -> Void,
        onNewWorktree: @escaping () -> Void,
        onIdentityChoice: @escaping (String) -> Void
    ) {
        let destinationChanged = self.selectedProjectID != selectedProjectID
            || self.selectedCheckoutID != selectedCheckoutID
            || self.selectedIdentityID != selectedIdentityID
            || self.checkoutOptions != checkouts
        if destinationChanged { dismissChoice() }
        projectOptions = projects
        checkoutOptions = checkouts
        // Account discovery admits at most 32 per runtime; the current Linux composer has
        // two runtimes. Retain values for 64 choices but mount no more than six row views.
        identityOptions = Array(identities.prefix(64))
        hasLaunchProject = projects.contains { $0.id == selectedProjectID }
        hasLaunchIdentity = identityOptions.contains { $0.id == selectedIdentityID }
        self.selectedProjectID = selectedProjectID
        self.selectedCheckoutID = selectedCheckoutID
        self.selectedIdentityID = selectedIdentityID
        self.onProjectChoice = onProjectChoice
        self.onCheckoutChoice = onCheckoutChoice
        self.onNewWorktree = onNewWorktree
        self.onIdentityChoice = onIdentityChoice
        selectedProjectName = projects.first(where: { $0.id == selectedProjectID })?.name ?? ""
        selectedLocationTitle = selectedProjectName.isEmpty ? "Choose a project…" : locationTitle
        projectChip.configure(symbolName: "folder",
            title: selectedLocationTitle)
        projectChip.toolTip = locationDetail
        if let identity = identityOptions.first(where: { $0.id == selectedIdentityID }) {
            selectedProviderName = identity.providerName
            selectedIdentityName = identity.title
            providerChip.configure(icon: identity.icon, title: identity.title)
        } else {
            selectedProviderName = ""
            selectedIdentityName = ""
            providerChip.configure(symbolName: "terminal", title: "Choose an agent…")
        }
        composerSurface.placeholder = selectedProjectName.isEmpty
            ? "Choose a project first" : "Describe a task or ask a question"
        refreshStartButton()
        projectChip.isEnabled = !projects.isEmpty
        providerChip.isEnabled = !identityOptions.isEmpty
        needsPresentation = true
    }

    func configurePermissionChoices(_ choices: [ComposerPermissionChoice], selectedID: String,
                                    title: String, onChoose: @escaping (String) -> Void) {
        permissionOptions = Array(choices.prefix(7))
        selectedPermissionID = selectedID
        selectedPermissionTitle = title
        onPermissionChoice = onChoose
        permissionChip.configure(symbolName: PermissionModeLabels.symbol, title: title)
        permissionChip.isEnabled = !permissionOptions.isEmpty
        needsPresentation = true
    }

    func configureSurfaceChoice(kind: AgentKind?, usesNativeUI: Bool,
                                onChoose: @escaping (Bool) -> Void) {
        let canSwitch = kind.map { $0.supportsNativeUI && $0.supports(.terminalUI) } ?? false
        let title = usesNativeUI ? "Native (Experimental)" : kind?.originalUITitle ?? ""
        selectedSurfaceID = usesNativeUI ? "native" : "terminal"
        selectedSurfaceTitle = title
        if let kind, canSwitch {
            surfaceOptions = [
                ChoiceOption(id: "terminal", name: kind.originalUITitle, icon: nil),
                ChoiceOption(id: "native", name: "Native (Experimental)", icon: nil)
            ]
        } else { surfaceOptions = [] }
        onSurfaceChoice = onChoose
        surfaceChip.configure(symbolName: "bubble.left.and.text.bubble.right", title: title)
        surfaceChip.isHidden = !canSwitch
        surfaceChip.isEnabled = canSwitch
        if choiceKind == .surface, !canSwitch { dismissChoice() }
        needsPresentation = true
    }

    func configureSpeedChoice(available: Bool, title: String, fastMode: Bool?,
                              onChoose: @escaping (Bool?) -> Void) {
        selectedSpeedID = fastMode.map { $0 ? "fast" : "standard" } ?? "inherit"
        selectedSpeedTitle = title
        onSpeedChoice = onChoose
        speedOptions = available ? [
            ChoiceOption(id: "inherit", name: "Follow Agent Setting", icon: nil,
                         detail: "Uses the speed configured for this agent."),
            ChoiceOption(id: "standard", name: "Standard", icon: nil,
                         detail: "Normal speed and usage"),
            ChoiceOption(id: "fast", name: "Fast", icon: nil,
                         detail: "1.5× speed, increased usage")
        ] : []
        speedChip.configure(symbolName: title == "Fast" ? "bolt.fill" : "gauge", title: title)
        speedChip.isHidden = !available
        speedChip.isEnabled = available
        if choiceKind == .speed, !available { dismissChoice() }
        needsPresentation = true
    }

    func configureModelChoices(_ presentation: ModelEffortPickerPresentation?, title: String,
                               selectionValid: Bool, hiddenModelCount: Int,
                               onRefresh: @escaping () -> Void,
                               onHideModel: @escaping (String) -> Void,
                               onShowHiddenModels: @escaping () -> Void,
                               onChoose: @escaping (String?, String?) -> Void) {
        let changed = modelPresentation != presentation || self.hiddenModelCount != hiddenModelCount
        modelPresentation = presentation
        modelSelectionValid = selectionValid
        self.hiddenModelCount = hiddenModelCount
        refreshStartButton()
        selectedModelTitle = title
        onModelChoice = onChoose
        onModelRefresh = onRefresh
        self.onHideModel = onHideModel
        self.onShowHiddenModels = onShowHiddenModels
        modelChip.configure(symbolName: "cpu", title: title)
        modelChip.isEnabled = presentation != nil
        if changed, choiceKind == .model {
            if presentation == nil { dismissChoice() }
            else { installModelContent() }
        }
        needsPresentation = true
    }

    private func installModelContent() {
        guard let presentation = modelPresentation else { return }
        unmountModelContent()
        modelMenuToken = UUID().uuidString
        let matrix = ModelEffortMatrixControl(presentation: presentation,
                                             onHideModel: { [weak self] modelID in
            guard let self else { return }
            self.dismissChoice()
            self.onHideModel?(modelID)
            self.focusEditor()
        }) { [weak self] model, effort in
            guard let self else { return }
            self.dismissChoice()
            self.onModelChoice?(model, effort)
            self.focusEditor()
        }
        let showHidden: ThemedButton? = if hiddenModelCount > 0 {
            ThemedButton()
        } else { nil }
        modelShowHiddenButton = showHidden
        if let showHidden {
            showHidden.title = L10n.format("Show hidden models (%d)", hiddenModelCount)
            showHidden.emphasis = .tertiary
            showHidden.contentAlignment = .leading
            showHidden.setAccessibilityIdentifier("model-effort.show-hidden-models")
            showHidden.action = { [weak self] in
                guard let self else { return }
                self.dismissChoice()
                self.onShowHiddenModels?()
                self.focusEditor()
            }
        }
        let content = ModelEffortPickerContentView(matrixView: matrix, footer: showHidden)
        content.translatesAutoresizingMaskIntoConstraints = false
        modelContent = content
        choiceSurface.addSubview(content)
        modelContentConstraints = [
            content.leadingAnchor.constraint(equalTo: choiceSurface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: choiceSurface.trailingAnchor),
            content.topAnchor.constraint(equalTo: choiceSurface.topAnchor),
            content.bottomAnchor.constraint(equalTo: choiceSurface.bottomAnchor)
        ]
        NSLayoutConstraint.activate(modelContentConstraints)
        layoutChoiceSurface(in: composerRoot.bounds.size)
        window.layoutIfNeeded()
        _ = window.makeFirstResponder(matrix)
        matrix.revealFocusedChoice()
        needsPresentation = true
    }

    private func unmountModelContent() {
        NSLayoutConstraint.deactivate(modelContentConstraints)
        modelContentConstraints.removeAll()
        modelContent?.removeFromSuperview()
        modelContent = nil
    }

    private func chip(for kind: ChoiceKind) -> ChipView {
        switch kind {
        case .project: projectChip
        case .identity: providerChip
        case .permission: permissionChip
        case .model: modelChip
        case .surface: surfaceChip
        case .speed: speedChip
        }
    }

    private func selectedID(for kind: ChoiceKind) -> String {
        switch kind {
        case .project: showingProjectNavigation ? selectedProjectID : selectedCheckoutID
        case .identity: selectedIdentityID
        case .permission: selectedPermissionID
        case .model: modelPresentation?.selectedModelID ?? ""
        case .surface: selectedSurfaceID
        case .speed: selectedSpeedID
        }
    }

    var hasOpenComposerChoice: Bool { choiceKind != nil }

    @discardableResult
    func pressComposerChoice(kind: Int, identity: String) -> Bool {
        guard showsComposer, identity == composerIdentity else { return false }
        guard let requested = ChoiceKind(rawValue: kind) else { return false }
        if requested == choiceKind {
            dismissChoice()
            return true
        }
        let chip = chip(for: requested)
        let pressed = chip.accessibilityPerformPress()
        needsPresentation = true
        return pressed
    }

    @discardableResult
    func chooseComposerChoice(kind: Int, index: Int, id: String, identity: String) -> Bool {
        if choiceKind == .model, kind == ChoiceKind.model.rawValue,
           showsComposer, identity == composerIdentity, id == "\(modelMenuToken):\(index)" {
            let chosen = index == -1
                ? modelShowHiddenButton?.accessibilityPerformPress() ?? false
                : modelContent?.matrixView.chooseVisibleChoice(at: index) ?? false
            needsPresentation = true
            return chosen
        }
        guard showsComposer, identity == composerIdentity,
              choiceKind?.rawValue == kind,
              index >= choiceFirst, index < choiceFirst + choiceRows.count,
              choiceOptions.indices.contains(index), choiceOptions[index].id == id
        else { return false }
        chooseChoice(index)
        return true
    }

    /// Called before ordinary composer key routing while a choice is open.
    func handleComposerChoiceKey(_ event: NSEvent) -> Bool {
        guard choiceKind != nil else { return false }
        if choiceKind == .model {
            if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
                dismissChoice()
            } else if event.keyCode == 48 {
                if let footer = modelShowHiddenButton {
                    if window.firstResponder === footer {
                        if event.modifierFlags.contains(.shift) {
                            _ = window.makeFirstResponder(modelContent?.matrixView)
                        } else {
                            dismissChoice()
                            advanceFocus(backward: false)
                        }
                    } else if !event.modifierFlags.contains(.shift) {
                        _ = window.makeFirstResponder(footer)
                    } else {
                        dismissChoice()
                        advanceFocus(backward: true)
                    }
                } else {
                    dismissChoice()
                    advanceFocus(backward: event.modifierFlags.contains(.shift))
                }
            } else if let footer = modelShowHiddenButton, window.firstResponder === footer {
                if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
                    _ = footer.accessibilityPerformPress()
                } else if event.keyCode == 126 {
                    _ = window.makeFirstResponder(modelContent?.matrixView)
                }
            } else {
                modelContent?.matrixView.keyDown(with: event)
            }
            needsPresentation = true
            return true
        }
        switch event.keyCode {
        case 53: dismissChoice(); return true // Escape
        case 126: moveChoice(by: -1); return true
        case 125: moveChoice(by: 1); return true
        case 115: highlightChoice(0); return true // Home
        case 119: highlightChoice(choiceOptions.count - 1); return true // End
        case 116: moveChoice(by: -max(1, choiceRows.count)); return true
        case 121: moveChoice(by: max(1, choiceRows.count)); return true
        case 36, 76: chooseHighlighted(); return true
        default: break
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters == "\u{1b}" {
            dismissChoice()
            return true
        }
        let isTextKey = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if isTextKey, let letter = characters.first, letter.isLetter,
           let next = choiceOptions.indices.first(where: {
               $0 > choiceSelected && choiceOptions[$0].name.lowercased().hasPrefix(String(letter).lowercased())
           }) ?? choiceOptions.indices.first(where: {
               choiceOptions[$0].name.lowercased().hasPrefix(String(letter).lowercased())
           }) {
            highlightChoice(next)
            return true
        }
        dismissChoice()
        return false
    }

    private func openChoice(_ kind: ChoiceKind,
                            didDismiss: @escaping () -> Void) -> ChipChoicePresentationSession? {
        if kind == .model {
            guard showsComposer, modelPresentation != nil else { return nil }
            dismissChoice()
            choiceKind = .model
            let session = ComposerChipChoiceSession(didDismiss: didDismiss)
            choiceSession = session
            choiceSurface.isHidden = false
            installModelContent()
            onModelRefresh?()
            return session
        }
        let options: [ChoiceOption]
        switch kind {
        case .project:
            showingProjectNavigation = false
            options = locationOptions()
        case .identity:
            options = identityOptions.map { ChoiceOption(id: $0.id, name: $0.title, icon: $0.icon) }
        case .permission:
            options = permissionOptions.map {
                ChoiceOption(id: $0.id, name: $0.title, icon: nil, detail: $0.detail)
            }
        case .model: return nil
        case .surface: options = surfaceOptions
        case .speed: options = speedOptions
        }
        guard showsComposer, !options.isEmpty else { return nil }
        dismissChoice()
        choiceKind = kind
        choiceOptions = options
        let selectedID = selectedID(for: kind)
        choiceSelected = options.firstIndex(where: { $0.id == selectedID }) ?? 0
        choiceFirst = 0
        choiceScrollRemainder = 0
        let entries = options.map { ThemedMenuEntry.item(ThemedMenuItem(title: $0.name, subtitle: $0.detail)) }
        choiceRowHeight = ThemedMenuMetrics.heights(for: entries).max() ?? 26
        choiceWidth = kind == .project || kind == .permission || kind == .surface || kind == .speed
            ? ThemedMenuMetrics.width(for: entries, minimum: 180, selectedEntryIndex: choiceSelected)
            : 180
        let session = ComposerChipChoiceSession(didDismiss: didDismiss)
        choiceSession = session
        layoutChoiceSurface(in: composerRoot.bounds.size)
        rebuildChoiceRows()
        choiceSurface.isHidden = false
        needsPresentation = true
        return session
    }

    private func dismissChoice() {
        guard let previousKind = choiceKind else { return }
        choiceKind = nil
        showingProjectNavigation = false
        unmountModelContent()
        modelShowHiddenButton = nil
        modelMenuToken = ""
        choiceOptions.removeAll(keepingCapacity: true)
        choiceSurface.setRows([], heights: [])
        choiceRows.removeAll(keepingCapacity: true)
        choiceSurface.isHidden = true
        let session = choiceSession
        choiceSession = nil
        session?.dismissChipChoicePresentation()
        if previousKind == .model { focusEditor() }
        needsPresentation = true
    }

    private func layoutChoiceSurface(in size: NSSize) {
        guard let choiceKind else { return }
        let source = chip(for: choiceKind)
        let sourceFrame = source.convert(source.bounds, to: composerRoot)
        if choiceKind == .model, let content = modelContent {
            let natural = content.intrinsicContentSize
            choiceSurface.frame = ThemedMenuLayout.frame(anchor: sourceFrame,
                desiredSize: natural, in: composerRoot.bounds,
                flipped: composerRoot.isFlipped)
            return
        }
        let width = min(max(choiceWidth, sourceFrame.width + 28), max(1, size.width - 48))
        let rowHeight = choiceRowHeight
        let outerInset = ThemedMenuMetrics.verticalOuterInset * 2
        let placement = ThemedMenuLayout.frame(anchor: sourceFrame,
            desiredSize: NSSize(width: width,
                height: CGFloat(choiceOptions.count) * rowHeight + outerInset),
            in: composerRoot.bounds, flipped: composerRoot.isFlipped)
        let rowCapacity = max(1, Int((placement.height - outerInset) / rowHeight))
        choiceVisibleCount = min(6, choiceOptions.count, rowCapacity)
        choiceSurface.frame = ThemedMenuLayout.frame(anchor: sourceFrame,
            desiredSize: NSSize(width: width,
                height: CGFloat(choiceVisibleCount) * rowHeight + outerInset),
            in: composerRoot.bounds, flipped: composerRoot.isFlipped)
    }

    private func rebuildChoiceRows() {
        guard let choiceKind, choiceKind != .model, choiceVisibleCount > 0 else { return }
        choiceFirst = min(max(0, choiceFirst), max(0, choiceOptions.count - choiceVisibleCount))
        if choiceSelected < choiceFirst { choiceFirst = choiceSelected }
        if choiceSelected >= choiceFirst + choiceVisibleCount {
            choiceFirst = choiceSelected - choiceVisibleCount + 1
        }
        choiceRows.removeAll(keepingCapacity: true)
        let visible = Array(choiceOptions[choiceFirst..<min(choiceOptions.count,
                                                           choiceFirst + choiceVisibleCount)])
        let selectedID = selectedID(for: choiceKind)
        let entries = visible.map { option in
            ThemedMenuEntry.item(ThemedMenuItem(title: option.name, subtitle: option.detail,
                image: option.icon, representedValue: option.id,
                isSelected: option.id == selectedID))
        }
        let plan = ThemedMenuRowPlan(entries: entries)
        for slot in visible.indices {
            guard let row = plan.row(at: slot) else { continue }
            let index = choiceFirst + slot
            row.onChoose = { [weak self] _, _ in self?.chooseChoice(index) }
            row.onHighlight = { [weak self] _ in self?.highlightChoice(index) }
            choiceRows.append(row)
        }
        choiceSurface.setRows(
            choiceRows, heights: Array(repeating: choiceRowHeight, count: choiceRows.count)
        )
        for (slot, row) in choiceRows.enumerated() {
            row.isKeyboardHighlighted = choiceFirst + slot == choiceSelected
        }
        needsPresentation = true
    }

    private func highlightChoice(_ index: Int) {
        guard choiceOptions.indices.contains(index), choiceSelected != index else { return }
        choiceSelected = index
        if index < choiceFirst || index >= choiceFirst + choiceRows.count {
            rebuildChoiceRows()
        } else {
            for (slot, row) in choiceRows.enumerated() {
                row.isKeyboardHighlighted = choiceFirst + slot == index
            }
        }
        needsPresentation = true
    }

    private func moveChoice(by step: Int) {
        guard !choiceOptions.isEmpty else { return }
        highlightChoice(min(choiceOptions.count - 1, max(0, choiceSelected + step)))
    }

    private func chooseHighlighted() { chooseChoice(choiceSelected) }

    private func chooseChoice(_ index: Int) {
        guard let choiceKind, choiceOptions.indices.contains(index) else { return }
        let id = choiceOptions[index].id
        if choiceKind == .project, id == "@switch-project" || id == "@back-to-checkouts" {
            showingProjectNavigation = id == "@switch-project"
            choiceOptions = locationOptions()
            choiceSelected = choiceOptions.firstIndex(where: { $0.id == selectedID(for: .project) }) ?? 0
            choiceFirst = 0
            layoutChoiceSurface(in: composerRoot.bounds.size)
            rebuildChoiceRows()
            return
        }
        let wasNavigating = showingProjectNavigation
        dismissChoice()
        switch choiceKind {
        case .project:
            if id == "@new-worktree" { onNewWorktree?() }
            else if !wasNavigating, !checkoutOptions.isEmpty { onCheckoutChoice?(id) }
            else { onProjectChoice?(id) }
        case .identity: onIdentityChoice?(id)
        case .permission: onPermissionChoice?(id)
        case .model: break
        case .surface: onSurfaceChoice?(id == "native")
        case .speed: onSpeedChoice?(id == "inherit" ? nil : id == "fast")
        }
        focusEditor()
    }

    private func locationOptions() -> [ChoiceOption] {
        if showingProjectNavigation || checkoutOptions.isEmpty {
            let projects = projectOptions.map { ChoiceOption(id: $0.id, name: $0.name, icon: nil) }
            return showingProjectNavigation
                ? [ChoiceOption(id: "@back-to-checkouts", name: "‹ Checkouts", icon: nil)] + projects
                : projects
        }
        let checkouts = checkoutOptions.map {
            ChoiceOption(id: $0.id, name: $0.title, icon: nil, detail: $0.detail)
        }
        return checkouts + [
            ChoiceOption(id: "@new-worktree", name: "New Worktree…", icon: nil),
            ChoiceOption(id: "@switch-project", name: "Switch Project…", icon: nil)
        ]
    }

    var isComposing: Bool { showsComposer }
    var editorHasFocus: Bool { showsComposer && window.firstResponder === composerSurface.linuxEditor }
    var composedPrompt: String { composerSurface.submissionValue }

    @discardableResult
    func removeAttachment(id: String) -> Bool { composerSurface.removeLinuxAttachment(id: id) }

    func pasteClipboard(wakeIdentity: UInt64) {
        guard editorHasFocus else { return }
        ComposerClipboardPaste.paste(into: composerSurface)
    }

    func drainAttachments() {}

    func acceptFileDrop(_ path: String, windowX: Int, windowY: Int,
                        originX: Int, wakeIdentity: UInt64) -> Bool {
        let point = NSPoint(x: CGFloat(windowX - originX) / WorkspaceDisplay.scale,
            y: root.bounds.height - CGFloat(windowY) / WorkspaceDisplay.scale)
        guard composerSurface.convert(composerSurface.bounds, to: root).contains(point)
        else { return false }
        composerSurface.acceptDroppedPaths([path])
        return true
    }

    func focusEditor() {
        guard showsComposer else { return }
        _ = window.makeFirstResponder(composerSurface.linuxEditor)
        needsPresentation = true
    }

    func advanceFocus(backward: Bool) {
        guard showsComposer else { return }
        if backward { window.selectPreviousKeyView(nil) }
        else { window.selectNextKeyView(nil) }
        needsPresentation = true
    }

    func selectAllText() {
        guard showsComposer else { return }
        let length = (composerSurface.linuxEditor.string as NSString).length
        composerSurface.linuxEditor.setSelectedRange(NSRange(location: 0, length: length))
        needsPresentation = true
    }

    var selectedText: String? {
        guard showsComposer else { return nil }
        let range = composerSurface.linuxEditor.selectedRange()
        guard range.length > 0 else { return nil }
        return (composerSurface.linuxEditor.string as NSString).substring(with: range)
    }

    func deleteSelection() {
        guard showsComposer else { return }
        composerSurface.linuxEditor.insertText("",
            replacementRange: composerSurface.linuxEditor.selectedRange())
        refreshStartButton()
        needsPresentation = true
    }

    func insertCommittedText(_ text: String) {
        guard showsComposer else { return }
        composerSurface.linuxEditor.insertText(text,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        refreshStartButton()
        needsPresentation = true
    }

    /// Apply a bounded AT-SPI edit to the same TextKit view that handles keyboard input.
    /// AT-SPI offsets count Unicode scalars; TextKit replacement ranges count UTF-16 units.
    @discardableResult
    func applyAccessibilityEdit(operation: Int32, start: Int32, end: Int32,
                                text: String) -> Bool {
        guard showsComposer, let range = textRange(forScalarStart: Int(start),
                                                   end: Int(end)) else { return false }
        let view = composerSurface.linuxEditor
        let source = view.string as NSString
        switch operation {
        case 1:
            let remaining = source.replacingCharacters(in: range, with: text)
            guard remaining.utf8.count <= 65_536 else { return false }
            view.insertText(text, replacementRange: range)
        case 2:
            view.setSelectedRange(range)
        case 3, 4:
            guard range.length > 0 else { return true }
            let bytes = Array(source.substring(with: range).utf8)
            let wrote = bytes.withUnsafeBufferPointer {
                tw_clipboard_write($0.baseAddress, Int32($0.count))
            }
            guard wrote == 0 else { return false }
            if operation == 4 { view.insertText("", replacementRange: range) }
        case 5:
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = bytes.withUnsafeMutableBufferPointer {
                tw_clipboard_read($0.baseAddress, Int32($0.count))
            }
            guard count >= 0,
                  let pasted = String(bytes: bytes.prefix(Int(count)), encoding: .utf8),
                  source.replacingCharacters(in: range, with: pasted).utf8.count <= 65_536
            else { return false }
            view.insertText(pasted, replacementRange: range)
        default: return false
        }
        refreshStartButton()
        needsPresentation = true
        return true
    }

    private func textRange(forScalarStart start: Int, end: Int) -> NSRange? {
        guard start >= 0, end >= start else { return nil }
        let scalars = Array(composerSurface.linuxEditor.string.unicodeScalars)
        guard end <= scalars.count else { return nil }
        let lower = scalars[..<start].reduce(0) { $0 + String($1).utf16.count }
        let upper = scalars[start..<end].reduce(lower) { $0 + String($1).utf16.count }
        return NSRange(location: lower, length: upper - lower)
    }

    func updatePreedit(_ text: String, selectedRange: NSRange) {
        guard showsComposer else { return }
        composerSurface.linuxEditor.setMarkedText(text, selectedRange: selectedRange,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        refreshStartButton()
        needsPresentation = true
    }

    func cancelMarkedText() -> Bool {
        guard showsComposer, composerSurface.linuxEditor.hasMarkedText() else { return false }
        composerSurface.linuxEditor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        refreshStartButton()
        needsPresentation = true
        return true
    }

    func handleComposerKey(_ event: NSEvent) {
        guard showsComposer else { return }
        _ = window.dispatchToContent(event)
        refreshStartButton()
        needsPresentation = true
    }

    func setLaunchBlocked(_ blocked: Bool) {
        guard launchBlocked != blocked else { return }
        launchBlocked = blocked
        refreshStartButton()
        needsPresentation = true
    }

    private func refreshStartButton() {
        let canSubmit = showsComposer && !launchBlocked && hasLaunchProject && hasLaunchIdentity
            && modelSelectionValid && !composerSurface.linuxEditor.hasMarkedText()
            && composerSurface.isSubmissionAvailable
        composerStartButton.isEnabled = canSubmit
        composerStartButton.toolTip = launchBlocked ? "Wait for project selection"
            : !hasLaunchProject ? "Choose a project first"
            : !hasLaunchIdentity ? "Choose an available agent first"
            : !modelSelectionValid ? "Choose an available model and effort"
            : canSubmit ? nil : "Write the brief first."
    }

    func focus(_ focused: Bool) {
        window.isKeyWindow = focused
        if !focused {
            dismissChoice()
            window.makeFirstResponder(nil)
            window.cancelPointerGesture()
        }
        refreshComposerSurface()
        needsPresentation = true
    }

    func handle(_ input: TWEvent) {
        let eventType: NSEvent.EventType
        switch input.action {
        case 1: eventType = .leftMouseDown
        case 2: eventType = .leftMouseDragged
        case 3: eventType = .leftMouseUp
        case 7: eventType = .scrollWheel
        default: eventType = .mouseMoved
        }
        let point = NSPoint(x: CGFloat(input.x) / WorkspaceDisplay.scale,
                            y: root.bounds.height - CGFloat(input.y) / WorkspaceDisplay.scale)
        if input.action == 7, choiceKind == .model, choiceSurface.frame.contains(point) {
            modelContent?.scrollView.scrollWheel(with: NSEvent(type: .scrollWheel,
                locationInWindow: point, scrollingDeltaX: CGFloat(input.scrollingDeltaX),
                scrollingDeltaY: CGFloat(input.scrollingDeltaY)))
            needsPresentation = true
            return
        }
        if input.action == 7, choiceKind != nil, choiceSurface.frame.contains(point) {
            let delta = CGFloat(input.scrollingDeltaY)
            guard delta.isFinite else { return }
            let limit = CGFloat(choiceOptions.count)
            choiceScrollRemainder = min(limit, max(-limit, choiceScrollRemainder - delta))
            let step = Int(choiceScrollRemainder.rounded(.towardZero))
            choiceScrollRemainder -= CGFloat(step)
            if step != 0 { moveChoice(by: step) }
            return
        }
        if input.action == 1, let choiceKind, !choiceSurface.frame.contains(point) {
            let source = chip(for: choiceKind)
            let clickedSource = source.convert(source.bounds, to: composerRoot).contains(point)
            dismissChoice()
            if clickedSource { return }
        }
        _ = window.dispatchToContent(NSEvent(type: eventType, locationInWindow: point,
            scrollingDeltaX: CGFloat(input.scrollingDeltaX),
            scrollingDeltaY: CGFloat(input.scrollingDeltaY)))
        if input.action == 4 { window.cancelPointerGesture() }
        needsPresentation = true
    }

    func cancelHover() {
        window.cancelPointerGesture()
        needsPresentation = true
    }

    @discardableResult
    func pressAction() -> Bool {
        let pressed = actionAnchor.accessibilityPerformPress()
        needsPresentation = true
        return pressed
    }

    func present(nativeWindow: OpaquePointer, width: Int, height: Int,
                 originX: Int) throws {
        let size = NSSize(width: CGFloat(width) / WorkspaceDisplay.scale, height: CGFloat(height) / WorkspaceDisplay.scale)
        _ = tw_workspace_composer_mode(nativeWindow, showsComposer ? 1 : 0)
        let hasImages = !composerSurface.linuxAttachmentTiles.isEmpty
        let attachmentHeight = hasImages
            ? Design.Size.promptAttachmentThumbnail + Design.Spacing.medium : 0
        let attachedMinimumHeight = PromptChrome.openingMinimumHeight + attachmentHeight
            + 2 * Design.Spacing.medium + max(24, Design.Size.choiceHeight)
            + max(26, composerStartButton.intrinsicContentSize.height) + Design.Spacing.pane
        let minimumWindowHeight = hasImages
            ? Int((attachedMinimumHeight * WorkspaceDisplay.scale).rounded(.up)) : 180
        tw_workspace_minimum_height(nativeWindow, Int32(minimumWindowHeight))
        // The Mac prompt keeps an 80-point image rail. Let SDL enforce enough room for that
        // constraint tree before solving this frame, even if a resize event is still pending.
        guard height >= minimumWindowHeight else { needsPresentation = true; return }
        guard needsPresentation || presentedSize != size else { return }
        root.frame = NSRect(origin: .zero, size: size)
        if showsComposer {
            let isShort = size.height < 160
            let bottomInset: CGFloat = isShort ? 8 : Design.Spacing.pane
            let startTitle = isShort ? "Start" : "Start Session"
            if composerStartButton.title != startTitle { composerStartButton.title = startTitle }
            let columnSpacing: CGFloat = isShort ? 4 : Design.Spacing.medium
            if composerColumn.spacing != columnSpacing { composerColumn.spacing = columnSpacing }
            if composerBottom.constant != -bottomInset { composerBottom.constant = -bottomInset }
            window.layoutIfNeeded()
            composerHero.updateVisibility()
            if choiceKind != nil {
                let oldFrame = choiceSurface.frame
                let oldCount = choiceVisibleCount
                layoutChoiceSurface(in: size)
                if oldFrame != choiceSurface.frame || oldCount != choiceVisibleCount {
                    rebuildChoiceRows()
                }
            }
        }
        window.layoutIfNeeded()

        let button = actionAnchor.convert(actionAnchor.bounds, to: root)
        let scale = window.backingScaleFactor
        let buttonX = originX + Int((button.minX * scale).rounded())
        let buttonY = Int(((root.bounds.height - button.maxY) * scale).rounded())
        let buttonWidth = Int((button.width * scale).rounded())
        let buttonHeight = Int((button.height * scale).rounded())

        let bitmap = Bitmap(width: width, height: height,
                            background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_placeholder(nativeWindow, $0.baseAddress,
                                   Int32(width), Int32(height))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        (composerHero.isHidden ? "" : title).withCString { name in
            detail.withCString { explanation in
                actionTitle.withCString { action in
                    tw_accessibility_placeholder(nativeWindow, name, explanation, action,
                        actionAnchor.isEnabled ? 1 : 0,
                        Int32(buttonX), Int32(buttonY), Int32(buttonWidth), Int32(buttonHeight))
                }
            }
        }
        let greeting = composerHero.greetingBounds
        tw_accessibility_placeholder_heading_bounds(nativeWindow,
            Int32(originX + Int((greeting.minX * scale).rounded())),
            Int32(((root.bounds.height - greeting.maxY) * scale).rounded()),
            Int32((greeting.width * scale).rounded()), Int32((greeting.height * scale).rounded()))
        if showsComposer {
            let view = composerSurface.linuxEditor
            let value = view.string
            let byteCount = value.utf8.prefix(65_537).count
            let frame = composerSurface.linuxEditorScrollView.convert(composerSurface.linuxEditorScrollView.bounds, to: root)
            let editorX = originX + Int((frame.minX * scale).rounded())
            let editorY = Int(((root.bounds.height - frame.maxY) * scale).rounded())
            if editorHasFocus {
                let caret = view.convert(view.insertionPointRect, to: root)
                tw_text_input_rect(nativeWindow,
                    Int32(originX + Int((caret.minX * scale).rounded())),
                    Int32((root.bounds.height - caret.maxY) * scale),
                    Int32(max(1, (caret.width * scale).rounded())),
                    Int32(max(1, (caret.height * scale).rounded())))
            }
            if byteCount <= 65_536, let identity = composerIdentity {
                let source = value as NSString
                let selection = view.selectedRange()
                let start = source.substring(to: selection.location).unicodeScalars.count
                let end = source.substring(to: NSMaxRange(selection)).unicodeScalars.count
                identity.withCString { editorID in
                    value.withCString { text in
                        tw_accessibility_composer_editor(nativeWindow, editorID, text,
                            Int32(byteCount), Int32(start), Int32(end), editorHasFocus ? 1 : 0,
                            Int32(editorX), Int32(editorY),
                            Int32((frame.width * scale).rounded()),
                            Int32((frame.height * scale).rounded()))
                    }
                }
            } else {
                tw_accessibility_composer_editor(nativeWindow, nil, nil, 0, 0, 0, 0, 0, 0, 0, 0)
            }
        } else {
            tw_accessibility_composer_editor(nativeWindow, nil, nil, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        publishComposerChoiceAccessibility(nativeWindow: nativeWindow, originX: originX,
                                           scale: scale)
        ComposerAttachmentAccessibility.publish(window: nativeWindow, prompt: composerSurface,
            owner: showsComposer ? composerIdentity : nil, scope: 1, root: root,
            originX: originX)
        if showsComposer, let identity = composerIdentity {
            let focused: Int32
            if window.firstResponder === projectChip { focused = 1 }
            else if window.firstResponder === providerChip { focused = 2 }
            else if window.firstResponder === composerSurface.linuxEditor { focused = 3 }
            else if window.firstResponder === composerStartButton { focused = 4 }
            else if window.firstResponder === permissionChip { focused = 5 }
            else if window.firstResponder === modelChip { focused = 6 }
            else if window.firstResponder === surfaceChip { focused = 7 }
            else if window.firstResponder === speedChip { focused = 8 }
            else { focused = 0 }
            identity.withCString { tw_accessibility_composer_focus(nativeWindow, $0, focused) }
        }
        presentedSize = size
        needsPresentation = false
        print("IDLE_PANE_FRAME \(width)x\(height) action=\(actionTitle)")
        fflush(nil)
    }

    private func publishComposerChoiceAccessibility(nativeWindow: OpaquePointer,
                                                     originX: Int, scale: CGFloat) {
        guard showsComposer, let identity = composerIdentity else {
            tw_accessibility_composer_chip(nativeWindow, nil, 1, nil, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_chip(nativeWindow, nil, 2, nil, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_chip(nativeWindow, nil, 3, nil, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_chip(nativeWindow, nil, 4, nil, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_chip(nativeWindow, nil, 5, nil, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_chip(nativeWindow, nil, 6, nil, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_menu_begin(nativeWindow, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_menu_end(nativeWindow)
            return
        }

        func pixels(_ view: NSView) -> (x: Int32, y: Int32, width: Int32, height: Int32) {
            let frame = view.convert(view.bounds, to: root)
            return (
                Int32(originX + Int((frame.minX * scale).rounded())),
                Int32((root.bounds.height - frame.maxY) * scale),
                Int32((frame.width * scale).rounded()),
                Int32((frame.height * scale).rounded())
            )
        }

        for (kind, chip, value) in [(1, projectChip, selectedLocationTitle),
                                    (2, providerChip, selectedIdentityName),
                                    (3, permissionChip, selectedPermissionTitle),
                                    (4, modelChip, String(selectedModelTitle.prefix(100))),
                                    (5, surfaceChip, selectedSurfaceTitle),
                                    (6, speedChip, selectedSpeedTitle)] {
            if chip.isHidden {
                tw_accessibility_composer_chip(nativeWindow, nil, Int32(kind), nil, nil, 0, 0, 0, 0, 0)
                continue
            }
            let frame = pixels(chip)
            let label = kind == 1 ? "Project" : kind == 2 ? "Identity"
                : kind == 3 ? "Permissions" : kind == 4 ? "Model and effort"
                : kind == 5 ? "Interface" : "Speed"
            identity.withCString { token in
                label.withCString { name in
                    value.withCString { selected in
                        tw_accessibility_composer_chip(nativeWindow, token, Int32(kind), name,
                            selected, chip.isEnabled ? 1 : 0, frame.x, frame.y, frame.width, frame.height)
                    }
                }
            }
        }

        guard let choiceKind else {
            tw_accessibility_composer_menu_begin(nativeWindow, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_menu_end(nativeWindow)
            return
        }
        let kind = Int32(choiceKind.rawValue)
        let frame = pixels(choiceSurface)
        identity.withCString { token in
            tw_accessibility_composer_menu_begin(nativeWindow, token, kind, frame.x, frame.y,
                                                 frame.width, frame.height)
        }
        if choiceKind == .model, let content = modelContent {
            let matrix = content.matrixView
            let footer = modelShowHiddenButton
            let footerFocused = footer != nil && window.firstResponder === footer
            for cell in matrix.visibleChoices().prefix(footer == nil ? 128 : 127) {
                let rect = matrix.convert(cell.frame, to: root)
                let cellID = "\(modelMenuToken):\(cell.index)"
                cellID.withCString { id in
                    String(cell.name.prefix(100)).withCString { name in
                        String(cell.detail.prefix(100)).withCString { detail in
                            _ = tw_accessibility_composer_menu_add_row(nativeWindow, Int32(cell.index),
                                id, name, detail, cell.selected ? 1 : 0, cell.enabled ? 1 : 0,
                                cell.focused && !footerFocused ? 1 : 0,
                                Int32(originX) + Int32((rect.minX * scale).rounded()),
                                Int32(((root.bounds.height - rect.maxY) * scale).rounded()),
                                Int32((rect.width * scale).rounded()), Int32((rect.height * scale).rounded()))
                        }
                    }
                }
            }
            if let footer {
                let frame = pixels(footer)
                let footerID = "\(modelMenuToken):-1"
                footerID.withCString { id in
                    footer.title.withCString { title in
                        _ = tw_accessibility_composer_menu_add_row(nativeWindow, -1, id,
                            title, "", 0, footer.isEnabled ? 1 : 0,
                            footerFocused ? 1 : 0,
                            frame.x, frame.y, frame.width, frame.height)
                    }
                }
            }
            tw_accessibility_composer_menu_end(nativeWindow)
            return
        }
        for (slot, row) in choiceRows.enumerated() {
            let index = choiceFirst + slot
            guard choiceOptions.indices.contains(index) else { continue }
            let option = choiceOptions[index]
            let bounds = pixels(row)
            option.id.withCString { id in
                option.name.withCString { name in
                    (option.detail ?? "").withCString { detail in
                        _ = tw_accessibility_composer_menu_add_row(nativeWindow, Int32(index), id,
                            name, detail, index == choiceSelected ? 1 : 0, 1,
                            index == choiceSelected ? 1 : 0, bounds.x, bounds.y, bounds.width, bounds.height)
                    }
                }
            }
        }
        tw_accessibility_composer_menu_end(nativeWindow)
    }
}
#endif
