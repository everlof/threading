import AppKit

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
/// The pane's surfaces answer "what is the agent saying"; this answers "what has it done to
/// the checkout" without asking the conversation to run a tool. It is deliberately a summary —
/// It remains a summary because the full answer already has a surface, the Git Review tab,
/// which is exactly where a click lands.
final class GitStatusOverlayView: BackdropOverlay {

    // MARK: - Properties

    /// Called on click; the container routes it to the review tab.
    var onOpen: (() -> Void)?

    private let stack = NSStackView()
    private let glyph = NSImageView()
    private let orb = WorkingOrbView()
    private var textLabel: NSTextField?

    /// Held so a backdrop change can rebuild the label, which carries its colours inside an
    /// attributed string and cannot be re-inked in place.
    private var lastReading: GitChangeMonitor.Reading?
    private var isRunActive = false
    private var runProgress: RunProgress?

    /// Lifts the card's *contents* to full strength under the pointer. The surface behind them
    /// does not move: it is what keeps the pane's text out of the card.
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            stack.alphaValue = isHovered ? 1 : GitStatusOverlayDefaults.restingContentAlpha
        }
    }

    // MARK: - Initialization

    init() {
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
        stack.spacing = Design.Spacing.small
        stack.alphaValue = GitStatusOverlayDefaults.restingContentAlpha
        stack.translatesAutoresizingMaskIntoConstraints = false
        orb.isHidden = true
        stack.addArrangedSubview(orb)
        stack.addArrangedSubview(glyph)
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: GitStatusOverlayDefaults.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: GitStatusOverlayDefaults.maxWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
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

    func clear() {
        lastReading = nil
        isRunActive = false
        runProgress = nil
        orb.isHidden = true
        glyph.isHidden = false
        isHidden = true
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
        guard text.length > 0 else {
            isHidden = true
            return
        }

        // Rebuilt rather than reassigned: a label measures itself at creation, and the helper
        // exists precisely because assigning attributed text afterwards does not re-measure.
        textLabel?.removeFromSuperview()
        let label = NSTextField.label(attributed: text)
        label.cell?.lineBreakMode = .byTruncatingMiddle
        textLabel = label
        stack.addArrangedSubview(label)

        orb.isHidden = !isRunActive
        glyph.isHidden = isRunActive
        setAccessibilityLabel(text.string)
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
        onOpen?()
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
