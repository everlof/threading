import AppKit

/// The native visual shell of a project navigator row. A table cell or Linux navigator owns
/// identity, selection, commands, hover timing and extension resolution; this view owns the
/// visible icon, title, optional checkout path, count and trailing controls. Reused cells only
/// materialize their optional path and count labels when one is actually shown.
final class ThemedProjectRowView: NSView {
    let nativeContent = NSView()
    let afterTitleSlot = NSStackView()
    let iconView = NSImageView()
    #if os(Linux)
    let titleLabel = NSTextField(labelWithString: "")
    private var pathLabel: NSTextField?
    #else
    let titleLabel = MorphingTitleLabel()
    private var pathLabel: MorphingTitleLabel?
    #endif
    private var pathMinimumWidth: NSLayoutConstraint?
    private lazy var nativeStack = NSStackView(views: [iconView, titleLabel])
    private lazy var contentStack = NSStackView(views: [nativeContent, afterTitleSlot])
    private let trailingSlot = NSView()
    private let hoverControls = NSStackView()
    let createButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.createSymbol,
        accessibility: L10n.string("New chat or terminal"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    let actionButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Project actions"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )

    private var countLabel: NSTextField?
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var trailingWidthConstraint: NSLayoutConstraint?
    private var showsHoverControls = false
    private var hoverControlsVisible = false
    private var hasCount = false
    private var isSelected = false
    private var isQuietHeading = false

    var onCreatePress: ((NSView) -> Void)?
    var onActionPress: ((NSView) -> Void)?
    var countLabelIsMaterialized: Bool { countLabel != nil }
    var title: String { titleLabel.stringValue }
    var pathLabelView: NSView? { pathLabel }
    var trailingSlotView: NSView { trailingSlot }
    var isIdentityHidden: Bool { iconView.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Called before an extension container adopts nativeContent. The ordinary Linux row keeps
    /// the default mounting and never calls this method.
    func prepareForExternalContent() {
        contentStack.removeArrangedSubview(nativeContent)
        nativeContent.removeFromSuperview()
    }

    /// The Mac extension host installs its replacement container over nativeContent. The
    /// Linux navigator leaves nativeContent in place, so both render the same default row.
    func installContentContainer(_ container: NSView) {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(SidebarRowDefaults.stretchableHugging, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.insertArrangedSubview(container, at: 0)
    }

    /// Host-owned status marks sit after default/replacement content but before the extension
    /// slot. They stay visible if an extension replaces the native title and icon.
    func insertHostStatusMark(_ view: NSView) {
        let index = contentStack.arrangedSubviews.firstIndex(of: afterTitleSlot)
            ?? contentStack.arrangedSubviews.count
        contentStack.insertArrangedSubview(view, at: index)
    }

    func configure(
        _ presentation: NavigatorProjectRowPresentation,
        path: String? = nil,
        icon: NSImage? = nil,
        count: Int = 0,
        moreSymbol: String? = SidebarRowDefaults.actionSymbol,
        moreAccessibility: String = "Project actions",
        showsCreate: Bool = true
    ) {
        applyPresentation(presentation, path: path)
        setTitle(presentation.title, animated: false)
        setIcon(icon, visible: presentation.showsIdentityMark)
        setHoverControls(moreSymbol: moreSymbol,
                         moreAccessibility: moreAccessibility, showsCreate: showsCreate)
        setCount(count)
        setHoverControlsVisible(false, animated: false)
        applyColors()
    }

    func applyPresentation(_ presentation: NavigatorProjectRowPresentation, path: String? = nil) {
        isQuietHeading = presentation.isQuietHeading
        setTitleFont(presentation.titleRole)
        setPath(path, displayedAs: presentation.secondaryPath)
        applyColors()
    }

    func setTitle(_ title: String, animated: Bool) {
        #if os(Linux)
        titleLabel.stringValue = title
        #else
        titleLabel.setStringValue(title, animated: animated)
        #endif
    }

    func setIcon(_ image: NSImage?, visible: Bool) {
        iconView.image = image
        iconView.isHidden = !visible
    }

    func setSelection(_ selected: Bool) {
        isSelected = selected
        applyColors()
    }

    func setHoverControlsVisible(_ visible: Bool, animated: Bool) {
        guard showsHoverControls else { return }
        hoverControlsVisible = visible
        if visible {
            if !createButton.isHidden { createButton.materializeGlyphIfNeeded() }
            if !actionButton.isHidden { actionButton.materializeGlyphIfNeeded() }
        }
        guard animated else {
            hoverControls.alphaValue = visible ? 1 : 0
            countLabel?.alphaValue = visible ? 0 : 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            hoverControls.animator().alphaValue = visible ? 1 : 0
            countLabel?.animator().alphaValue = visible ? 0 : 1
        }
    }

    func applySidebarDensity(leading: CGFloat, trailing: CGFloat) {
        leadingConstraint?.constant = leading
        trailingConstraint?.constant = -trailingSlotInset(for: trailing)
    }

    func refreshColors() { applyColors() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarRowDefaults.iconSize, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityIdentifier("sidebar.project.identity")

        titleLabel.setContentHuggingPriority(SidebarRowDefaults.stretchableHugging, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("sidebar.project.title")
        #if os(Linux)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        #else
        titleLabel.setTextColor { [weak self] in self?.titleColor() ?? Design.Text.label }
        #endif

        nativeStack.orientation = .horizontal
        nativeStack.alignment = .centerY
        nativeStack.spacing = SidebarRowDefaults.horizontalSpacing
        nativeStack.translatesAutoresizingMaskIntoConstraints = false
        nativeContent.translatesAutoresizingMaskIntoConstraints = false
        nativeContent.addSubview(nativeStack)
        NSLayoutConstraint.activate([
            nativeStack.topAnchor.constraint(equalTo: nativeContent.topAnchor),
            nativeStack.bottomAnchor.constraint(equalTo: nativeContent.bottomAnchor),
            nativeStack.leadingAnchor.constraint(equalTo: nativeContent.leadingAnchor),
            nativeStack.trailingAnchor.constraint(equalTo: nativeContent.trailingAnchor)
        ])
        nativeContent.setAccessibilityIdentifier("sidebar.project.default-content")
        nativeContent.setContentHuggingPriority(SidebarRowDefaults.stretchableHugging, for: .horizontal)
        nativeContent.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        afterTitleSlot.orientation = .horizontal
        afterTitleSlot.alignment = .centerY
        afterTitleSlot.spacing = Design.Spacing.tight
        afterTitleSlot.isHidden = true
        afterTitleSlot.setAccessibilityIdentifier("sidebar.project.slot.after-title")
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = SidebarRowDefaults.horizontalSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        setupTrailingSlot()
        addSubview(trailingSlot)
        let leading = contentStack.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: SidebarRowDefaults.leadingInset)
        let trailing = trailingSlot.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -trailingSlotInset(for: SidebarRowDefaults.trailingInset))
        leadingConstraint = leading
        trailingConstraint = trailing
        NSLayoutConstraint.activate([
            leading,
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingSlot.leadingAnchor,
                constant: -SidebarRowDefaults.horizontalSpacing),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing,
            trailingSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth)
        ])
    }

    private func setTitleFont(_ role: NavigatorProjectRowPresentation.TitleRole) {
        #if os(Linux)
        titleLabel.font = ProjectRowLinuxTypography.titleFont(for: role)
        #else
        switch role {
        case .emphasizedBody: titleLabel.applyFont(.emphasizedBody)
        case .caption: titleLabel.applyFont(.caption)
        }
        #endif
    }

    private func setPath(_ path: String?, displayedAs text: String?) {
        guard let path else {
            pathMinimumWidth?.isActive = false
            pathLabel?.isHidden = true
            titleLabel.setContentHuggingPriority(SidebarRowDefaults.stretchableHugging, for: .horizontal)
            titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            return
        }
        guard let text else { preconditionFailure("Checkout presentation must provide its path text") }
        #if os(Linux)
        let label: NSTextField
        #else
        let label: MorphingTitleLabel
        #endif
        if let pathLabel {
            label = pathLabel
        } else {
            #if os(Linux)
            label = NSTextField(labelWithString: "")
            label.font = ProjectRowLinuxTypography.pathFont
            label.lineBreakMode = .byTruncatingTail
            #else
            label = MorphingTitleLabel()
            label.applyFont(.body)
            label.setTextColor { [weak self] in self?.pathColor() ?? Design.Text.tertiary }
            #endif
            label.setAccessibilityIdentifier("sidebar.project.worktree-path")
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            nativeStack.addArrangedSubview(label)
            pathLabel = label
            pathMinimumWidth = label.widthAnchor.constraint(
                greaterThanOrEqualTo: nativeStack.widthAnchor,
                multiplier: SidebarRowDefaults.worktreePathMinimumFraction)
        }
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        #if os(Linux)
        label.stringValue = text
        #else
        label.setStringValue(text, animated: false)
        #endif
        label.toolTip = path
        label.isHidden = false
        pathMinimumWidth?.isActive = true
    }

    private func setupTrailingSlot() {
        actionButton.presentsMenu = true
        actionButton.onPress = { [weak self] in
            guard let self else { return }
            self.onActionPress?(self.actionButton)
        }
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.presentsMenu = true
        createButton.onPress = { [weak self] in
            guard let self else { return }
            self.onCreatePress?(self.createButton)
        }
        createButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.setAccessibilityIdentifier("sidebar.project.create")

        hoverControls.orientation = .horizontal
        hoverControls.spacing = SidebarRowDefaults.hoverButtonSpacing
        hoverControls.alignment = .centerY
        hoverControls.alphaValue = 0
        hoverControls.translatesAutoresizingMaskIntoConstraints = false
        hoverControls.addArrangedSubview(createButton)
        hoverControls.addArrangedSubview(actionButton)
        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.setAccessibilityIdentifier("sidebar.project.trailing")
        hoverControls.setAccessibilityIdentifier("sidebar.project.actions")
        trailingSlot.addSubview(hoverControls)
        let width = trailingSlot.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize)
        trailingWidthConstraint = width
        NSLayoutConstraint.activate([
            width,
            trailingSlot.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize),
            hoverControls.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
            hoverControls.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor)
        ])
    }

    func setHoverControls(moreSymbol: String?, moreAccessibility: String, showsCreate: Bool) {
        createButton.isHidden = !showsCreate
        actionButton.isHidden = moreSymbol == nil
        if let moreSymbol { actionButton.setSymbol(moreSymbol, accessibility: moreAccessibility) }
        showsHoverControls = moreSymbol != nil || showsCreate
        trailingWidthConstraint?.constant = showsCreate
            ? SidebarRowDefaults.projectTrailingSlotWidth : SidebarRowDefaults.trailingSlotSize
        updateTrailingSlotVisibility()
        if !showsHoverControls {
            hoverControls.alphaValue = 0
            countLabel?.alphaValue = 1
        }
    }

    func setCount(_ count: Int) {
        hasCount = count > 0
        if count > 0 {
            let label = countLabelForPresentation()
            label.stringValue = String(count)
            label.isHidden = false
            label.alphaValue = hoverControlsVisible && showsHoverControls ? 0 : 1
        } else if let countLabel {
            countLabel.stringValue = ""
            countLabel.isHidden = true
        }
        updateTrailingSlotVisibility()
    }

    private func countLabelForPresentation() -> NSTextField {
        if let countLabel { return countLabel }
        let label = NSTextField(labelWithString: "")
        #if os(Linux)
        label.font = ProjectRowLinuxTypography.countFont
        #else
        label.applyFont(.numericDetail())
        #endif
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        // The slot fixes both horizontal edges. Its count label must yield its intrinsic width
        // to that slot, especially when a large count needs truncation.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("sidebar.project.count")
        trailingSlot.addSubview(label, positioned: .below, relativeTo: hoverControls)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: trailingSlot.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor,
                                            constant: -actionButton.opticalHorizontalInset),
            label.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor)
        ])
        countLabel = label
        return label
    }

    private func updateTrailingSlotVisibility() {
        trailingSlot.isHidden = !showsHoverControls && !hasCount
    }

    private func titleColor() -> NSColor {
        if isSelected { return Design.Text.selected }
        return isQuietHeading ? Design.Text.secondary : Design.Text.label
    }

    private func pathColor() -> NSColor {
        isSelected ? Design.Ink.selection.secondary : Design.Text.tertiary
    }

    private func applyColors() {
        #if os(Linux)
        titleLabel.textColor = titleColor()
        pathLabel?.textColor = pathColor()
        #else
        titleLabel.refreshTextColor()
        pathLabel?.refreshTextColor()
        #endif
        let ground: InkSource? = isSelected ? .selection : nil
        createButton.hostGround = ground
        actionButton.hostGround = ground
        countLabel?.textColor = isSelected
            ? Design.Text.selected.withAlphaComponent(SidebarRowDefaults.secondaryTextAlpha)
            : Design.Text.secondary
        iconView.contentTintColor = isSelected ? Design.Text.selected : Design.Text.secondary
    }

    private func trailingSlotInset(for gutter: CGFloat) -> CGFloat {
        max(0, gutter - actionButton.opticalHorizontalInset)
    }
}
