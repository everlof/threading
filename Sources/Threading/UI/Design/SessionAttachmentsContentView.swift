import AppKit

/// The attachment count and filter share one baseline, even when their fonts differ.
/// `NSStackView` stretches the two to one cross-axis frame on macOS, which raises the caption.
/// The host supplies its filter control; this row owns the same alignment on both platforms.
final class SessionAttachmentHeaderRow: NSView {
    private let count: NSTextField
    private let filter: NSView
    private var filterShownConstraints: [NSLayoutConstraint] = []
    private var filterHiddenConstraints: [NSLayoutConstraint] = []

    init(count: NSTextField, filter: NSView, spacing: CGFloat) {
        self.count = count
        self.filter = filter
        super.init(frame: .zero)

        count.translatesAutoresizingMaskIntoConstraints = false
        filter.translatesAutoresizingMaskIntoConstraints = false
        // The count absorbs horizontal slack; requiring its natural width would push the pane's
        // split divider back after a drag, even though Auto Layout reports no broken constraint.
        count.setContentHuggingPriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .vertical)
        addSubview(count)
        addSubview(filter)
        setContentHuggingPriority(.required, for: .vertical)

        count.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        filterShownConstraints = [
            count.trailingAnchor.constraint(equalTo: filter.leadingAnchor, constant: -spacing),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor),
            filter.topAnchor.constraint(equalTo: topAnchor),
            filter.bottomAnchor.constraint(equalTo: bottomAnchor),
            count.firstBaselineAnchor.constraint(equalTo: filter.firstBaselineAnchor),
            count.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            count.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ]
        filterHiddenConstraints = [
            count.trailingAnchor.constraint(equalTo: trailingAnchor),
            count.topAnchor.constraint(equalTo: topAnchor),
            count.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(filterShownConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: filter.isHidden
                ? count.intrinsicContentSize.height
                : filter.intrinsicContentSize.height
        )
    }

    func setFilterHidden(_ hidden: Bool) {
        guard filter.isHidden != hidden else { return }
        NSLayoutConstraint.deactivate(hidden ? filterShownConstraints : filterHiddenConstraints)
        filter.isHidden = hidden
        NSLayoutConstraint.activate(hidden ? filterHiddenConstraints : filterShownConstraints)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

/// The attachment pane's fixed, host-owned shell. Hosts supply the list, preview and actions;
/// this view owns their shared relationship, including the optional scope band below the footer.
/// Extensions may replace only the preview body through `attachments.preview@1`.
final class SessionAttachmentsContentView: NSView {
    let listHeightConstraint: NSLayoutConstraint
    var onWidthChange: (() -> Void)?

    private let scopeBand: NSView
    private var footerToPaneBottom: [NSLayoutConstraint] = []
    private var footerToScopeBand: [NSLayoutConstraint] = []

    init(
        header: NSView,
        list: NSView,
        fold: NSView,
        preview: NSView,
        previewMessage: NSView,
        footer: NSView,
        scopeBand: NSView,
        emptyMessage: NSView,
        listHeightPriority: NSLayoutConstraint.Priority
    ) {
        self.scopeBand = scopeBand
        listHeightConstraint = list.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: .zero)
        wantsLayer = true
        footerToPaneBottom = [footer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)]
        footerToScopeBand = [footer.bottomAnchor.constraint(equalTo: scopeBand.topAnchor)]

        for child in [header, list, fold, preview, footer, scopeBand, emptyMessage] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        previewMessage.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(previewMessage)
        scopeBand.isHidden = true

        let inset = Design.Spacing.inset
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor,
                                        constant: Design.Spacing.small),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            list.topAnchor.constraint(equalTo: header.bottomAnchor,
                                      constant: Design.Spacing.small),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),

            fold.topAnchor.constraint(equalTo: list.bottomAnchor),
            fold.leadingAnchor.constraint(equalTo: leadingAnchor),
            fold.trailingAnchor.constraint(equalTo: trailingAnchor),

            preview.topAnchor.constraint(equalTo: fold.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            preview.bottomAnchor.constraint(equalTo: footer.topAnchor,
                                            constant: -Design.Spacing.small),

            previewMessage.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            previewMessage.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            previewMessage.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: inset),
            previewMessage.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -inset),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),

            scopeBand.leadingAnchor.constraint(equalTo: leadingAnchor),
            scopeBand.trailingAnchor.constraint(equalTo: trailingAnchor),
            scopeBand.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyMessage.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyMessage.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyMessage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            emptyMessage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])
        NSLayoutConstraint.activate(footerToPaneBottom)
        listHeightConstraint.priority = listHeightPriority
        listHeightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)
        if previousWidth != newSize.width { onWidthChange?() }
    }

    func setScopeBandVisible(_ visible: Bool) {
        guard scopeBand.isHidden == visible else { return }
        NSLayoutConstraint.deactivate(visible ? footerToPaneBottom : footerToScopeBand)
        scopeBand.isHidden = !visible
        NSLayoutConstraint.activate(visible ? footerToScopeBand : footerToPaneBottom)
    }
}
