import AppKit

/// The native icon and title of a standalone terminal row. Its host cell owns selection,
/// foreground-command status, actions and row density. Linux mounts this content for visible
/// terminals with the same layout and ink roles.
final class ThemedTerminalRowContentView: NSStackView {
    let iconView = NSImageView()
    #if os(Linux)
    let titleLabel = NSTextField(labelWithString: "")
    #else
    let titleLabel = MorphingTitleLabel()
    #endif

    private var isSelected = false
    private var isRunning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String, animated: Bool = false) {
        #if os(Linux)
        titleLabel.stringValue = title
        #else
        titleLabel.setStringValue(title, animated: animated)
        #endif
    }

    func setIcon(_ image: NSImage?) {
        guard iconView.image !== image else { return }
        iconView.image = image
    }

    func setInk(selected: Bool, running: Bool) {
        isSelected = selected
        isRunning = running
        #if os(Linux)
        titleLabel.textColor = resolvedInk
        #else
        titleLabel.refreshTextColor()
        #endif
        iconView.contentTintColor = resolvedInk
    }

    private var resolvedInk: NSColor {
        if isSelected { return Design.Text.selected }
        return isRunning ? Design.Text.label : Design.Text.secondary
    }

    private func setup() {
        orientation = .horizontal
        alignment = .centerY
        spacing = SidebarRowDefaults.horizontalSpacing
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("sidebar.terminal.default-content")
        setContentHuggingPriority(SidebarRowDefaults.stretchableHugging, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarRowDefaults.iconSize, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityIdentifier("sidebar.terminal.identity")
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth)
        ])

        #if os(Linux)
        titleLabel.font = Design.Typography.controlRegular()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        #else
        titleLabel.applyFont(.controlRegular)
        titleLabel.setTextColor { [weak self] in self?.resolvedInk ?? Design.Text.label }
        #endif
        titleLabel.setContentHuggingPriority(SidebarRowDefaults.stretchableHugging,
                                             for: .horizontal)
        titleLabel.setAccessibilityIdentifier("sidebar.terminal.title")

        addArrangedSubview(iconView)
        addArrangedSubview(titleLabel)
        setInk(selected: false, running: false)
    }
}
