#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge
@testable import CoreSlice

/// Native conversation content in the ordinary workspace. The same chrome serves a terminal;
/// transcript cells and prompt controls come from the production Design sources.
@MainActor
final class WorkspaceConversationPane: WorkspacePane {
    let runtime: NativeWorkspaceSession
    let chrome: WorkspacePaneChrome
    private let owner = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
    private let root = NSView(frame: .zero)
    private let scroll = ThemedScrollView()
    private let table = ConversationContentTable.make()
    private let rows = DocumentRowSource()
    private let editor = PromptTextView.scrollingPrompt()
    private let composer = NSView(frame: .zero)
    private let composerContent = NSStackView()
    private let composerFooter = NSStackView()
    private let composerSpacer = NSView(frame: .zero)
    private let submit = ThemedButton()
    private let status: NSTextField
    private var needsPresentation = true
    private var presentedSize = NSSize.zero
    private var displayRevision: UInt64 = 0
    private var followTail = true
    private var focused = false
    private var composerFocused = false
    private var presentedPermission: Int?
    private var permissionCard: PermissionRequestView?
    private var questionCards: [UUID: ConversationQuestionCard] = [:]
    /// Every decision card in arrival order, as the trailing transcript block shows them.
    private var decisionOrder: [NSView] = []
    var title: String { "Threading conversation · \(runtime.status)" }
    var needsPolling: Bool { false }
    func takeInitialViewport() -> (Int, Int)? { nil }

    init(runtime: NativeWorkspaceSession, pageName: String, icon: NSImage?, onReveal: @escaping () -> Void) {
        self.runtime = runtime
        chrome = WorkspacePaneChrome(pageName: pageName, pageIdentity: runtime.id.uuidString,
            symbolName: "text.bubble", icon: icon, showsSessionActions: true, onReveal: onReveal)
        status = ConversationRowView.streaming(runtime.status)
        // These peers are positioned by this bounded host, while each peer's own
        // internal constraints still own its content. Do not feed their intrinsic fits back
        // into the root as unconstrained Auto Layout siblings.
        let positionedViews: [NSView] = [scroll, status, composer]
        for view in positionedViews { view.translatesAutoresizingMaskIntoConstraints = true }
        table.dataSource = rows
        table.delegate = rows
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        editor.textView.placeholder = "Reply to this conversation"
        editor.textView.submitsOnReturn = { true }
        editor.textView.onSubmit = { [weak self] _ in self?.send() }
        editor.textView.onFocusChange = { [weak self] focused in
            self?.composerFocused = focused
            self?.refreshComposerSurface()
        }
        submit.isBordered = false
        submit.setAccessibilityIdentifier("composer.conversation-reply.submit")
        submit.action = { [weak self] in
            guard let self else { return }
            if self.runtime.canInterrupt { self.runtime.interrupt() }
            else { self.send() }
        }
        editor.textView.nextKeyView = submit
        submit.nextKeyView = editor.textView
        root.addSubview(scroll)
        root.addSubview(status)
        root.addSubview(composer)
        PromptChrome.configureFooter(composerFooter, spacer: composerSpacer)
        composerFooter.addArrangedSubview(submit)
        composerContent.orientation = .vertical
        composerContent.alignment = .leading
        composerContent.spacing = Design.Spacing.medium
        composerContent.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        submit.translatesAutoresizingMaskIntoConstraints = false
        composerContent.addArrangedSubview(editor)
        composerContent.addArrangedSubview(composerFooter)
        composer.addSubview(composerContent)
        NSLayoutConstraint.activate([
            composerContent.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: Design.Spacing.inset),
            composerContent.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -Design.Spacing.inset),
            composerContent.topAnchor.constraint(equalTo: composer.topAnchor, constant: PromptChrome.footerVerticalInset),
            composerContent.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -PromptChrome.footerVerticalInset),
            editor.widthAnchor.constraint(equalTo: composerContent.widthAnchor),
            composerFooter.widthAnchor.constraint(equalTo: composerContent.widthAnchor),
            composerFooter.heightAnchor.constraint(equalToConstant: Design.Size.chipHeight),
            submit.widthAnchor.constraint(equalToConstant: PromptChrome.submitSize),
            submit.heightAnchor.constraint(equalToConstant: PromptChrome.submitSize)
        ])
        owner.contentView = root
        runtime.onRow = { [weak self] index, row, blocks in
            guard let self else { return }
            self.rows.updateNativeRow(row, at: index, blocks: blocks, in: self.table)
            self.needsPresentation = true
        }
        runtime.onStreaming = { [weak self] text in
            guard let self else { return }
            self.rows.setStreaming(text.flatMap { $0.isEmpty ? nil : $0 }, in: self.table, native: true)
            self.needsPresentation = true
        }
        runtime.onChange = { [weak self] in self?.updateState() }
        runtime.onPermissionChange = { [weak self] in self?.updatePermission() }
        runtime.onQuestionsChange = { [weak self] in self?.updateQuestions() }
        setThemeAppearance()
        updatePermission()
        updateQuestions()
        updateState()
    }

    /// The queue's head as the production card, after the transcript as the Mac shows it. An
    /// answered card leaves; the next request, if any, replaces it.
    private func updatePermission() {
        let pending = runtime.pendingPermission
        guard pending?.id != presentedPermission else { return }
        presentedPermission = pending?.id
        let card = pending.map { pending in
            PermissionRequestView(request: pending.request) { [weak self] decision in
                self?.runtime.answerPermission(id: pending.id, decision)
            }
        }
        if let permissionCard { retire(permissionCard, returningFocus: false) }
        permissionCard = card
        if let card { decisionOrder.append(card) }
        rows.setDecisions(decisionOrder, in: table)
        followTail = true
        needsPresentation = true
    }

    /// Each provider question as the production card. A card the provider withdrew leaves.
    private func updateQuestions() {
        let live = Set(runtime.questions.map(\.request.id))
        for (id, card) in questionCards where !live.contains(id) {
            card.invalidate()
            questionCards[id] = nil
            retire(card, returningFocus: true)
        }
        for question in runtime.questions where questionCards[question.request.id] == nil {
            let id = question.request.id
            let card = ConversationQuestionCard(request: question.request) { [weak self] answers in
                self?.runtime.answerQuestion(id, answers)
            }
            card.onLayoutChange = { [weak self, weak card] in
                guard let self, let card else { return }
                let row = table.row(for: card)
                if row >= 0 { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
                needsPresentation = true
            }
            questionCards[id] = card
            decisionOrder.append(card)
        }
        rows.setDecisions(decisionOrder, in: table)
        followTail = true
        needsPresentation = true
    }

    /// Removes a card from the block. The Mac returns focus held inside a question card to the
    /// prompt, and leaves it where it was for a permission card; both are kept.
    private func retire(_ card: NSView, returningFocus: Bool) {
        decisionOrder.removeAll { $0 === card }
        if returningFocus, let responder = owner.firstResponder as? NSView, responder.isDescendant(of: card) {
            _ = owner.makeFirstResponder(editor.textView)
        }
    }

    private func updateState() {
        status.stringValue = runtime.pendingPermission != nil ? "Waiting for permission"
            : runtime.questions.isEmpty ? runtime.status : "Waiting for your answer"
        status.textColor = runtime.failure == nil ? Design.Text.secondary : Design.Status.negative
        let canSubmit = runtime.canSend
            && !editor.textView.hasMarkedText()
            && !editor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        PromptChrome.updateSubmit(submit, canSubmit: canSubmit, isStop: runtime.canInterrupt)
        submit.toolTip = runtime.canInterrupt ? "Stop · Esc" : "Send · Return"
        needsPresentation = true
    }

    private func send() {
        guard !editor.textView.hasMarkedText(), runtime.send(editor.textView.string) else { updateState(); return }
        editor.textView.string = ""
        followTail = true
        updateState()
    }

    func setThemeAppearance() {
        chrome.setThemeAppearance()
        root.appearance = LinuxTheme.appearance
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        refreshComposerSurface()
        rows.refreshTheme()
        needsPresentation = true
    }

    private func refreshComposerSurface() {
        PromptChrome.applySurface(to: composer, fill: Design.Surface.field,
            emphasized: owner.isKeyWindow && composerFocused)
        needsPresentation = true
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        self.focused = focused
        chrome.focus(focused, window: window)
        owner.isKeyWindow = focused
        _ = tw_workspace_composer_mode(window, 1)
        if focused { _ = owner.makeFirstResponder(editor.textView) }
        else { owner.cancelPointerGesture(); _ = owner.makeFirstResponder(nil) }
        _ = tw_workspace_editor_focus(window, focused ? 1 : 0)
        needsPresentation = true
    }

    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int, focused: Bool) throws {
        try chrome.refresh(window: window, width: width, height: height, originX: originX)
        let contentHeight = max(1, height - WorkspacePaneChrome.headerPixelHeight)
        let size = NSSize(width: CGFloat(width) / WorkspaceDisplay.scale, height: CGFloat(contentHeight) / WorkspaceDisplay.scale)
        guard needsPresentation || size != presentedSize || displayRevision != owner.displayRevision else { return }
        root.frame = NSRect(origin: .zero, size: size)
        let inset = min(Design.Spacing.inset, size.width / 8)
        let actionHeight = min(28, max(1, size.height / 5))
        let composerWidth = max(1, size.width - 2 * inset)
        // Width changes reflow the same cached TextKit document the editor already paints.
        // Reading its used rect adds no second string scan or alternate text measurement.
        editor.frame.size.width = max(1, composerWidth - 2 * Design.Spacing.inset)
        let lineHeight = (editor.textView.font ?? Design.Typography.body()).boundingRectForFont.height
        let resting = PromptChrome.restingHeight(minimum: Design.Size.inputHeight,
            lineHeight: lineHeight, showsFooter: true)
        let textHeight = editor.textView.layoutManager.flatMap { manager in
            editor.textView.textContainer.map { manager.usedRect(for: $0).height }
        } ?? 0
        let fitted = PromptChrome.fittedHeight(textHeight: textHeight, restingHeight: resting, showsFooter: true)
        let composerHeight = min(fitted.height, max(1, size.height - 2 * inset - actionHeight
            - Design.Spacing.small - Design.Size.chipHeight))
        let needsScroller = fitted.scrolls || composerHeight < fitted.height
        if editor.hasVerticalScroller != needsScroller { editor.hasVerticalScroller = needsScroller }
        composer.frame = NSRect(x: inset, y: inset + actionHeight + Design.Spacing.small,
            width: composerWidth, height: composerHeight)
        status.frame = NSRect(x: inset, y: inset, width: composerWidth, height: actionHeight)
        let bottom = composer.frame.maxY + Design.Spacing.medium
        scroll.frame = NSRect(x: inset, y: bottom, width: max(1, size.width - 2 * inset),
            height: max(1, size.height - bottom - inset))
        // The clip view already sizes its document to the viewport, so the table's own width is
        // no signal; the column's is. Cells read it when they are built and state it as theirs.
        if table.tableColumns.first?.width != scroll.bounds.width || table.frame.width != scroll.bounds.width {
            table.tableColumns.first?.width = scroll.bounds.width
            table.frame.size.width = scroll.bounds.width
            ConversationVirtualRowHost.stateColumnWidth(in: table)
            table.noteHeightOfRows(withIndexesChanged: table.visibleRowIndexes)
        }
        owner.layoutIfNeeded()
        if followTail {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.frame.height - scroll.contentView.bounds.height)))
        }
        let bitmap = Bitmap(width: width, height: contentHeight, background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: WorkspaceDisplay.scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_pane(window, $0.baseAddress, Int32(width), Int32(contentHeight), 0)
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        if focused {
            tw_title(window, title)
            let caret = activeTextView.convert(activeTextView.insertionPointRect, to: root)
            tw_text_input_rect(window, Int32(originX + Int(caret.minX * WorkspaceDisplay.scale)),
                Int32(WorkspacePaneChrome.headerPixelHeight + Int((size.height - caret.maxY) * WorkspaceDisplay.scale)),
                Int32(max(1, caret.width * WorkspaceDisplay.scale)), Int32(max(1, caret.height * WorkspaceDisplay.scale)))
        }
        tw_accessibility_show_terminal(window, title)
        needsPresentation = false
        presentedSize = size
        displayRevision = owner.displayRevision
        func waiting(_ view: NSView) -> Bool {
            (view as? NSTextField)?.isWaitingForCompleteTextViewport == true || view.subviews.contains(where: waiting)
        }
        let prepared = runtime.rowsPrepared && !waiting(table) && !status.isWaitingForCompleteTextViewport
        let composerTop = WorkspacePaneChrome.headerPixelHeight + Int((size.height - composer.frame.maxY) * WorkspaceDisplay.scale)
        let sendPoint = submit.convert(NSPoint(x: submit.bounds.midX, y: submit.bounds.midY), to: root)
        print("COMPOSER_FRAME x=\(originX + Int(composer.frame.minX * WorkspaceDisplay.scale)) y=\(composerTop) width=\(Int(composer.bounds.width * WorkspaceDisplay.scale)) height=\(Int(composer.bounds.height * WorkspaceDisplay.scale)) send=\(originX + Int(sendPoint.x * WorkspaceDisplay.scale)),\(WorkspacePaneChrome.headerPixelHeight + Int((size.height - sendPoint.y) * WorkspaceDisplay.scale)) enabled=\(submit.isEnabled) focused=\(composerFocused) scrolls=\(editor.hasVerticalScroller)")
        for card in decisionOrder where card.window != nil {
            // Window-pixel centres of a decision card's controls, for journeys that use them.
            var controls: [String] = []
            func centre(_ name: String, _ view: NSView) {
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: root)
                let x = originX + Int(point.x * WorkspaceDisplay.scale)
                let y = WorkspacePaneChrome.headerPixelHeight + Int((size.height - point.y) * WorkspaceDisplay.scale)
                controls.append("\(name.replacingOccurrences(of: " ", with: "_"))=\(x),\(y)")
            }
            func walk(_ view: NSView) {
                guard !view.isHidden else { return }
                if let button = view as? ThemedButton {
                    if button.isEnabled { centre(button.title, button) }
                    return
                }
                if let choice = view as? ConversationChoiceRow { centre(choice.accessibilityLabel() ?? "", choice); return }
                if let field = view as? NSTextField, field.isEditable { centre("field", field); return }
                view.subviews.forEach(walk)
            }
            walk(card)
            let kind = card === permissionCard ? "PERMISSION_FRAME \(presentedPermission ?? 0)" : "QUESTION_FRAME"
            print("\(kind) \(controls.joined(separator: " "))")
        }
        // Window-pixel centre and height of each mounted tool row, for journeys that open one.
        func tools(_ view: NSView) -> [ToolCallView] {
            ((view as? ToolCallView).map { [$0] } ?? []) + view.subviews.flatMap(tools)
        }
        for tool in tools(table) where !tool.visibleRect.isEmpty {
            let point = tool.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), to: root)
            print("TOOL_FRAME \(originX + Int(point.x * WorkspaceDisplay.scale)),\(WorkspacePaneChrome.headerPixelHeight + Int((size.height - point.y) * WorkspaceDisplay.scale)) height=\(Int(tool.bounds.height)) open=\(rows.expandedTools.count)")
        }
        print("CONVERSATION_FRAME \(runtime.id.uuidString) rows=\(table.numberOfRows) mounted=\(table.mountedViewCount) turns=\(runtime.completedTurns) prepared=\(prepared) dark=\(LinuxTheme.isDark) status=\(runtime.status)")
        fflush(nil)
    }

    func handle(_ input: TWEvent, window: OpaquePointer) {
        var input = input
        switch input.kind {
        case 6, 46:
            if let text = String(validatingCString: tw_event_text(&input)) {
                activeTextView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case 19, 47:
            if let text = String(validatingCString: tw_event_text(&input)) {
                let lengths = text.unicodeScalars.map { String($0).utf16.count }
                let start = min(max(0, Int(input.textCursor)), lengths.count)
                let end = min(start + max(0, Int(input.textSelectionLength)), lengths.count)
                activeTextView.setMarkedText(text, selectedRange: NSRange(location: lengths.prefix(start).reduce(0, +),
                    length: lengths[start..<end].reduce(0, +)), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case 7, 48:
            guard input.action != 3 else { return }
            let event = WindowHarness.composerKeyEvent(input)
            if input.modifiers & (4 | 8) != 0, Int(input.key) == 118 { paste() }
            else if input.modifiers & (4 | 8) != 0, Int(input.key) == 97 {
                activeTextView.selectAll(nil)
            }
            else { _ = owner.dispatchToContent(event) }
        case 14: paste()
        case 15, 17, 16:
            let type: NSEvent.EventType = input.kind == 16 ? .scrollWheel
                : input.kind == 17 ? .leftMouseDragged
                : input.action == 3 ? .leftMouseUp : .leftMouseDown
            let point = NSPoint(x: CGFloat(input.x) / WorkspaceDisplay.scale, y: root.bounds.height - CGFloat(input.y) / WorkspaceDisplay.scale)
            _ = owner.dispatchToContent(NSEvent(type: type, locationInWindow: point,
                scrollingDeltaY: input.kind == 16 ? CGFloat(input.key) : 0))
            if input.kind == 16 {
                followTail = scroll.contentView.bounds.maxY >= table.frame.maxY - 1
            }
            _ = tw_workspace_editor_focus(window, owner.firstResponder is NSTextView ? 1 : 0)
        default: break
        }
        updateState()
    }

    private func paste() {
        activeTextView.paste(nil)
    }

    /// Native text input reaches the focused text view: a decision card's field editor while
    /// one is editing, the prompt otherwise.
    private var activeTextView: NSTextView { (owner.firstResponder as? NSTextView) ?? editor.textView }
}
#endif
