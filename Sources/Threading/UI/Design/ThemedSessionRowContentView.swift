import AppKit

/// The native icon and title of a sidebar session row. The host cell owns selection,
/// activity, actions and extension resolution; this is the default content that an extension
/// may replace. Linux mounts this same stack for visible saved sessions.
final class ThemedSessionRowContentView: NSStackView {
    let nativeIdentityContent = NSView()
    let iconView = NSImageView()
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
    func setSelection(_ selected: Bool, dormant: Bool = false) {
        titleLabel.textColor = selected
            ? Design.Text.selected
            : (dormant ? Design.Text.secondary : Design.Text.label)
        iconView.contentTintColor = selected
            ? Design.Ink.selection.label
            : (dormant ? Design.Text.tertiary : Design.Text.secondary)
        iconView.alphaValue = dormant ? 0.6 : 1
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

        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarRowDefaults.iconSize, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
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
