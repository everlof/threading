import AppKit

/// One compact fact in the info panel: a state glyph, a two-line name/detail column, and a
/// reading on the right — and, under a process, the rest of its story when asked for.
///
/// It follows the tool row's rule rather than the table's — **no fill at rest**, raised on
/// hover — because a panel is mostly rows, and a stack of filled slabs reads as the content
/// rather than as a list of facts about it. Only a row that *does* something takes a hover at
/// all; on the rest the absence of one is the honest signal that there is nothing to click.
///
/// A process row carries its command line, redacted by default: argv is where credentials
/// travel, and this panel ends up in screenshots. The raw line is one deliberate right-click
/// away (`Show Full Command`), per row and transient — a rebuild forgets the choice, which is
/// the right memory for a secret.
///
/// **A process row opens.** One compact line cannot hold an agent's launch command — a settings
/// path, a model, an effort, sometimes the whole opening prompt — and truncating it kept the
/// part a person was looking for behind an ellipsis, with the tooltip as the only way in. A
/// click on the row unfolds the command beneath it, the program then one flag with its value
/// per line, together with when the process started and where it runs. The fold is the row's
/// own state, so a poll writing new readings into the row leaves it open.
final class SessionInfoRowView: NSView, PointerClaiming {

    // MARK: - Types

    /// Which vocabulary the row's text speaks.
    ///
    /// A process is code — its name, pid and argv belong in the compact monospace — while a
    /// receipt line (*Total · 38 requests*) is a sentence with a number beside it, and setting
    /// prose in a code face made "Main agent" read as an identifier. The receipt face pairs the
    /// detail face with fixed-width digits for the value.
    enum Face {
        case code
        case receipt
    }

    /// The command line a process row shows and can reveal. The compact line omits `argv[0]` —
    /// the primary label already names the process — while the tooltip lines, the unfolded
    /// block and the copied text carry the whole thing.
    struct CommandLine {

        /// The command as a person would write it across lines, and how much would not fit.
        struct Block: Equatable {
            let lines: [String]
            let omittedArgumentCount: Int
        }

        let redactedArguments: [String]
        let fullArguments: [String]
        let redactedCount: Int
        let redactedDisplay: String
        let fullDisplay: String
        let redactedLine: String
        let fullLine: String

        private let home: String
        private let collapsedRedacted: [String]
        private let collapsedFull: [String]

        /// Builds the safe presentation forms from argv. An argument may itself contain a
        /// multiline prompt; joining argv with spaces does not remove those embedded newlines,
        /// and AppKit then measures a tall field whose first line can paint several rows away.
        /// The panel is a one-line summary, so all display whitespace is deliberately collapsed
        /// before any string reaches a label.
        init?(processArguments arguments: [String], home: String = NSHomeDirectory()) {
            guard !arguments.isEmpty else { return nil }

            let redacted = CommandLineRedactor.redact(arguments)
            self.init(
                redactedArguments: redacted.arguments,
                fullArguments: arguments,
                redactedCount: redacted.redactedCount,
                home: home
            )
        }

        init(
            redactedArguments: [String],
            fullArguments: [String],
            redactedCount: Int,
            home: String = NSHomeDirectory()
        ) {
            let collapsedRedacted = redactedArguments.map(Self.collapsed).filter { !$0.isEmpty }
            let collapsedFull = fullArguments.map(Self.collapsed).filter { !$0.isEmpty }
            let abbreviate = { PathAbbreviation.abbreviatingHome(in: $0, home: home) }

            self.redactedArguments = redactedArguments
            self.fullArguments = fullArguments
            self.redactedCount = redactedCount
            self.home = home
            self.collapsedRedacted = collapsedRedacted
            self.collapsedFull = collapsedFull
            redactedDisplay = collapsedRedacted.dropFirst().map(abbreviate).joined(separator: " ")
            fullDisplay = collapsedFull.dropFirst().map(abbreviate).joined(separator: " ")
            redactedLine = collapsedRedacted.map(abbreviate).joined(separator: " ")
            fullLine = collapsedFull.map(abbreviate).joined(separator: " ")
        }

        /// The command across lines: the program, then each flag with the value that follows
        /// it. Bounded twice — a line is cut at `maximumLineCharacters`, and past
        /// `maximumLines` the rest is counted rather than drawn — because an opening prompt is
        /// one argument and can be pages long.
        func block(revealed: Bool) -> Block {
            let arguments = revealed ? collapsedFull : collapsedRedacted
            var lines: [String] = []
            var covered = 0
            var index = 0

            while index < arguments.count, lines.count < ProcessDetailDefaults.maximumLines {
                var line = arguments[index]
                var width = 1
                if index > 0, Self.takesAValue(line), index + 1 < arguments.count,
                   !Self.isFlag(arguments[index + 1]) {
                    line += " " + arguments[index + 1]
                    width = 2
                }
                lines.append(Self.cut(PathAbbreviation.abbreviatingHome(in: line, home: home)))
                covered += width
                index += width
            }

            return Block(lines: lines, omittedArgumentCount: arguments.count - covered)
        }

        /// What "Copy Command Line" puts on the pasteboard: the arguments as given, quoted so
        /// the line runs again in a shell, with paths unabbreviated because a shell does not
        /// expand `~` inside a quoted string.
        func copyText(revealed: Bool) -> String {
            (revealed ? fullArguments : redactedArguments)
                .map(Self.shellQuoted)
                .joined(separator: " ")
        }

        // MARK: Private

        private static func collapsed(_ argument: String) -> String {
            argument
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }

        private static func isFlag(_ argument: String) -> Bool {
            argument.hasPrefix("-") && argument.count > 1
        }

        /// A bare flag takes the argument after it; `--key=value` already carries its own.
        private static func takesAValue(_ argument: String) -> Bool {
            isFlag(argument) && !argument.contains("=")
        }

        private static func cut(_ line: String) -> String {
            guard line.count > ProcessDetailDefaults.maximumLineCharacters else { return line }
            return line.prefix(ProcessDetailDefaults.maximumLineCharacters) + "…"
        }

        private static let shellSafeCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_./=:@%+,"))

        private static func shellQuoted(_ argument: String) -> String {
            guard !argument.isEmpty else { return "''" }
            guard argument.unicodeScalars.contains(where: { !shellSafeCharacters.contains($0) })
            else { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    /// What moves between polls, written into the row in place so a changing number never costs
    /// the pointer its hover or the panel its scroll position.
    struct Reading {
        let valueSegments: [String]
        let dotSymbolName: String
        let dotColor: NSColor
        let factLines: [String]
        let accessibilityValue: String
    }

    // MARK: - Properties

    private let summary = NSView()
    private let glyphView = GlyphView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let valueLabel = CompoundValueLabel()
    private var detailView: ProcessDetailView?
    private var collapsedBottom: NSLayoutConstraint?
    private var expandedConstraints: [NSLayoutConstraint] = []

    private let secondaryPrefix: String
    private let commandLine: CommandLine?
    private let isExpandable: Bool
    private var factLines: [String] = []
    private var revealsSecrets = false
    private var contextMenuSession: AnyObject?
    private var stopButton: ThemedIconButton?

    private var isHovered = false

    /// Whether the row's story is unfolded beneath it. Row-local: a poll writes readings into
    /// an open row without closing it, and the panel re-opens it after a rebuild.
    private(set) var isExpanded = false

    /// Answered when the user opens or closes the row, so the panel can remember which
    /// processes were open across a rebuild.
    var onExpansionChange: ((Bool) -> Void)?

    /// What clicking the row does. Nil leaves the row inert, and with no action there is no
    /// hover either.
    private var action: (() -> Void)?

    /// A row answers the pointer when it opens something or unfolds.
    private var isInteractive: Bool { action != nil || isExpandable }

    // MARK: - Initialization

    init(
        symbolName: String?,
        symbolColor: NSColor,
        primary: String,
        secondary: String,
        valueSegments: [String],
        face: Face = .code,
        indentLevel: Int = 0,
        commandLine: CommandLine? = nil,
        isExpandable: Bool = false,
        accessibilityLabel: String,
        action: (() -> Void)? = nil
    ) {
        self.secondaryPrefix = secondary
        self.commandLine = commandLine
        self.isExpandable = isExpandable
        self.action = action
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.toolRowResting, radius: .control)

        // A receipt row keeps the glyph's slot without a glyph, so every row's text starts on
        // one column whether or not a state dot stands before it.
        glyphView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: SessionInfoLayout.glyphPointSize, weight: .regular))
        }
        glyphView.tint = symbolColor

        switch face {
        case .code:
            primaryLabel.applyFont(.compactCode)
            secondaryLabel.applyFont(.compactCode)
            valueLabel.face = .code
        case .receipt:
            primaryLabel.applyFont(.detail(weight: .medium))
            secondaryLabel.applyFont(.detail())
            valueLabel.face = .numeric
        }
        primaryLabel.textColor = Design.Text.label
        primaryLabel.stringValue = primary
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.usesSingleLineMode = true

        secondaryLabel.textColor = Design.Text.tertiary
        secondaryLabel.lineBreakMode = .byTruncatingTail
        // `lineBreakMode` chooses how a line ends; it does not make an AppKit label one line.
        // Agent launch arguments can be paragraph-long, and a wrapping field inside this compact
        // two-line row paints through the rows and section headings on both sides of it.
        secondaryLabel.usesSingleLineMode = true

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.distribution = .fillEqually
        textStack.spacing = 0
        textStack.addArrangedSubview(primaryLabel)
        textStack.addArrangedSubview(secondaryLabel)
        primaryLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        secondaryLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        valueLabel.segments = valueSegments
        valueLabel.alignment = .right

        // The value is the row's answer, so it keeps its width and gives up whole segments —
        // never characters — when squeezed; the two descriptions truncate first. High rather
        // than required: required would make the widest row a hard floor under the whole panel.
        valueLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        summary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summary)
        [glyphView, textStack, valueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            summary.addSubview($0)
        }

        // The dot column itself draws the tree: one step of indent per level of parentage,
        // capped so a pathological chain cannot push the name into the value.
        let indent = Design.Spacing.small
            + CGFloat(min(indentLevel, SessionInfoLayout.maxIndentDepth)) * Design.Spacing.medium

        let collapsedBottom = summary.bottomAnchor.constraint(equalTo: bottomAnchor)
        self.collapsedBottom = collapsedBottom

        NSLayoutConstraint.activate([
            // The compact band keeps the row's fixed measure; the fold below adds to it.
            summary.topAnchor.constraint(equalTo: topAnchor),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.heightAnchor.constraint(equalToConstant: SessionInfoLayout.rowHeight),
            collapsedBottom,

            glyphView.leadingAnchor.constraint(equalTo: summary.leadingAnchor, constant: indent),
            glyphView.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),
            glyphView.heightAnchor.constraint(equalTo: summary.heightAnchor),

            textStack.leadingAnchor.constraint(
                equalTo: glyphView.trailingAnchor,
                constant: Design.Spacing.small
            ),
            textStack.topAnchor.constraint(equalTo: summary.topAnchor, constant: Design.Spacing.hairline),
            textStack.bottomAnchor.constraint(equalTo: summary.bottomAnchor, constant: -Design.Spacing.hairline),

            valueLabel.leadingAnchor.constraint(
                equalTo: textStack.trailingAnchor,
                constant: Design.Spacing.small
            ),
            valueLabel.trailingAnchor.constraint(equalTo: summary.trailingAnchor, constant: -Design.Spacing.small),
            valueLabel.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            valueLabel.heightAnchor.constraint(equalTo: summary.heightAnchor)
        ])

        // The row speaks as one element: its label names the line, its value carries the state
        // and readings, and the labels inside stay quiet so nothing is announced twice.
        setAccessibilityElement(true)
        setAccessibilityRole(action != nil ? .link : .group)
        setAccessibilityLabel(accessibilityLabel)
        if isExpandable {
            setAccessibilityHelp(L10n.string(
                "Press to show or hide the command line, start time and working directory."
            ))
        }
        primaryLabel.setAccessibilityElement(false)
        secondaryLabel.setAccessibilityElement(false)
        valueLabel.isAccessibilityExposed = false

        recomposeSecondary()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Installs the stop affordance: a hover-revealed ✕ standing where the value stands, so
    /// revealing it never shifts a sibling. Never called for a root row — session teardown owns
    /// those — nor for a process whose start identity could not be read: no identity, no kill.
    ///
    /// The reveal follows the sidebar rows' rule: hidden rather than merely transparent at
    /// rest, because `hitTest` does not read `alphaValue` and an invisible button would still
    /// swallow the row's own clicks; deferred glyph, because most rows are never hovered.
    func offerStop(titled accessibility: String, handler: @escaping () -> Void) {
        guard stopButton == nil else { return }

        let button = ThemedIconButton(
            symbolName: SessionInfoSymbols.stop,
            accessibility: accessibility,
            target: .inline,
            inkSource: .chrome,
            glyphMaterialization: .deferred
        )
        button.toolTip = accessibility
        button.onPress = handler
        button.isHidden = true
        button.alphaValue = 0
        summary.addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: summary.trailingAnchor, constant: -Design.Spacing.tight),
            button.centerYAnchor.constraint(equalTo: summary.centerYAnchor)
        ])

        stopButton = button
        updateTrackingAreas()
    }

    /// Applies one poll's moving facts in place.
    func update(_ reading: Reading) {
        valueLabel.segments = reading.valueSegments
        glyphView.image = NSImage(
            systemSymbolName: reading.dotSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: SessionInfoLayout.glyphPointSize, weight: .regular))
        glyphView.tint = reading.dotColor
        factLines = reading.factLines
        setAccessibilityValue(reading.accessibilityValue)
        recomposeToolTip()
        if isExpanded { refreshDetail() }
    }

    /// Updates a fixed-form summary row without replacing the row under the pointer or in the
    /// scroll document. Process rows use `update(_:)`; usage rows keep their glyph and primary
    /// identity while their secondary receipt, values and spoken sentence move together.
    func updateSummary(
        secondary: String,
        valueSegments: [String],
        accessibilityLabel: String
    ) {
        guard commandLine == nil else {
            assertionFailure("A command row cannot become a fixed-form summary")
            return
        }
        secondaryLabel.stringValue = secondary
        valueLabel.segments = valueSegments
        setAccessibilityLabel(accessibilityLabel)
    }

    // MARK: - Expansion

    /// Opens or closes the fold without reporting it — the panel restoring a remembered choice
    /// after a rebuild is not the user making one.
    func setExpanded(_ expanded: Bool) {
        guard isExpandable, expanded != isExpanded else { return }
        isExpanded = expanded

        let detail = materializeDetail()
        if expanded {
            refreshDetail()
            collapsedBottom?.isActive = false
            detail.isHidden = false
            NSLayoutConstraint.activate(expandedConstraints)
        } else {
            NSLayoutConstraint.deactivate(expandedConstraints)
            detail.isHidden = true
            collapsedBottom?.isActive = true
        }
        needsLayout = true
    }

    private func toggleExpansion() {
        setExpanded(!isExpanded)
        onExpansionChange?(isExpanded)
    }

    /// Built on the first opening, because most rows are never opened.
    private func materializeDetail() -> ProcessDetailView {
        if let detailView { return detailView }

        let detail = ProcessDetailView()
        detail.isHidden = true
        addSubview(detail)
        expandedConstraints = [
            detail.topAnchor.constraint(equalTo: summary.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small)
        ]
        detailView = detail
        return detail
    }

    private func refreshDetail() {
        guard let detailView else { return }
        detailView.setFacts(factLines)
        detailView.setBlock(commandLine?.block(revealed: revealsSecrets))
    }

    // MARK: - Reveal

    /// Whether the raw command line is on show — row-local and transient by design: a shape
    /// rebuild forgets it, which is the right memory for a secret.
    var revealsFullCommand: Bool { revealsSecrets }

    /// Internal rather than private for behavior tests: the only other route is the themed
    /// menu, and presenting one puts a window on screen, which the fast plan forbids.
    func toggleReveal() {
        revealsSecrets.toggle()
        recomposeSecondary()
        recomposeToolTip()
        if isExpanded { refreshDetail() }
    }

    private func recomposeSecondary() {
        guard let commandLine else {
            secondaryLabel.stringValue = secondaryPrefix
            return
        }
        let display = revealsSecrets ? commandLine.fullDisplay : commandLine.redactedDisplay
        secondaryLabel.stringValue = display.isEmpty
            ? secondaryPrefix
            : "\(secondaryPrefix)\(SessionInfoLayout.detailSeparator)\(display)"
    }

    /// A process row's tooltip is the whole answer: the command line at the reveal the user
    /// chose, then the poll's facts. A port row has no command line and no fact lines, so its
    /// host-set tooltip is left alone.
    private func recomposeToolTip() {
        guard commandLine != nil || !factLines.isEmpty else { return }
        var lines: [String] = []
        if let commandLine {
            lines.append(revealsSecrets ? commandLine.fullLine : commandLine.redactedLine)
        }
        lines.append(contentsOf: factLines)
        toolTip = lines.joined(separator: "\n")
    }

    // MARK: - Context Menu

    override func rightMouseDown(with event: NSEvent) {
        if !presentMenu(at: .pointer(event.locationInWindow)) {
            super.rightMouseDown(with: event)
        }
    }

    /// The pointerless route to the same menu, hanging from the row itself.
    override func accessibilityPerformShowMenu() -> Bool {
        presentMenu(at: .control)
    }

    /// What the row's menu offers. Internal so a test can read the offer without presenting
    /// it: a command line can always be copied, and a reveal is offered only when something was
    /// actually hidden — a menu with a no-op item would promise otherwise.
    func menuEntries() -> [ThemedMenuEntry] {
        guard let commandLine else { return [] }

        var entries: [ThemedMenuEntry] = [.item(ThemedMenuItem(
            title: L10n.string("Copy Command Line"),
            onChoose: { [weak self] in self?.copyCommandLine() }
        ))]
        if commandLine.redactedCount > 0 {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Show Full Command"),
                isSelected: revealsSecrets,
                onChoose: { [weak self] in self?.toggleReveal() }
            )))
        }
        return entries
    }

    /// Copies what is shown: the redacted line unless the row was deliberately revealed.
    func copyCommandLine() {
        guard let commandLine else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commandLine.copyText(revealed: revealsSecrets), forType: .string)
    }

    private func presentMenu(at anchor: ThemedMenuAnchor) -> Bool {
        let entries = menuEntries()
        guard !entries.isEmpty else { return false }

        contextMenuSession = ThemedMenuPresenter.present(
            // No minimum: a short pointer menu sizes to its titles.
            ThemedMenuPresentation(entries: entries, minimumWidth: 0),
            from: self,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
        return contextMenuSession != nil
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        if let action {
            action()
        } else if isExpandable {
            toggleExpansion()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        if let action {
            action()
            return true
        }
        guard isExpandable else { return false }
        toggleExpansion()
        return true
    }

    /// A row that opens something, or unfolds, is a line of text you press; one that only
    /// reports is still an opaque row. See `PointerClaiming`.
    var restingPointer: NSCursor? { isInteractive ? .pointingHand : .arrow }

    override func resetCursorRects() {
        registerPointerClaims()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)

        // The row moved rather than the pointer, so no exit was ever delivered — see
        // `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) {
            isHovered = false
            updateSurface()
            setStopRevealed(false, animated: false)
        }

        guard isInteractive || stopButton != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        // Not through whatever floats over the pane — see `NSView.isPointerCovered(at:)`.
        guard !isPointerCovered(at: event.locationInWindow) else { return }
        isHovered = true
        updateSurface()
        setStopRevealed(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateSurface()
        setStopRevealed(false, animated: true)
    }

    /// The raised plate belongs to a row whose *whole surface* is a click — a port row that
    /// opens, or a process row that unfolds. A row that merely reports keeps its ground.
    private func updateSurface() {
        let raised = isHovered && isInteractive
        applyLayerBackground(raised ? Design.Chat.toolRowActive : Design.Chat.toolRowResting)
    }

    /// The ✕ stands where the value stands, so the swap moves nothing: the reading fades out
    /// as the button fades in. Unhidden before the fade in so it is hit-testable for the whole
    /// reveal; hidden only after the fade out so it never vanishes mid-frame.
    private func setStopRevealed(_ revealed: Bool, animated: Bool) {
        guard let stopButton else { return }

        if revealed {
            stopButton.materializeGlyphIfNeeded()
            stopButton.isHidden = false
        }

        guard animated else {
            stopButton.alphaValue = revealed ? 1 : 0
            stopButton.isHidden = !revealed
            valueLabel.alphaValue = revealed ? 0 : 1
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.quick
            stopButton.animator().alphaValue = revealed ? 1 : 0
            valueLabel.animator().alphaValue = revealed ? 0 : 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let stopButton = self.stopButton else { return }
                if stopButton.alphaValue == 0 { stopButton.isHidden = true }
            }
        })
    }
}

// MARK: - Detail

/// What a process row unfolds: the poll's facts on quiet lines, then the command as a person
/// would write it — the program, and under it one flag with its value per line, continuation
/// lines stepped in so the program stays the head of the block.
///
/// Bounded by construction: at most `ProcessDetailDefaults.maximumLines` code lines plus a
/// handful of fact lines, each wrapping to a few lines and then truncating, so an opening
/// prompt the length of a page costs the panel a paragraph, not a page.
private final class ProcessDetailView: NSView {

    private let stack = NSStackView()
    private var factLabels: [NSTextField] = []
    private var lineHosts: [NSView] = []
    private var lineLabels: [NSTextField] = []
    private var block: SessionInfoRowView.CommandLine.Block?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A wrapping label wraps at the width it *has*; see `AgentWorkSummaryView.layout()`.
    override func layout() {
        super.layout()
        for label in factLabels + lineLabels where label.preferredMaxLayoutWidth != label.bounds.width {
            label.preferredMaxLayoutWidth = label.bounds.width
        }
    }

    /// The facts move every poll ("Started 8 min ago" becomes 9), so a matching count is
    /// written in place; only a changed count rebuilds the group.
    func setFacts(_ facts: [String]) {
        if facts.count == factLabels.count {
            for (label, fact) in zip(factLabels, facts) where label.stringValue != fact {
                label.stringValue = fact
            }
            return
        }

        factLabels.forEach { $0.removeFromSuperview() }
        factLabels = facts.map { fact in
            let label = Self.wrappingLabel(
                font: .detail(),
                color: Design.Text.tertiary,
                maximumLines: ProcessDetailDefaults.maximumLinesPerFact
            )
            label.stringValue = fact
            return label
        }
        for (index, label) in factLabels.enumerated() {
            stack.insertArrangedSubview(label, at: index)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// The command block is the same until the reveal changes, so it is rebuilt only then.
    func setBlock(_ block: SessionInfoRowView.CommandLine.Block?) {
        guard block != self.block else { return }
        self.block = block

        lineHosts.forEach { $0.removeFromSuperview() }
        lineHosts.removeAll()
        lineLabels.removeAll()
        guard let block else { return }

        var lines = block.lines
        if block.omittedArgumentCount > 0 {
            lines.append(L10n.format("… %lld more arguments", Int64(block.omittedArgumentCount)))
        }
        for (index, line) in lines.enumerated() {
            let label = Self.wrappingLabel(
                font: .compactCode,
                color: Design.Text.secondary,
                maximumLines: ProcessDetailDefaults.maximumLinesPerArgument
            )
            label.stringValue = line
            let host = Self.host(label, indented: index > 0)
            stack.addArrangedSubview(host)
            host.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            lineHosts.append(host)
            lineLabels.append(label)
        }
    }

    private static func wrappingLabel(
        font: Design.FontRole,
        color: NSColor,
        maximumLines: Int
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        // A label, not a text well: selectable text would claim the I-beam and the clicks that
        // fold the row, and the whole line is one menu item away on the pasteboard.
        label.isSelectable = false
        label.applyFont(font)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = maximumLines
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// Continuation lines step in by one indent so the program reads as the head of the block.
    private static func host(_ label: NSTextField, indented: Bool) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: indented ? Design.Spacing.medium : 0
            ),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            label.topAnchor.constraint(equalTo: host.topAnchor),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return host
    }
}

// MARK: - Layout

enum SessionInfoLayout {
    static let rowHeight: CGFloat = 30
    static let glyphPointSize: CGFloat = 11
    static let detailSeparator = " · "

    /// Levels of parentage the indent will draw before flattening: deep enough for any real
    /// dev-server tree, shallow enough that a runaway chain leaves room for the name.
    static let maxIndentDepth = 6
}

enum ProcessDetailDefaults {
    /// Code lines an unfolded row will draw before counting the rest: room for any real launch
    /// command, and a ceiling under a script invoked with hundreds of paths.
    static let maximumLines = 24

    /// Characters kept of one line: enough to read a long path or the head of a prompt.
    static let maximumLineCharacters = 400

    /// How far one argument wraps before its tail is cut — a paragraph, not a page.
    static let maximumLinesPerArgument = 4

    static let maximumLinesPerFact = 2
}

extension SessionInfoSymbols {
    /// The stop affordance's mark — a tab's close vocabulary, because "make this go away" is
    /// the same verb in both places.
    static let stop = "xmark"
}
