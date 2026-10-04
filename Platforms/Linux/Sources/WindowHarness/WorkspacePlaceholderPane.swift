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

/// The idle workspace's bounded production content view. It keeps one view tree and texture
/// while project rows change, and repaints only for resize or interaction.
@MainActor
final class WorkspacePlaceholderPane {
    private(set) var title = ""
    private(set) var detail = ""
    private(set) var actionTitle = ""

    private let window = NSWindow(backingScaleFactor: 2)
    private let placeholderRoot = SessionPlaceholderView(frame: .zero)
    private let composerRoot = NSView(frame: .zero)
    private let composerHero = SessionPlaceholderView(frame: .zero)
    private let composerEditor = PromptTextView.scrollingPrompt()
    private lazy var projectChip = ChipView()
    private lazy var providerChip = ChipView()
    private let choiceSurface = SessionMenuSurface(frame: .zero)
    private enum ChoiceKind { case project, provider }
    private var choiceKind: ChoiceKind?
    private var choiceSession: ComposerChipChoiceSession?
    private var choiceRows: [ThemedMenuRowView] = []
    private var choiceFirst = 0
    private var choiceSelected = 0
    private var choiceVisibleCount = 0
    private var choiceOptions: [(id: String, name: String)] = []
    private var projectOptions: [(id: String, name: String)] = []
    private var providerOptions: [(id: String, name: String)] = []
    private var selectedProjectID = ""
    private var selectedProviderID = ""
    private var selectedProjectName = ""
    private var selectedProviderName = ""
    private var onProjectChoice: ((String) -> Void)?
    private var onProviderChoice: ((String) -> Void)?
    private var showsComposer = false
    private(set) var composerIdentity: String?
    private var root: NSView { showsComposer ? composerRoot : placeholderRoot }
    private var actionAnchor: ThemedButton {
        showsComposer ? composerHero.actionAnchor : placeholderRoot.actionAnchor
    }
    private var presentedSize = NSSize.zero
    private var needsPresentation = true

    init(hasProjects: Bool, onAction: @escaping () -> Void,
         onSubmit: @escaping () -> Void) {
        NSImage.systemSymbolProvider = { name, _ in
            Design.Symbol.image(name, slot: PlaceholderDefaults.iconSize,
                                pointSize: 36, weight: .regular)
        }
        placeholderRoot.onAction = onAction
        composerHero.onAction = onAction
        composerRoot.addSubview(composerHero)
        composerRoot.addSubview(composerEditor)
        composerRoot.addSubview(projectChip)
        composerRoot.addSubview(providerChip)
        composerRoot.addSubview(choiceSurface)
        choiceSurface.isHidden = true
        projectChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.project, didDismiss: didDismiss)
        }
        providerChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openChoice(.provider, didDismiss: didDismiss)
        }
        projectChip.configure(symbolName: "folder", title: "Project")
        providerChip.configure(symbolName: "terminal", title: "Agent")
        composerEditor.textView.placeholder = "Describe a task or ask a question"
        composerEditor.textView.submitsOnReturn = { false }
        composerEditor.textView.onSubmit = { _ in onSubmit() }
        composerEditor.textView.drawsBackground = true
        composerEditor.textView.backgroundColor = LinuxTheme.color("fieldSurface")
        composerEditor.textView.textContainerInset = NSSize(width: 10, height: 8)
        window.contentView = placeholderRoot
        setThemeAppearance()
        configure(hasProjects: hasProjects)
    }

    func setThemeAppearance() {
        placeholderRoot.appearance = LinuxTheme.appearance
        composerRoot.appearance = LinuxTheme.appearance
        choiceSurface.appearance = LinuxTheme.appearance
        if choiceKind != nil { rebuildChoiceRows() }
        needsPresentation = true
    }

    func configure(hasProjects: Bool) {
        dismissChoice()
        showsComposer = false
        composerIdentity = nil
        window.contentView = placeholderRoot
        title = hasProjects ? "No Session Selected" : "No Projects Yet"
        detail = hasProjects ? "Select a session in the sidebar, or start one here."
                             : "Add a project folder to start a session."
        actionTitle = hasProjects ? "New Session" : "Add Project"
        placeholderRoot.configure(symbolName: "terminal", title: title, detail: detail,
                       actionTitle: actionTitle)
        needsPresentation = true
    }

    func showComposer(projectName: String, providerName: String) {
        dismissChoice()
        showsComposer = true
        composerIdentity = UUID().uuidString
        title = "Start a \(providerName) session"
        detail = "In \(projectName). Write a brief below."
        actionTitle = "Start Session"
        composerHero.configure(symbolName: "terminal", title: title, detail: detail,
                               actionTitle: actionTitle)
        projectChip.configure(symbolName: "folder", title: projectName)
        providerChip.configure(symbolName: "terminal", title: providerName)
        selectedProjectName = projectName
        selectedProviderName = providerName
        composerEditor.textView.string = ""
        window.contentView = composerRoot
        _ = window.makeFirstResponder(composerEditor.textView)
        needsPresentation = true
    }

    /// Choices are host-owned identities. This pane only presents a bounded visible page.
    func configureComposerChoices(
        projects: [(id: String, name: String)], selectedProjectID: String,
        providers: [(id: String, name: String)], selectedProviderID: String,
        onProjectChoice: @escaping (String) -> Void,
        onProviderChoice: @escaping (String) -> Void
    ) {
        projectOptions = projects
        providerOptions = providers
        self.selectedProjectID = selectedProjectID
        self.selectedProviderID = selectedProviderID
        self.onProjectChoice = onProjectChoice
        self.onProviderChoice = onProviderChoice
        if let project = projects.first(where: { $0.id == selectedProjectID }) {
            selectedProjectName = project.name
            projectChip.configure(symbolName: "folder", title: project.name)
        }
        if let provider = providers.first(where: { $0.id == selectedProviderID }) {
            selectedProviderName = provider.name
            providerChip.configure(symbolName: "terminal", title: provider.name)
        }
        if showsComposer, !selectedProjectName.isEmpty, !selectedProviderName.isEmpty {
            title = "Start a \(selectedProviderName) session"
            detail = "In \(selectedProjectName). Write a brief below."
            composerHero.configure(symbolName: "terminal", title: title, detail: detail,
                                   actionTitle: actionTitle)
        }
        projectChip.isEnabled = !projects.isEmpty
        providerChip.isEnabled = !providers.isEmpty
        if choiceKind != nil { dismissChoice() }
        needsPresentation = true
    }

    var hasOpenComposerChoice: Bool { choiceKind != nil }

    @discardableResult
    func pressComposerChoice(kind: Int, identity: String) -> Bool {
        guard showsComposer, identity == composerIdentity else { return false }
        if kind == 1 && choiceKind == .project || kind == 2 && choiceKind == .provider {
            dismissChoice()
            return true
        }
        let chip: ChipView
        switch kind {
        case 1: chip = projectChip
        case 2: chip = providerChip
        default: return false
        }
        let pressed = chip.accessibilityPerformPress()
        needsPresentation = true
        return pressed
    }

    @discardableResult
    func chooseComposerChoice(kind: Int, index: Int, id: String, identity: String) -> Bool {
        guard showsComposer, identity == composerIdentity,
              (kind == 1 && choiceKind == .project || kind == 2 && choiceKind == .provider),
              index >= choiceFirst, index < choiceFirst + choiceRows.count,
              choiceOptions.indices.contains(index), choiceOptions[index].id == id
        else { return false }
        chooseChoice(index)
        return true
    }

    /// Called before ordinary composer key routing while a choice is open.
    func handleComposerChoiceKey(_ event: NSEvent) -> Bool {
        guard choiceKind != nil else { return false }
        switch event.keyCode {
        case 53: dismissChoice(); return true // Escape
        case 126: moveChoice(by: -1); return true
        case 125: moveChoice(by: 1); return true
        case 36, 76: chooseHighlighted(); return true
        default: break
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters == "\u{1b}" {
            dismissChoice()
            return true
        }
        if let letter = characters.first, letter.isLetter,
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
        let options = kind == .project ? projectOptions : providerOptions
        guard showsComposer, !options.isEmpty else { return nil }
        dismissChoice()
        choiceKind = kind
        choiceOptions = options
        let selectedID = kind == .project ? selectedProjectID : selectedProviderID
        choiceSelected = options.firstIndex(where: { $0.id == selectedID }) ?? 0
        choiceFirst = 0
        let session = ComposerChipChoiceSession(didDismiss: didDismiss)
        choiceSession = session
        layoutChoiceSurface(in: composerRoot.bounds.size)
        rebuildChoiceRows()
        choiceSurface.isHidden = false
        needsPresentation = true
        return session
    }

    private func dismissChoice() {
        guard choiceKind != nil else { return }
        choiceKind = nil
        choiceOptions.removeAll(keepingCapacity: true)
        for row in choiceRows { row.removeFromSuperview() }
        choiceRows.removeAll(keepingCapacity: true)
        choiceSurface.isHidden = true
        let session = choiceSession
        choiceSession = nil
        session?.dismissChipChoicePresentation()
        needsPresentation = true
    }

    private func layoutChoiceSurface(in size: NSSize) {
        guard let choiceKind else { return }
        let source = choiceKind == .project ? projectChip : providerChip
        let width = min(max(180, source.frame.width + 28), max(1, size.width - 48))
        let availableAbove = max(0, size.height - source.frame.maxY - 12)
        let rowHeight = max(24, ThemedMenuMetrics.heights(for: [.item(ThemedMenuItem(title: "Sample"))]).first ?? 26)
        let opensAbove = availableAbove >= rowHeight + 12
        let available = opensAbove ? availableAbove : max(0, source.frame.minY - 8)
        choiceVisibleCount = min(6, choiceOptions.count, max(1, Int((available - 12) / rowHeight)))
        let height = CGFloat(choiceVisibleCount) * rowHeight + 12
        let x = min(max(8, source.frame.minX), max(8, size.width - width - 8))
        let y = opensAbove ? source.frame.maxY + 4 : max(4, source.frame.minY - height - 4)
        choiceSurface.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private func rebuildChoiceRows() {
        guard choiceKind != nil, choiceVisibleCount > 0 else { return }
        choiceFirst = min(max(0, choiceFirst), max(0, choiceOptions.count - choiceVisibleCount))
        if choiceSelected < choiceFirst { choiceFirst = choiceSelected }
        if choiceSelected >= choiceFirst + choiceVisibleCount {
            choiceFirst = choiceSelected - choiceVisibleCount + 1
        }
        for row in choiceRows { row.removeFromSuperview() }
        choiceRows.removeAll(keepingCapacity: true)
        let visible = Array(choiceOptions[choiceFirst..<min(choiceOptions.count,
                                                           choiceFirst + choiceVisibleCount)])
        let selectedID = choiceKind == .project ? selectedProjectID : selectedProviderID
        let entries = visible.map { option in
            ThemedMenuEntry.item(ThemedMenuItem(title: option.name,
                representedValue: option.id, isSelected: option.id == selectedID))
        }
        let plan = ThemedMenuRowPlan(entries: entries)
        var top: CGFloat = 6
        for slot in visible.indices {
            guard let row = plan.row(at: slot) else { continue }
            let index = choiceFirst + slot
            let rowHeight = plan.heights[slot]
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
        case .provider: onProviderChoice?(id)
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

    func focusAction() {
        guard showsComposer else { return }
        _ = window.makeFirstResponder(actionAnchor)
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
        needsPresentation = true
    }

    func insertCommittedText(_ text: String) {
        guard showsComposer else { return }
        composerEditor.textView.insertText(text,
            replacementRange: NSRange(location: NSNotFound, length: 0))
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
        needsPresentation = true
    }

    func cancelMarkedText() -> Bool {
        guard showsComposer, composerEditor.textView.hasMarkedText() else { return false }
        composerEditor.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        needsPresentation = true
        return true
    }

    func handleEditorKey(_ event: NSEvent) {
        guard showsComposer else { return }
        _ = window.dispatchToContent(event)
        needsPresentation = true
    }

    func focus(_ focused: Bool) {
        window.isKeyWindow = focused
        if !focused {
            dismissChoice()
            window.makeFirstResponder(nil)
            window.cancelPointerGesture()
        }
        needsPresentation = true
    }

    func handle(_ input: TWEvent) {
        let eventType: NSEvent.EventType
        switch input.action {
        case 1: eventType = .leftMouseDown
        case 2: eventType = .leftMouseDragged
        case 3: eventType = .leftMouseUp
        default: eventType = .mouseMoved
        }
        let point = NSPoint(x: CGFloat(input.x) / 2,
                            y: root.bounds.height - CGFloat(input.y) / 2)
        if input.action == 1, let choiceKind, !choiceSurface.frame.contains(point) {
            let source = choiceKind == .project ? projectChip : providerChip
            let clickedSource = source.frame.contains(point)
            dismissChoice()
            if clickedSource { return }
        }
        _ = window.dispatchToContent(NSEvent(type: eventType, locationInWindow: point))
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
        let size = NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        guard needsPresentation || presentedSize != size else { return }
        root.frame = NSRect(origin: .zero, size: size)
        if showsComposer {
            let horizontalInset: CGFloat = 24
            let bottomInset: CGFloat = 8
            let editorHeight = min(108, max(44, size.height * 0.25))
            let chipHeight = max(24, Design.Size.choiceHeight)
            let chipY = bottomInset + editorHeight + 8
            let heroBottom = chipY + chipHeight + 4
            composerEditor.frame = NSRect(x: horizontalInset, y: bottomInset,
                width: max(1, size.width - horizontalInset * 2), height: editorHeight)
            composerHero.frame = NSRect(x: 0, y: heroBottom,
                width: size.width, height: max(0, size.height - heroBottom))
            let available = max(1, size.width - 2 * horizontalInset)
            let gap: CGFloat = 8
            let projectWidth = min(max(94, projectChip.intrinsicContentSize.width),
                                   max(1, (available - gap) * 0.58))
            let providerWidth = min(max(84, providerChip.intrinsicContentSize.width),
                                    max(1, available - projectWidth - gap))
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
        title.withCString { name in
            detail.withCString { explanation in
                actionTitle.withCString { action in
                    tw_accessibility_placeholder(nativeWindow, name, explanation, action,
                        Int32(buttonX), Int32(buttonY), Int32(buttonWidth), Int32(buttonHeight))
                }
            }
        }
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
        presentedSize = size
        needsPresentation = false
        print("IDLE_PANE_FRAME \(width)x\(height) action=\(actionTitle)")
        fflush(nil)
    }

    private func publishComposerChoiceAccessibility(nativeWindow: OpaquePointer,
                                                     originX: Int, scale: CGFloat) {
        guard showsComposer, let identity = composerIdentity else {
            tw_accessibility_composer_chip(nativeWindow, nil, 1, nil, nil, 0, 0, 0, 0)
            tw_accessibility_composer_chip(nativeWindow, nil, 2, nil, nil, 0, 0, 0, 0)
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
                                    (2, providerChip, selectedProviderName)] {
            let frame = pixels(chip)
            let label = kind == 1 ? "Project" : "Provider"
            identity.withCString { token in
                label.withCString { name in
                    value.withCString { selected in
                        tw_accessibility_composer_chip(nativeWindow, token, Int32(kind), name,
                            selected, frame.x, frame.y, frame.width, frame.height)
                    }
                }
            }
        }

        guard let choiceKind else {
            tw_accessibility_composer_menu_begin(nativeWindow, nil, 0, 0, 0, 0, 0)
            tw_accessibility_composer_menu_end(nativeWindow)
            return
        }
        let kind: Int32 = choiceKind == .project ? 1 : 2
        let frame = pixels(choiceSurface)
        identity.withCString { token in
            tw_accessibility_composer_menu_begin(nativeWindow, token, kind, frame.x, frame.y,
                                                 frame.width, frame.height)
        }
        for (slot, row) in choiceRows.enumerated() {
            let index = choiceFirst + slot
            guard choiceOptions.indices.contains(index) else { continue }
            let option = choiceOptions[index]
            let bounds = pixels(row)
            option.id.withCString { id in
                option.name.withCString { name in
                    _ = tw_accessibility_composer_menu_add_row(nativeWindow, Int32(index), id,
                        name, index == choiceSelected ? 1 : 0, 1,
                        bounds.x, bounds.y, bounds.width, bounds.height)
                }
            }
        }
        tw_accessibility_composer_menu_end(nativeWindow)
    }
}
#endif
