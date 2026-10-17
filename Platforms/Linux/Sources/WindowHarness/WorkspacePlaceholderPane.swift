#if os(Linux)
import AppKit
import Foundation
import Glibc
import LinuxWindowBridge

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
    private let composerSurface = NSView(frame: .zero)
    private let composerEditor = PromptTextView.scrollingPrompt()
    private let composerStartButton = ThemedButton()
    private lazy var projectChip = ChipView()
    private lazy var providerChip = ChipView()
    private let modelChip = ChipView()
    private var modelSelectionValid = true
    private var modelPresentation: ModelEffortPickerPresentation?
    private var modelContent: ModelEffortPickerContentView?
    private var modelMenuToken = ""
    private var selectedModelTitle = "Default model"
    private var onModelChoice: ((String?, String?) -> Void)?
    private var onModelRefresh: (() -> Void)?
    private let permissionChip = ChipView()
    private let choiceSurface = SessionMenuSurface(frame: .zero)
    private enum ChoiceKind: Int { case project = 1, identity = 2, permission = 3, model = 4 }
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
    private var identityOptions: [ComposerIdentityChoice] = []
    private var permissionOptions: [ComposerPermissionChoice] = []
    private var selectedPermissionID = "manual"
    private var selectedPermissionTitle = "Manual"
    private var onPermissionChoice: ((String) -> Void)?
    private var choiceRowHeight: CGFloat = 26
    private var choiceWidth: CGFloat = 180
    private var choiceScrollRemainder: CGFloat = 0
    private var selectedProjectID = ""
    private var selectedIdentityID = ""
    private var selectedProjectName = ""
    private var selectedProviderName = ""
    private var selectedIdentityName = ""
    private var onProjectChoice: ((String) -> Void)?
    private var onIdentityChoice: ((String) -> Void)?
    private let showsComposer = true
    private(set) var composerIdentity: String?
    private var root: NSView { composerRoot }
    private var actionAnchor: ThemedButton { composerStartButton }
    private var hasLaunchProject = false
    private var hasLaunchIdentity = false
    private var launchBlocked = false
    private var composerFocused = false
    private var presentedSize = NSSize.zero
    private var needsPresentation = true

    init(onSubmit: @escaping () -> Void) {
        LinuxSymbols.install()
        composerRoot.addSubview(composerHero)
        composerRoot.addSubview(composerSurface)
        composerSurface.addSubview(composerEditor)
        composerSurface.addSubview(modelChip)
        composerSurface.addSubview(permissionChip)
        composerRoot.addSubview(composerStartButton)
        composerRoot.addSubview(projectChip)
        composerRoot.addSubview(providerChip)
        composerRoot.addSubview(choiceSurface)
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
        projectChip.configure(symbolName: "folder", title: "Project")
        providerChip.configure(symbolName: "terminal", title: "Choose an agent…")
        composerEditor.textView.placeholder = "Describe a task or ask a question"
        composerEditor.textView.submitsOnReturn = { false }
        composerEditor.textView.onSubmit = { [weak self] _ in
            guard let self, self.composerStartButton.isEnabled else { return }
            onSubmit()
        }
        composerEditor.textView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.composerFocused = focused
            self.refreshComposerSurface()
        }
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
        providerChip.nextKeyView = composerEditor.textView
        composerEditor.textView.nextKeyView = modelChip
        modelChip.nextKeyView = permissionChip
        permissionChip.nextKeyView = composerStartButton
        composerStartButton.nextKeyView = projectChip
        window.initialFirstResponder = composerEditor.textView
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
        PromptChrome.applySurface(to: composerSurface, fill: Design.Surface.field,
            emphasized: window.isKeyWindow && composerFocused)
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
        selectedProviderName = providerName
        selectedIdentityName = providerName
        composerEditor.textView.string = ""
        refreshStartButton()
        window.contentView = composerRoot
        _ = window.makeFirstResponder(composerEditor.textView)
        needsPresentation = true
    }

    /// Choices are host-owned identities. This pane only presents a bounded visible page.
    func configureComposerChoices(
        projects: [(id: String, name: String)], selectedProjectID: String,
        identities: [ComposerIdentityChoice], selectedIdentityID: String,
        onProjectChoice: @escaping (String) -> Void,
        onIdentityChoice: @escaping (String) -> Void
    ) {
        let destinationChanged = self.selectedProjectID != selectedProjectID
            || self.selectedIdentityID != selectedIdentityID
        if destinationChanged { dismissChoice() }
        projectOptions = projects
        // Account discovery admits at most 32 per runtime; the current Linux composer has
        // two runtimes. Retain values for 64 choices but mount no more than six row views.
        identityOptions = Array(identities.prefix(64))
        hasLaunchProject = projects.contains { $0.id == selectedProjectID }
        hasLaunchIdentity = identityOptions.contains { $0.id == selectedIdentityID }
        self.selectedProjectID = selectedProjectID
        self.selectedIdentityID = selectedIdentityID
        self.onProjectChoice = onProjectChoice
        self.onIdentityChoice = onIdentityChoice
        selectedProjectName = projects.first(where: { $0.id == selectedProjectID })?.name ?? ""
        projectChip.configure(symbolName: "folder",
            title: selectedProjectName.isEmpty ? "Choose a project…" : selectedProjectName)
        if let identity = identityOptions.first(where: { $0.id == selectedIdentityID }) {
            selectedProviderName = identity.providerName
            selectedIdentityName = identity.title
            providerChip.configure(icon: identity.icon, title: identity.title)
        } else {
            selectedProviderName = ""
            selectedIdentityName = ""
            providerChip.configure(symbolName: "terminal", title: "Choose an agent…")
        }
        composerEditor.textView.placeholder = selectedProjectName.isEmpty
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

    func configureModelChoices(_ presentation: ModelEffortPickerPresentation?, title: String, selectionValid: Bool,
                               onRefresh: @escaping () -> Void,
                               onChoose: @escaping (String?, String?) -> Void) {
        let changed = modelPresentation != presentation
        modelPresentation = presentation
        modelSelectionValid = selectionValid
        refreshStartButton()
        selectedModelTitle = title
        onModelChoice = onChoose
        onModelRefresh = onRefresh
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
        modelContent?.removeFromSuperview()
        modelMenuToken = UUID().uuidString
        let matrix = ModelEffortMatrixControl(presentation: presentation) { [weak self] model, effort in
            guard let self else { return }
            self.dismissChoice()
            self.onModelChoice?(model, effort)
            self.focusEditor()
        }
        let content = ModelEffortPickerContentView(matrixView: matrix)
        modelContent = content
        choiceSurface.addSubview(content)
        layoutChoiceSurface(in: composerRoot.bounds.size)
        window.layoutIfNeeded()
        _ = window.makeFirstResponder(matrix)
        matrix.revealFocusedChoice()
        needsPresentation = true
    }

    private func chip(for kind: ChoiceKind) -> ChipView {
        switch kind {
        case .project: projectChip
        case .identity: providerChip
        case .permission: permissionChip
        case .model: modelChip
        }
    }

    private func selectedID(for kind: ChoiceKind) -> String {
        switch kind {
        case .project: selectedProjectID
        case .identity: selectedIdentityID
        case .permission: selectedPermissionID
        case .model: modelPresentation?.selectedModelID ?? ""
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
            let chosen = modelContent?.matrixView.chooseVisibleChoice(at: index) ?? false
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
                dismissChoice()
                advanceFocus(backward: event.modifierFlags.contains(.shift))
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
            options = projectOptions.map { ChoiceOption(id: $0.id, name: $0.name, icon: nil) }
        case .identity:
            options = identityOptions.map { ChoiceOption(id: $0.id, name: $0.title, icon: $0.icon) }
        case .permission:
            options = permissionOptions.map {
                ChoiceOption(id: $0.id, name: $0.title, icon: nil, detail: $0.detail)
            }
        case .model: return nil
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
        choiceWidth = kind == .permission
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
        modelContent?.removeFromSuperview()
        modelContent = nil
        modelMenuToken = ""
        choiceOptions.removeAll(keepingCapacity: true)
        for row in choiceRows { row.removeFromSuperview() }
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
            let width = min(natural.width, max(1, size.width - 16))
            let above = max(1, size.height - sourceFrame.maxY - 8)
            let below = max(1, sourceFrame.minY - 8)
            let opensAbove = above >= below
            let height = min(natural.height, opensAbove ? above : below)
            let x = min(max(8, sourceFrame.minX), max(8, size.width - width - 8))
            let y = opensAbove ? sourceFrame.maxY + 4 : max(4, sourceFrame.minY - height - 4)
            choiceSurface.frame = NSRect(x: x, y: y, width: width, height: height)
            content.frame = choiceSurface.bounds
            content.layout()
            return
        }
        let width = min(max(choiceWidth, sourceFrame.width + 28), max(1, size.width - 48))
        let availableAbove = max(0, size.height - sourceFrame.maxY - 12)
        let rowHeight = choiceRowHeight
        let opensAbove = availableAbove >= rowHeight + 12
        let available = opensAbove ? availableAbove : max(0, sourceFrame.minY - 8)
        choiceVisibleCount = min(6, choiceOptions.count, max(1, Int((available - 12) / rowHeight)))
        let height = CGFloat(choiceVisibleCount) * rowHeight + 12
        let x = min(max(8, sourceFrame.minX), max(8, size.width - width - 8))
        let y = opensAbove ? sourceFrame.maxY + 4 : max(4, sourceFrame.minY - height - 4)
        choiceSurface.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private func rebuildChoiceRows() {
        guard let choiceKind, choiceKind != .model, choiceVisibleCount > 0 else { return }
        choiceFirst = min(max(0, choiceFirst), max(0, choiceOptions.count - choiceVisibleCount))
        if choiceSelected < choiceFirst { choiceFirst = choiceSelected }
        if choiceSelected >= choiceFirst + choiceVisibleCount {
            choiceFirst = choiceSelected - choiceVisibleCount + 1
        }
        for row in choiceRows { row.removeFromSuperview() }
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
        var top: CGFloat = 6
        for slot in visible.indices {
            guard let row = plan.row(at: slot) else { continue }
            let index = choiceFirst + slot
            let rowHeight = choiceRowHeight
            row.frame = NSRect(x: 6, y: choiceSurface.bounds.height - top - rowHeight,
                               width: max(1, choiceSurface.bounds.width - 12), height: rowHeight)
            row.onChoose = { [weak self] _, _ in self?.chooseChoice(index) }
            row.onHighlight = { [weak self] _ in self?.highlightChoice(index) }
            choiceSurface.addSubview(row)
            choiceRows.append(row)
            top += rowHeight
        }
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
        dismissChoice()
        switch choiceKind {
        case .project: onProjectChoice?(id)
        case .identity: onIdentityChoice?(id)
        case .permission: onPermissionChoice?(id)
        case .model: break
        }
        focusEditor()
    }

    var isComposing: Bool { showsComposer }
    var editorHasFocus: Bool { showsComposer && window.firstResponder === composerEditor.textView }
    var composedPrompt: String { composerEditor.textView.string }

    func focusEditor() {
        guard showsComposer else { return }
        _ = window.makeFirstResponder(composerEditor.textView)
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
        let length = (composerEditor.textView.string as NSString).length
        composerEditor.textView.setSelectedRange(NSRange(location: 0, length: length))
        needsPresentation = true
    }

    var selectedText: String? {
        guard showsComposer else { return nil }
        let range = composerEditor.textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (composerEditor.textView.string as NSString).substring(with: range)
    }

    func deleteSelection() {
        guard showsComposer else { return }
        composerEditor.textView.insertText("",
            replacementRange: composerEditor.textView.selectedRange())
        refreshStartButton()
        needsPresentation = true
    }

    func insertCommittedText(_ text: String) {
        guard showsComposer else { return }
        composerEditor.textView.insertText(text,
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
        let view = composerEditor.textView
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
        let scalars = Array(composerEditor.textView.string.unicodeScalars)
        guard end <= scalars.count else { return nil }
        let lower = scalars[..<start].reduce(0) { $0 + String($1).utf16.count }
        let upper = scalars[start..<end].reduce(lower) { $0 + String($1).utf16.count }
        return NSRange(location: lower, length: upper - lower)
    }

    func updatePreedit(_ text: String, selectedRange: NSRange) {
        guard showsComposer else { return }
        composerEditor.textView.setMarkedText(text, selectedRange: selectedRange,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        refreshStartButton()
        needsPresentation = true
    }

    func cancelMarkedText() -> Bool {
        guard showsComposer, composerEditor.textView.hasMarkedText() else { return false }
        composerEditor.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
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
        let text = composerEditor.textView.string
        let canSubmit = showsComposer && !launchBlocked && hasLaunchProject && hasLaunchIdentity
            && modelSelectionValid && !composerEditor.textView.hasMarkedText()
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        guard needsPresentation || presentedSize != size else { return }
        root.frame = NSRect(origin: .zero, size: size)
        if showsComposer {
            let isShort = size.height < 160
            let contentWidth = min(PromptChrome.openingContentWidth,
                max(1, size.width - Design.Spacing.pane * 2))
            let horizontalInset = (size.width - contentWidth) / 2
            let bottomInset: CGFloat = isShort ? 8 : Design.Spacing.pane
            let startTitle = isShort ? "Start" : "Start Session"
            if composerStartButton.title != startTitle { composerStartButton.title = startTitle }
            let actionGap: CGFloat = isShort ? 4 : Design.Spacing.medium
            let chipGap: CGFloat = isShort ? 4 : Design.Spacing.medium
            let actionHeight = max(26, composerStartButton.intrinsicContentSize.height)
            let chipHeight = max(24, Design.Size.choiceHeight)
            composerEditor.frame.size.width = max(1, contentWidth - Design.Spacing.inset * 2)
            let textHeight = composerEditor.textView.layoutManager.flatMap { manager in
                composerEditor.textView.textContainer.map { manager.usedRect(for: $0).height }
            } ?? 0
            let fitted = PromptChrome.fittedHeight(textHeight: textHeight,
                restingHeight: PromptChrome.openingMinimumHeight, showsFooter: true)
            let availableEditorHeight = max(1, size.height - bottomInset - actionHeight
                - actionGap - chipGap - chipHeight)
            let editorHeight = min(fitted.height, availableEditorHeight)
            let scrolls = fitted.scrolls || editorHeight < fitted.height
            if composerEditor.hasVerticalScroller != scrolls { composerEditor.hasVerticalScroller = scrolls }
            let editorY = bottomInset + actionHeight + actionGap
            let chipY = editorY + editorHeight + chipGap
            let heroBottom = chipY + chipHeight
            let available = contentWidth
            let actionWidth = min(available, max(120, composerStartButton.intrinsicContentSize.width))
            composerStartButton.frame = NSRect(
                x: size.width - horizontalInset - actionWidth, y: bottomInset,
                width: actionWidth, height: actionHeight
            )
            composerSurface.frame = NSRect(x: horizontalInset, y: editorY,
                width: contentWidth, height: editorHeight)
            let frames = PromptChrome.contentFrames(in: composerSurface.bounds)
            composerEditor.frame = frames.editor
            let permissionWidth = min(permissionChip.intrinsicContentSize.width, frames.footer.width * 0.45)
            let modelWidth = min(modelChip.intrinsicContentSize.width,
                max(1, frames.footer.width - permissionWidth - Design.Spacing.small))
            modelChip.frame = NSRect(x: frames.footer.minX, y: frames.footer.minY,
                width: modelWidth, height: frames.footer.height)
            permissionChip.frame = NSRect(x: modelChip.frame.maxX + Design.Spacing.small,
                y: frames.footer.minY, width: permissionWidth, height: frames.footer.height)
            composerHero.place(in: NSRect(x: 0, y: heroBottom,
                width: size.width, height: max(0, size.height - heroBottom)))
            let gap: CGFloat = 8
            let providerWidth = min(max(84, providerChip.intrinsicContentSize.width),
                                    max(1, available - gap - 48))
            let projectWidth = min(max(72, projectChip.intrinsicContentSize.width),
                                   max(1, available - providerWidth - gap))
            projectChip.frame = NSRect(x: horizontalInset, y: chipY,
                                       width: projectWidth, height: chipHeight)
            providerChip.frame = NSRect(x: horizontalInset + projectWidth + gap, y: chipY,
                                        width: providerWidth, height: chipHeight)
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
            let view = composerEditor.textView
            let value = view.string
            let byteCount = value.utf8.prefix(65_537).count
            let frame = composerEditor.convert(composerEditor.bounds, to: root)
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
        if showsComposer, let identity = composerIdentity {
            let focused: Int32
            if window.firstResponder === projectChip { focused = 1 }
            else if window.firstResponder === providerChip { focused = 2 }
            else if window.firstResponder === composerEditor.textView { focused = 3 }
            else if window.firstResponder === composerStartButton { focused = 4 }
            else if window.firstResponder === permissionChip { focused = 5 }
            else if window.firstResponder === modelChip { focused = 6 }
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

        for (kind, chip, value) in [(1, projectChip, selectedProjectName),
                                    (2, providerChip, selectedIdentityName),
                                    (3, permissionChip, selectedPermissionTitle),
                                    (4, modelChip, String(selectedModelTitle.prefix(100)))] {
            let frame = pixels(chip)
            let label = kind == 1 ? "Project" : kind == 2 ? "Identity" : kind == 3 ? "Permissions" : "Model and effort"
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
            for cell in matrix.visibleChoices().prefix(128) {
                let rect = matrix.convert(cell.frame, to: root)
                let cellID = "\(modelMenuToken):\(cell.index)"
                cellID.withCString { id in
                    String(cell.name.prefix(100)).withCString { name in
                        String(cell.detail.prefix(100)).withCString { detail in
                            _ = tw_accessibility_composer_menu_add_row(nativeWindow, Int32(cell.index),
                                id, name, detail, cell.selected ? 1 : 0, cell.enabled ? 1 : 0,
                                cell.focused ? 1 : 0,
                                Int32(originX) + Int32((rect.minX * scale).rounded()),
                                Int32(((root.bounds.height - rect.maxY) * scale).rounded()),
                                Int32((rect.width * scale).rounded()), Int32((rect.height * scale).rounded()))
                        }
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
