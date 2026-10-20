import AppKit

/// The native icon and title of a sidebar session row. The host cell owns selection,
/// activity, actions and extension resolution; this is the default content that an extension
/// may replace. Linux mounts this same stack for visible saved sessions.
final class ThemedSessionRowContentView: NSStackView {
    let nativeIdentityContent = NSView()
    let iconView = GlyphView()
    #if os(Linux)
    let titleLabel = NSTextField(labelWithString: "")
    #else
    let titleLabel = MorphingTitleLabel()
    #endif
    private(set) var accountChipView: NSImageView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String, animated: Bool = false) {
        #if os(Linux)
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        #else
        titleLabel.setStringValue(title, animated: animated)
        #endif
    }

    func setIcon(_ image: NSImage?) {
        guard iconView.image !== image else { return }
        iconView.image = image
    }

    /// The alternate-account mark rides the provider mark rather than taking another slot.
    /// Rows without one never create its image view or constraints.
    func accountChipViewForPresentation(size: CGFloat, cornerOverhang: CGFloat) -> NSImageView {
        if let accountChipView { return accountChipView }

        let chip = NSImageView()
        chip.imageScaling = .scaleProportionallyDown
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setAccessibilityIdentifier("sidebar.session.account")
        nativeIdentityContent.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: size),
            chip.heightAnchor.constraint(equalToConstant: size),
            chip.trailingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                           constant: cornerOverhang),
            chip.bottomAnchor.constraint(equalTo: iconView.bottomAnchor,
                                         constant: cornerOverhang)
        ])
        accountChipView = chip
        return chip
    }

    #if os(Linux)
    /// The diagnostic shell's fixed palette is supplied by its Design boundary. Mac rows
    /// continue to resolve live theme and selection ink from their table cell.
    func setSelection(_ selected: Bool, dormant: Bool = false, on ground: NSColor? = nil) {
        let face = ground ?? (selected ? Design.Surface.selectionFill : Design.Surface.background)
        let ink = Design.Text.on(face)
        titleLabel.textColor = dormant && !selected ? ink.secondary : ink.label
        iconView.tint = selected
            ? ink.label
            : (dormant ? ink.tertiary : ink.secondary)
        iconView.alphaValue = dormant && iconView.image?.isTemplate == false
            ? SidebarRowDefaults.dormantBrandAlpha : 1
    }
    #endif

    private func setup() {
        orientation = .horizontal
        alignment = .centerY
        spacing = SidebarRowDefaults.horizontalSpacing
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("sidebar.session.default-content")
        setContentHuggingPriority(SidebarRowDefaults.stretchableHugging, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.slot = NSSize(width: SidebarRowDefaults.iconSlotWidth, height: SidebarRowDefaults.iconSlotWidth)
        iconView.contrastGround = { [weak self] in self?.resolvedGround() ?? Design.Surface.background }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(true)
        iconView.setAccessibilityRole(.image)
        iconView.setAccessibilityIdentifier("sidebar.session.identity")

        nativeIdentityContent.translatesAutoresizingMaskIntoConstraints = false
        nativeIdentityContent.addSubview(iconView)
        nativeIdentityContent.setAccessibilityIdentifier("sidebar.session.identity.default-content")
        NSLayoutConstraint.activate([
            nativeIdentityContent.widthAnchor.constraint(
                equalToConstant: SidebarRowDefaults.iconSlotWidth),
            nativeIdentityContent.heightAnchor.constraint(
                equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.topAnchor.constraint(equalTo: nativeIdentityContent.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: nativeIdentityContent.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: nativeIdentityContent.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: nativeIdentityContent.trailingAnchor)
        ])

        #if os(Linux)
        titleLabel.font = Design.Typography.controlRegular()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        #else
        titleLabel.applyFont(.controlRegular)
        #endif
        titleLabel.setAccessibilityIdentifier("sidebar.session.title")
        titleLabel.setContentHuggingPriority(SidebarRowDefaults.stretchableHugging,
                                             for: .horizontal)

        addArrangedSubview(nativeIdentityContent)
        addArrangedSubview(titleLabel)
    }
}

#if os(Linux)
/// The portable bitmap host paints the same status silhouettes as the Mac row in its shared
/// constrained slot. Only a visible, non-idle session mounts this view; the host supplies the
/// provider's turn/blocker truth and the selected row's legible ink.
final class ThemedSessionActivityMark: NSView {
    enum State: Equatable { case loading, working, readyWithBackgroundWork, awaitingUser }

    private var state: State = .working
    private var selectedInk: NSColor?
    private var phase: CGFloat = 0
    var isWorking: Bool { state == .loading || state == .working }

    func updatePhase(_ phase: CGFloat) {
        self.phase = phase
    }

    func update(_ state: State, selectedInk: NSColor?, phase: CGFloat) {
        self.state = state
        self.selectedInk = selectedInk
        self.phase = phase
        setAccessibilityElement(true)
        setAccessibilityRole(state == .loading || state == .working
            ? .progressIndicator : .staticText)
        let label = switch state {
        case .loading: "Loading session"
        case .working: "Session working"
        case .readyWithBackgroundWork: "Ready for input; background work running"
        case .awaitingUser: "Session waiting for an answer"
        }
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .readyWithBackgroundWork:
            let side = SidebarRowDefaults.sessionBackgroundDotSize
            let dot = NSBezierPath(ovalIn: NSRect(
                x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                width: side, height: side))
            (selectedInk ?? Design.Surface.accent).setFill()
            dot.fill()
        case .awaitingUser:
            let side: CGFloat = 6
            let dot = NSBezierPath(ovalIn: NSRect(
                x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                width: side, height: side))
            (selectedInk ?? Design.Status.warning).setFill()
            dot.fill()
        case .loading, .working:
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2 - 1.5
            let start = -phase * 2 * CGFloat.pi
            let sweep = 0.72 * 2 * CGFloat.pi
            let arc = NSBezierPath()
            for step in 0...24 {
                let angle = start + sweep * CGFloat(step) / 24
                let point = NSPoint(x: center.x + radius * cos(angle),
                                    y: center.y + radius * sin(angle))
                if step == 0 { arc.move(to: point) } else { arc.line(to: point) }
            }
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            (selectedInk ?? Design.Surface.accent).setStroke()
            arc.stroke()
        }
    }
}
#endif
