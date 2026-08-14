import AppKit

/// One line in the info panel: a state glyph, what the line is about, and a reading on the right.
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
final class SessionInfoRowView: NSView {

    // MARK: - Types

    /// The command line a process row shows and can reveal. Display lines omit `argv[0]` — the
    /// primary label already names the process — while the tooltip lines carry the whole thing.
    struct CommandLine {
        let redactedDisplay: String
        let fullDisplay: String
        let redactedLine: String
        let fullLine: String
        let redactedCount: Int
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

    private let glyphView = GlyphView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let valueLabel = CompoundValueLabel()

    private let secondaryPrefix: String
    private let commandLine: CommandLine?
    private var factLines: [String] = []
    private var revealsSecrets = false
    private var contextMenuSession: AnyObject?
    private var stopButton: ThemedIconButton?

    private var isHovered = false

    /// What clicking the row does. Nil leaves the row inert, and with no action there is no
    /// hover either.
    private var action: (() -> Void)?

    // MARK: - Initialization

    init(
        symbolName: String,
        symbolColor: NSColor,
        primary: String,
        secondary: String,
        valueSegments: [String],
        indentLevel: Int = 0,
        commandLine: CommandLine? = nil,
        accessibilityLabel: String,
        action: (() -> Void)? = nil
    ) {
        self.secondaryPrefix = secondary
        self.commandLine = commandLine
        self.action = action
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.toolRowResting, radius: .control)

        glyphView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: SessionInfoLayout.glyphPointSize, weight: .regular))
        glyphView.tint = symbolColor

        primaryLabel.applyFont(.compactCode)
        primaryLabel.textColor = Design.Text.label
        primaryLabel.stringValue = primary
        primaryLabel.lineBreakMode = .byTruncatingTail

        secondaryLabel.applyFont(.compactCode)
        secondaryLabel.textColor = Design.Text.tertiary
        secondaryLabel.lineBreakMode = .byTruncatingTail

        valueLabel.segments = valueSegments
        valueLabel.alignment = .right

        // The value is the row's answer, so it keeps its width and gives up whole segments —
        // never characters — when squeezed; the two descriptions truncate first. High rather
        // than required: required would make the widest row a hard floor under the whole panel.
        valueLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        [glyphView, primaryLabel, secondaryLabel, valueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        // The dot column itself draws the tree: one step of indent per level of parentage,
        // capped so a pathological chain cannot push the name into the value.
        let indent = Design.Spacing.small
            + CGFloat(min(indentLevel, SessionInfoLayout.maxIndentDepth)) * Design.Spacing.medium

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SessionInfoLayout.rowHeight),

            glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),
            glyphView.heightAnchor.constraint(equalTo: heightAnchor),

            primaryLabel.leadingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: Design.Spacing.small),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryLabel.leadingAnchor.constraint(equalTo: primaryLabel.trailingAnchor, constant: Design.Spacing.small),
            secondaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: secondaryLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.heightAnchor.constraint(equalTo: heightAnchor)
        ])

        // The row speaks as one element: its label names the line, its value carries the state
        // and readings, and the labels inside stay quiet so nothing is announced twice.
        setAccessibilityElement(true)
        setAccessibilityRole(action != nil ? .link : .group)
        setAccessibilityLabel(accessibilityLabel)
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
        addSubview(button)

        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.tight),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
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
    }

    private func recomposeSecondary() {
        guard let commandLine else {
            secondaryLabel.stringValue = secondaryPrefix
            return
        }
        let display = revealsSecrets ? commandLine.fullDisplay : commandLine.redactedDisplay
        secondaryLabel.stringValue = display.isEmpty
            ? secondaryPrefix
            : "\(secondaryPrefix)  \(display)"
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
        if !presentRevealMenu(at: .pointer(event.locationInWindow)) {
            super.rightMouseDown(with: event)
        }
    }

    /// The pointerless route to the same menu, hanging from the row itself.
    override func accessibilityPerformShowMenu() -> Bool {
        presentRevealMenu(at: .control)
    }

    /// Offered only when something was actually hidden: a command line that redacted nothing
    /// has nothing to reveal, and a menu with a no-op item would promise otherwise.
    private func presentRevealMenu(at anchor: ThemedMenuAnchor) -> Bool {
        guard let commandLine, commandLine.redactedCount > 0 else { return false }

        let entries: [ThemedMenuEntry] = [.item(ThemedMenuItem(
            title: L10n.string("Show Full Command"),
            isSelected: revealsSecrets,
            onChoose: { [weak self] in self?.toggleReveal() }
        ))]

        contextMenuSession = ThemedMenuPresenter.present(
            // No minimum: a one-item pointer menu sizes to its title.
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
        guard let action else {
            super.mouseDown(with: event)
            return
        }
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        action()
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard action != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
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

        guard action != nil || stopButton != nil else { return }
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

    /// The raised plate belongs only to a row whose *whole surface* is a click — a port row.
    /// A stoppable process row hovers by revealing its ✕ instead; a plate there would promise
    /// a row-wide press the row does not have.
    private func updateSurface() {
        let raised = isHovered && action != nil
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

// MARK: - Layout

enum SessionInfoLayout {
    static let rowHeight: CGFloat = 22
    static let glyphPointSize: CGFloat = 11

    /// Levels of parentage the indent will draw before flattening: deep enough for any real
    /// dev-server tree, shallow enough that a runaway chain leaves room for the name.
    static let maxIndentDepth = 6
}

extension SessionInfoSymbols {
    /// The stop affordance's mark — a tab's close vocabulary, because "make this go away" is
    /// the same verb in both places.
    static let stop = "xmark"
}
