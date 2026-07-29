import AppKit
import SkalmanExtensionKit

// MARK: - Defaults

enum GitStatusOverlayDefaults {
    static let height: CGFloat = 26
    static let fontSize: CGFloat = 11
    static let maxWidth: CGFloat = 360
    /// Quiet at rest, per the design system; full under the pointer.
    ///
    /// Carried by the card's **contents** rather than by the card. On the view it also thinned
    /// the fill, and a fill that thins over a conversation is a card with the agent's own text
    /// running through it.
    static let restingContentAlpha: CGFloat = 0.85
}

// MARK: - View

/// The floating card at the session pane's top-right corner: branch and uncommitted work while
/// idle; plan position, changed files and live line totals while the agent is working.
///
/// The pane's surfaces answer "what is the agent saying"; this answers what changed in the
/// checkout and whether delegated agents are active. It stays a summary because both full
/// answers already have surfaces: Git Review and the Subagents display-pane tab.
final class GitStatusOverlayView: BackdropOverlay {

    // MARK: - Properties

    /// Called when the Git portion is clicked; the container routes it to the review tab.
    var onOpen: (() -> Void)?
    /// The child-agent segment is a distinct destination inside the same status card.
    var onOpenSubagents: (() -> Void)?

    private let stack = NSStackView()
    private let glyph = NSImageView()
    private let orb = WorkingOrbView()
    private let subagentsButton: ThemedButton
    private var textLabel: NSTextField?

    /// The `session.corner-card@1` `top-trailing` slot: extension rows under the summary line.
    ///
    /// The slot ID names the corner, not the content — a future leading card becomes a
    /// `top-leading` slot on the same contract. The card grows downward when rows exist and
    /// keeps its exact single-line geometry when they do not.
    private let extensionSlotStack = NSStackView()
    /// The host requires a container, but this contract is slot-only — no hook, no
    /// replacement — so the container never joins the hierarchy and composes nothing.
    private let customizationContainer = ComponentContentContainer(defaultContent: NSView())
    private var customizationHost: ComponentCustomizationHost?
    private var collapsedBottomConstraint: NSLayoutConstraint?
    private var expandedBottomConstraint: NSLayoutConstraint?
    private var slotRowWidthConstraints: [NSLayoutConstraint] = []

    /// Held so a backdrop change can rebuild the label, which carries its colours inside an
    /// attributed string and cannot be re-inked in place.
    private var lastReading: GitChangeMonitor.Reading?
    private var isRunActive = false
    private var runProgress: RunProgress?
    private var subagentCounts = (working: 0, done: 0)

    /// Lifts the card's *contents* to full strength under the pointer. The surface behind them
    /// does not move: it is what keeps the pane's text out of the card.
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            let alpha = isHovered ? 1 : GitStatusOverlayDefaults.restingContentAlpha
            stack.alphaValue = alpha
            extensionSlotStack.alphaValue = alpha
        }
    }

    // MARK: - Initialization

    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
    ) {
        subagentsButton = ThemedButton(
            symbol: "person.2",
            accessibility: L10n.string("Open Subagents"),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        toolTip = L10n.string("Open Git Review (⇧⌘R)")
        setAccessibilityRole(.button)

        wantsLayer = true
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: L10n.string("Branch")
        )
        glyph.symbolConfiguration = .init(
            pointSize: GitStatusOverlayDefaults.fontSize,
            weight: .medium
        )

        stack.orientation = .horizontal
        // Tighter than the gap the sentence itself carries between branch and counters, so the
        // mark reads as belonging to the name beside it rather than as a third thing in the row.
        stack.spacing = Design.Spacing.tight
        stack.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        stack.translatesAutoresizingMaskIntoConstraints = false
        orb.isHidden = true
        stack.addArrangedSubview(orb)
        stack.addArrangedSubview(glyph)
        subagentsButton.target = self
        subagentsButton.action = #selector(openSubagents)
        subagentsButton.emphasis = .tertiary
        subagentsButton.font = Design.Typography.numericDetail(weight: .medium)
        subagentsButton.hoverFill = Design.Surface.controlHover
        subagentsButton.setContentHuggingPriority(.required, for: .horizontal)
        subagentsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        subagentsButton.isHidden = true
        stack.addArrangedSubview(subagentsButton)
        addSubview(stack)

        extensionSlotStack.orientation = .vertical
        extensionSlotStack.alignment = .leading
        extensionSlotStack.spacing = Design.Spacing.tight
        extensionSlotStack.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        extensionSlotStack.translatesAutoresizingMaskIntoConstraints = false
        extensionSlotStack.isHidden = true
        extensionSlotStack.setAccessibilityIdentifier("session.corner-card.slot.top-trailing")
        addSubview(extensionSlotStack)

        // The summary keeps its exact 26-point band — top-pinned now instead of centred, so
        // the card can grow downward under extension rows without moving a pixel of the line
        // the render tests measure. With the slot empty the collapsed bottom reproduces the
        // original fixed height.
        let collapsedBottom = bottomAnchor.constraint(equalTo: stack.bottomAnchor)
        let expandedBottom = bottomAnchor.constraint(
            equalTo: extensionSlotStack.bottomAnchor,
            constant: Design.Spacing.small
        )
        collapsedBottomConstraint = collapsedBottom
        expandedBottomConstraint = expandedBottom

        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: GitStatusOverlayDefaults.maxWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: GitStatusOverlayDefaults.height),
            extensionSlotStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            extensionSlotStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),
            extensionSlotStack.topAnchor.constraint(equalTo: stack.bottomAnchor),
            collapsedBottom
        ])

        customizationHost = ComponentCustomizationHost(
            target: .sessionCornerCard(),
            contentContainer: customizationContainer,
            slots: ["top-trailing": extensionSlotStack],
            lookup: customizationLookup,
            imageResolver: ExtensionComponentResourceResolver.image,
            onResolution: { [weak self] _ in self?.needsLayout = true }
        )
        // Detached until the container binds a real session; family-wide publications must not
        // decorate a card that is not anyone's checkout yet.
        customizationHost?.deactivate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// This card floats on the *terminal's* background, not on the chrome's ground — see
    /// `BackdropOverlay`. Its surface and its label both come from there.
    ///
    /// `+N −M` stays green and red — those two are semantic rather than decorative, and a green
    /// that stopped meaning added would cost more than the contrast it bought — but it is the
    /// theme's green *measured against this card* (`Design.Diff.on(_:)`), which keeps the hue and
    /// moves only the lightness when the card is too close to it. The card's colour comes from
    /// the terminal's palette, so the app theme cannot know what its own green will land on.
    /// **The card is opaque**, which the roles it draws from are not. It floats over the pane's
    /// live content — a conversation, or the terminal itself — rather than over an empty stretch
    /// of backdrop, so `ink.surface` at 14% let the text underneath run straight through the
    /// branch name. Flattening against the ground keeps exactly the colour the role asks for and
    /// loses only the see-through; `WindowBackdrop.opaque` carries the reasoning.
    ///
    /// The border flattens against the *card*, not the ground, because that is what is behind it.
    override func applyInk(_ ink: Design.Ink) {
        layer?.cornerRadius = Design.Radius.pill(height: GitStatusOverlayDefaults.height)
        let surface = WindowBackdrop.opaque(ink.surface)
        applyLayerBackground(surface)
        layer?.borderWidth = Design.Radius.border
        applyLayerBorder(ink.border.composited(over: surface))
        glyph.contentTintColor = ink.secondary
        subagentsButton.contentTintColor = ink.secondary
        subagentsButton.hoverFill = ink.surfaceHover
        rebuild()
    }

    // MARK: - Public Methods

    func update(with reading: GitChangeMonitor.Reading) {
        lastReading = reading
        rebuild()
    }

    /// Promotes the ordinary branch card into the live run receipt shown in the same place.
    ///
    /// The checkout monitor continues feeding `update(with:)`, so file and line totals move
    /// independently of plan updates. A rising edge prepares one orb variant; repeated plan or
    /// diff readings do not restart its animation.
    func updateRunState(isActive: Bool, progress: RunProgress?) {
        if isActive, !isRunActive {
            orb.prepareForWorking(style: AppSettings.shared.workingOrbStyle)
        }
        isRunActive = isActive
        runProgress = isActive ? progress : nil
        rebuild()
    }

    /// Adds the session's child-agent receipt to the same top-right card as branch and diff.
    ///
    /// It is its own hit target: the rest of the card still opens Git Review, while this
    /// segment opens the Subagents tab in the display pane.
    func updateSubagents(workingCount: Int, doneCount: Int) {
        subagentCounts = (
            working: max(0, workingCount),
            done: max(0, doneCount)
        )
        rebuild()
    }

    func clear() {
        lastReading = nil
        isRunActive = false
        runProgress = nil
        subagentCounts = (working: 0, done: 0)
        orb.isHidden = true
        glyph.isHidden = false
        subagentsButton.isHidden = true
        isHidden = true
    }

    /// Binds the extension slot to the session on screen, or detaches it between sessions.
    ///
    /// Extension rows ride the card's own visibility: a pane with no checkout reading shows
    /// no card, so a bound slot on a hidden card renders nothing the user can see.
    func showSession(_ sessionID: String?) {
        if let sessionID {
            customizationHost?.updateTarget(.sessionCornerCard(sessionID: sessionID))
        } else {
            customizationHost?.deactivate()
        }
    }

    // MARK: - Layout

    /// Keeps the card in step with whatever the customization host just rendered into the
    /// slot: each row stretches to the card's width so a flexible spacer can hold name and
    /// state apart, and the bottom edge tracks the last row only while rows exist — with the
    /// slot empty the collapsed constraint reproduces the original single-line height exactly.
    override func layout() {
        let rows = extensionSlotStack.arrangedSubviews
        if rows.isEmpty {
            expandedBottomConstraint?.isActive = false
            collapsedBottomConstraint?.isActive = true
        } else {
            collapsedBottomConstraint?.isActive = false
            expandedBottomConstraint?.isActive = true
        }

        let tracked = slotRowWidthConstraints.compactMap { $0.firstItem as? NSView }
        if tracked != rows {
            NSLayoutConstraint.deactivate(slotRowWidthConstraints)
            slotRowWidthConstraints = rows.map {
                $0.widthAnchor.constraint(equalTo: extensionSlotStack.widthAnchor)
            }
            NSLayoutConstraint.activate(slotRowWidthConstraints)
        }
        super.layout()
    }

    // MARK: - Private Methods

    private func rebuild() {
        let text = Self.attributedText(
            for: lastReading,
            isRunActive: isRunActive,
            progress: runProgress,
            ink: ink,
            // The counters sit on the card, not on the backdrop the card floats over.
            diff: Design.Diff.on(WindowBackdrop.opaque(ink.surface))
        )
        let hasGitReceipt = text.length > 0
        let hasSubagents = subagentCounts.working + subagentCounts.done > 0
        guard hasGitReceipt || hasSubagents else {
            isHidden = true
            return
        }

        // Rebuilt rather than reassigned: a label measures itself at creation, and the helper
        // exists precisely because assigning attributed text afterwards does not re-measure.
        textLabel?.removeFromSuperview()
        if hasGitReceipt {
            let label = NSTextField.label(attributed: text)
            label.cell?.lineBreakMode = .byTruncatingMiddle
            textLabel = label
            stack.insertArrangedSubview(label, at: 2)
        } else {
            textLabel = nil
        }

        orb.isHidden = !isRunActive || !hasGitReceipt
        glyph.isHidden = isRunActive || !hasGitReceipt
        subagentsButton.isHidden = !hasSubagents
        if hasSubagents {
            let working = subagentCounts.working
            let done = subagentCounts.done
            let workingText = L10n.format("%lld working", Int64(working))
            let doneText = L10n.format("%lld done", Int64(done))
            subagentsButton.title = working > 0 ? "\(workingText) · \(doneText)" : doneText
            // A titled `ThemedButton` deliberately exposes its visible title to accessibility.
            // Put the destination in help instead of trying to replace that truthful title.
            subagentsButton.setAccessibilityHelp(L10n.string("Open Subagents"))
        }
        if hasGitReceipt {
            setAccessibilityRole(.button)
            setAccessibilityLabel(text.string)
            toolTip = L10n.string("Open Git Review (⇧⌘R)")
        } else {
            setAccessibilityRole(.group)
            setAccessibilityLabel(
                L10n.format("Subagents: %@", subagentsButton.title)
            )
            toolTip = nil
        }
        isHidden = false
    }

    /// The card's whole sentence. Idle, it is the branch and counters it has always shown.
    /// During a run, the plan position replaces the branch and the changed-file count joins the
    /// live line totals, matching the unit of work the orb describes.
    /// A clean checkout shows the branch alone; a detached head shows the counters alone;
    /// both absent is nothing to say, and the caller hides the card.
    private static func attributedText(
        for reading: GitChangeMonitor.Reading?,
        isRunActive: Bool,
        progress: RunProgress?,
        ink: Design.Ink,
        diff: Design.DiffInk
    ) -> NSAttributedString {
        let font = Design.Typography.numericDetail(weight: .medium)
        let text = NSMutableAttributedString()

        if isRunActive {
            text.append(NSAttributedString(
                string: progress?.label ?? "Working…",
                attributes: [
                    .font: font,
                    .foregroundColor: ink.label
                ]
            ))
        } else if let branch = reading?.branch {
            text.append(NSAttributedString(string: branch, attributes: [
                .font: font,
                .foregroundColor: ink.secondary
            ]))
        }

        if let reading, !reading.summary.isClean {
            if text.length > 0 {
                text.append(NSAttributedString(
                    string: isRunActive ? "  ·  " : "  ",
                    attributes: [
                        .font: font,
                        .foregroundColor: ink.tertiary
                    ]
                ))
            }
            if isRunActive {
                let noun = reading.summary.files == 1 ? "file" : "files"
                text.append(NSAttributedString(
                    string: "\(formatted(reading.summary.files)) \(noun) changed ",
                    attributes: [
                        .font: font,
                        .foregroundColor: ink.secondary
                    ]
                ))
            }
            text.append(NSAttributedString(string: "+\(formatted(reading.summary.added))", attributes: [
                .font: font,
                .foregroundColor: diff.added
            ]))
            text.append(NSAttributedString(string: " −\(formatted(reading.summary.removed))", attributes: [
                .font: font,
                .foregroundColor: diff.removed
            ]))
        }

        return text
    }

    /// Counts follow the user's locale: `8,349`, `8 349`, and their equivalents are the same
    /// number rendered in the notation the rest of the system uses.
    private static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        if textLabel != nil { onOpen?() }
    }

    @objc private func openSubagents() {
        onOpenSubagents?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        // The card is pinned to the pane's trailing edge, so opening a panel slides it out from
        // under a pointer that never moved and no exit is delivered — see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) { isHovered = false }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
