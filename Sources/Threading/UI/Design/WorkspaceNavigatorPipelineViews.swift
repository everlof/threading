import AppKit
import ThreadingExtensionKit

/// The persistent host-owned search band above a pipeline navigator's virtualized output.
///
/// The field survives structural re-evaluation so filtering on every keystroke does not replace
/// the field editor, caret, or first responder. Extensions supply only already-localized copy.
@MainActor
final class WorkspaceNavigatorPipelineSearchBandView:
    NSView,
    ThemedComponent,
    NSTextFieldDelegate
{
    private let searchField = ThemedSearchField()
    private let presentedHeight: CGFloat
    private var heightConstraint: NSLayoutConstraint?

    var onQueryChange: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        presentedHeight = Design.Size.fieldHeight + Design.Spacing.small * 2
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("workspace.navigator.search-band")

        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("workspace.navigator.search")
        addSubview(searchField)

        let heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            searchField.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.medium
            )
        ])
        setPresented(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        placeholder: String,
        accessibilityLabel: String,
        query: String
    ) {
        searchField.placeholderString = placeholder
        searchField.setAccessibilityLabel(accessibilityLabel)
        if searchField.stringValue != query {
            searchField.stringValue = query
            searchField.currentEditor()?.string = query
        }
    }

    func setPresented(_ presented: Bool) {
        heightConstraint?.constant = presented ? presentedHeight : 0
        searchField.isHidden = !presented
        setAccessibilityElement(false)
    }

    var query: String { searchField.stringValue }

    var searchFieldForTesting: ThemedSearchField { searchField }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              !searchField.stringValue.isEmpty else { return false }
        searchField.clear()
        return true
    }
}

/// Host-owned composition around a pipeline's virtualized collection.
///
/// The optional notice is outside the collection so truncation can never create a selectable
/// pseudo-session or make the collection exceed its declared item ceiling.
@MainActor
final class WorkspaceNavigatorPipelineResultsView: NSView, ThemedComponent {
    private let content: NSView
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var contentBottomConstraint: NSLayoutConstraint?
    private var noticeConstraints: [NSLayoutConstraint] = []
    private var emptyPlaceholder: WorkspaceNavigatorPipelinePlaceholderView?

    init(content: NSView, overflowText: String?) {
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("workspace.navigator.pipeline-results")

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        notice.applyFont(.detail())
        notice.textColor = Design.Text.secondary
        notice.alignment = .center
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.setAccessibilityIdentifier("workspace.navigator.pipeline-overflow")
        addSubview(notice)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            notice.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.medium
            ),
            notice.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.medium
            ),
        ])
        setOverflowText(overflowText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOverflowText(_ text: String?) {
        contentBottomConstraint?.isActive = false
        NSLayoutConstraint.deactivate(noticeConstraints)
        noticeConstraints.removeAll(keepingCapacity: true)
        notice.stringValue = text ?? ""
        notice.isHidden = text == nil
        if text == nil {
            let constraint = content.bottomAnchor.constraint(equalTo: bottomAnchor)
            contentBottomConstraint = constraint
            constraint.isActive = true
        } else {
            let contentBottom = content.bottomAnchor.constraint(equalTo: notice.topAnchor)
            contentBottomConstraint = contentBottom
            noticeConstraints = [
                notice.bottomAnchor.constraint(
                    equalTo: bottomAnchor,
                    constant: -Design.Spacing.small
                )
            ]
            NSLayoutConstraint.activate([contentBottom] + noticeConstraints)
        }
    }

    /// Keeps the virtual table mounted while a query has no matches. Its selection, scroll
    /// anchor, reuse pool, and the search field above it therefore survive an empty round-trip.
    func setEmptyState(title: String?, detail: String?) {
        emptyPlaceholder?.removeFromSuperview()
        emptyPlaceholder = nil
        content.isHidden = title != nil
        guard let title else { return }
        let placeholder = WorkspaceNavigatorPipelinePlaceholderView(
            title: title,
            detail: detail
        )
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        emptyPlaceholder = placeholder
    }
}

/// A quiet, noninteractive answer for an empty or temporarily unavailable pipeline.
@MainActor
final class WorkspaceNavigatorPipelinePlaceholderView: NSView, ThemedComponent {
    init(title: String, detail: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("workspace.navigator.pipeline-placeholder")

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.applyFont(.emphasizedBody)
        titleLabel.textColor = Design.Text.secondary
        titleLabel.alignment = .center
        titleLabel.setAccessibilityIdentifier("workspace.navigator.pipeline-placeholder.title")

        var labels: [NSView] = [titleLabel]
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.applyFont(.detail())
            detailLabel.textColor = Design.Text.tertiary
            detailLabel.alignment = .center
            detailLabel.setAccessibilityIdentifier(
                "workspace.navigator.pipeline-placeholder.detail"
            )
            labels.append(detailLabel)
        }
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Placeholder.line
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.pane
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A visible pipeline row built only after the table asks for that row.
///
/// It is deliberately a design-system component: the pipeline chooses semantic roles while this
/// view owns concrete labels, images, status ink, spinner behavior, spacing, and accessibility.
@MainActor
final class WorkspaceNavigatorPipelineTemplateView: NSView, ThemedComponent {
    typealias ImageResolver = (WorkspaceNavigatorRealizedImage) -> NSImage?
    typealias IntentHandler = (ExtensionWorkspaceNavigatorIntent) -> Void

    private var intentButtons: [ThemedIconButton] = []
    private var keyboardFocusedIntentButtons = Set<ObjectIdentifier>()
    private var intentControlsHovered = false
    private var intentControlsPresented = false

    init(
        node: WorkspaceNavigatorRealizedTemplateNode,
        imageResolver: @escaping ImageResolver,
        onIntent: @escaping IntentHandler = { _ in }
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("workspace.navigator.pipeline-template")

        let content = makeView(
            for: node,
            parentAxis: nil,
            imageResolver: imageResolver,
            onIntent: onIntent
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        var constraints = [
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
        ]
        switch node {
        case .stack:
            // Stacks own layout along the whole row. This is what gives a declared flexible
            // spacer room to separate its siblings.
            constraints.append(content.trailingAnchor.constraint(equalTo: trailingAnchor))
        default:
            // A scalar root keeps its semantic size. Pinning both horizontal edges made an
            // image-only template simultaneously demand its declared square and the row width.
            constraints.append(content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        setIntentControlsPresented(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        keyboardFocusedIntentButtons.removeAll()
        intentControlsHovered = false
        updateIntentControlsPresentation()
    }

    /// Resting rows reserve their action geometry and keep the controls in keyboard and
    /// accessibility traversal. `hitTest(_:)` alone refuses pointer presses until the row host
    /// reveals them, so an invisible target cannot steal the row's ordinary click.
    func setIntentControlsPresented(_ presented: Bool) {
        intentControlsHovered = presented
        updateIntentControlsPresentation()
    }

    private func updateIntentControlsPresentation() {
        let presented = intentControlsHovered || !keyboardFocusedIntentButtons.isEmpty
        intentControlsPresented = presented
        for button in intentButtons {
            if presented { button.materializeGlyphIfNeeded() }
            button.alphaValue = presented ? 1 : 0
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard !intentControlsPresented,
              let target,
              intentButtons.contains(where: { target === $0 || target.isDescendant(of: $0) })
        else { return target }

        // Returning nil lets the owning collection row receive the ordinary activation gesture.
        // The button remains enabled, focusable and exposed to accessibility without a pointer.
        return nil
    }

    /// One stable list-row height derived from the declaration, not from realized subject data.
    /// Conditional content reserves its possible space so rows never jump as facts change.
    static func rowHeight(
        for template: ExtensionWorkspaceNavigatorTemplateNode
    ) -> CGFloat {
        max(
            SidebarDefaults.projectCompactRowHeight,
            contentHeight(for: template) + Design.Spacing.small * 2
        )
    }

    private func makeView(
        for node: WorkspaceNavigatorRealizedTemplateNode,
        parentAxis: ExtensionAxis?,
        imageResolver: ImageResolver,
        onIntent: @escaping IntentHandler
    ) -> NSView {
        switch node {
        case let .text(text, role):
            return makeText(text, role: role)
        case let .image(image, role, accessibilityLabel):
            return makeImage(
                image,
                role: role,
                accessibilityLabel: accessibilityLabel,
                imageResolver: imageResolver
            )
        case let .status(text, role):
            let label = NSTextField(labelWithString: text)
            label.applyFont(.control)
            label.textColor = statusColor(for: role)
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityIdentifier("workspace.navigator.pipeline-status")
            return label
        case let .activityIndicator(accessibilityLabel):
            let spinner = ThemedSpinner()
            spinner.isAnimating = true
            spinner.setAccessibilityLabel(accessibilityLabel)
            spinner.setAccessibilityIdentifier("workspace.navigator.pipeline-activity")
            return spinner
        case let .intent(intent):
            let button = ThemedIconButton(
                symbolName: intent.symbolName,
                accessibility: intent.accessibilityLabel,
                target: .inline,
                glyphMaterialization: .deferred
            )
            button.toolTip = intent.accessibilityLabel
            button.setAccessibilityIdentifier(
                "workspace.navigator.intent.\(intent.rawValue)"
            )
            button.onPress = { onIntent(intent) }
            let buttonIdentifier = ObjectIdentifier(button)
            button.onKeyboardFocusChange = { [weak self] hasFocus in
                guard let self else { return }
                if hasFocus {
                    self.keyboardFocusedIntentButtons.insert(buttonIdentifier)
                } else {
                    self.keyboardFocusedIntentButtons.remove(buttonIdentifier)
                }
                self.updateIntentControlsPresentation()
            }
            intentButtons.append(button)
            return button
        case .divider:
            return SeparatorView(parentAxis == .horizontal ? .vertical : .horizontal)
        case let .spacer(spacing):
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            let value = spacingValue(spacing)
            switch parentAxis {
            case .horizontal:
                spacer.widthAnchor.constraint(equalToConstant: value).isActive = true
            case .vertical:
                spacer.heightAnchor.constraint(equalToConstant: value).isActive = true
            case nil:
                spacer.widthAnchor.constraint(equalToConstant: value).isActive = true
                spacer.heightAnchor.constraint(equalToConstant: value).isActive = true
            }
            return spacer
        case .flexibleSpacer:
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            if parentAxis != .vertical {
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            if parentAxis != .horizontal {
                spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
                spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            }
            return spacer
        case let .stack(axis, spacing, children):
            let views = children.map {
                makeView(
                    for: $0,
                    parentAxis: axis,
                    imageResolver: imageResolver,
                    onIntent: onIntent
                )
            }
            let stack = NSStackView(views: views)
            stack.orientation = axis == .horizontal ? .horizontal : .vertical
            stack.alignment = axis == .horizontal ? .centerY : .leading
            stack.spacing = spacingValue(spacing)
            for (child, view) in zip(children, views) where child.isDivider {
                if axis == .horizontal {
                    view.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
                } else {
                    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
            if axis == .vertical {
                for view in views {
                    view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
                }
            }
            return stack
        }
    }

    private func makeText(_ text: String, role: ExtensionTextRole) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = switch role {
        case .detail, .compactDetail: Design.Text.secondary
        default: Design.Text.label
        }
        label.applyFont(fontRole(for: role))
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("workspace.navigator.pipeline-text.\(role.rawValue)")
        return label
    }

    private func makeImage(
        _ image: WorkspaceNavigatorRealizedImage,
        role: ExtensionImageRole,
        accessibilityLabel: String?,
        imageResolver: ImageResolver
    ) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = imageResolver(image)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let side = imageSide(for: role)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: side),
            imageView.heightAnchor.constraint(equalToConstant: side)
        ])
        if let accessibilityLabel {
            imageView.setAccessibilityLabel(accessibilityLabel)
        } else {
            imageView.setAccessibilityElement(false)
        }
        imageView.setAccessibilityIdentifier(
            "workspace.navigator.pipeline-image.\(role.rawValue)"
        )
        return imageView
    }

    private static func contentHeight(
        for node: ExtensionWorkspaceNavigatorTemplateNode
    ) -> CGFloat {
        switch node {
        case let .text(_, role):
            return ceil(font(for: role).boundingRectForFont.height)
        case let .image(_, role, _):
            return imageSide(for: role)
        case .status:
            return ceil(Design.Typography.control().boundingRectForFont.height)
        case .activityIndicator:
            return Design.Size.extensionIconImage
        case .intent:
            return Design.Size.inlineButtonTarget
        case let .conditional(_, content):
            return contentHeight(for: content)
        case .divider:
            return Design.Radius.border
        case let .spacer(spacing):
            return spacingValue(spacing)
        case .flexibleSpacer:
            return 0
        case let .stack(axis, spacing, children):
            guard !children.isEmpty else { return 0 }
            let heights = children.map(contentHeight)
            if axis == .horizontal { return heights.max() ?? 0 }
            return heights.reduce(0, +)
                + CGFloat(max(0, children.count - 1)) * spacingValue(spacing)
        }
    }

    private static func font(for role: ExtensionTextRole) -> NSFont {
        switch role {
        case .heading: Design.Typography.heading()
        case .body: Design.Typography.body()
        case .detail, .compactDetail: Design.Typography.detail()
        case .code: Design.Typography.code()
        case .compactBody: Design.Typography.control()
        }
    }

    private func fontRole(for role: ExtensionTextRole) -> Design.FontRole {
        switch role {
        case .heading: .heading
        case .body: .body
        case .detail, .compactDetail: .detail()
        case .code: .code()
        case .compactBody: .control
        }
    }

    private func statusColor(for role: ExtensionStatusRole) -> NSColor {
        switch role {
        case .neutral: Design.Text.secondary
        case .positive: Design.Status.positive
        case .warning: Design.Status.warning
        case .negative: Design.Status.negative
        }
    }

    private static func imageSide(for role: ExtensionImageRole) -> CGFloat {
        switch role {
        case .identity: Design.Size.extensionIdentityImage
        case .icon: Design.Size.extensionIconImage
        case .decoration: Design.Size.extensionDecorationImage
        // A navigator's vocabulary is `ExtensionImageRole.inline`, so a fill never reaches
        // here; sized as a decoration rather than trapped, because a validated document is
        // not the place to crash.
        case .backdrop: Design.Size.extensionDecorationImage
        }
    }

    private static func spacingValue(_ spacing: ExtensionSpacing) -> CGFloat {
        switch spacing {
        case .none: 0
        case .tight: Design.Spacing.tight
        case .small: Design.Spacing.small
        case .medium: Design.Spacing.medium
        case .large: Design.Spacing.large
        }
    }

    private func imageSide(for role: ExtensionImageRole) -> CGFloat {
        Self.imageSide(for: role)
    }

    private func spacingValue(_ spacing: ExtensionSpacing) -> CGFloat {
        Self.spacingValue(spacing)
    }
}

private extension ExtensionWorkspaceNavigatorIntent {
    var symbolName: String {
        switch self {
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .archive: "archivebox"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .pin: L10n.string("Pin")
        case .unpin: L10n.string("Unpin")
        case .archive: L10n.string("Archive")
        }
    }
}

private extension WorkspaceNavigatorRealizedTemplateNode {
    var isDivider: Bool {
        if case .divider = self { return true }
        return false
    }
}
