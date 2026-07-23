import AppKit

// MARK: - Tab Bar Item

/// A lightweight description of one tab, so the strip can draw itself without reaching into a
/// tab's live content (an image, a document, or a whole browser view controller).
struct DisplayTabBarItem {
    let id: UUID
    let title: String
    let symbolName: String
    let isActive: Bool
}

// MARK: - Display Tab Bar

/// The strip of tabs along the top of the display pane, in the app's flat, quiet style.
///
/// It appears only once surfaces coexist (see `DisplayPaneDefaults.tabBarMinimumTabs`), scrolls
/// horizontally when it runs out of room rather than shrinking chips to nothing, and reports a
/// selection or a close back to the pane — it owns no state of its own beyond what it is handed.
final class DisplayTabBar: NSView {

    // MARK: - Callbacks

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    // MARK: - Views

    private let stack = NSStackView()
    private let scrollView = ThemedScrollView()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.tight
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.small,
            bottom: 0, right: Design.Spacing.small
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // The document is as tall as the clip and only as wide as its chips, which is what
            // makes the overflow scroll sideways rather than the chips wrapping or squashing.
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)
        ])

        // A hairline under the strip, separating it from the content below.
        let separator = SeparatorView()
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Update

    /// Rebuilds the chips from the given items. Cheap: tabs change rarely and are few.
    func update(items: [DisplayTabBarItem]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in items {
            let tab = ThemedTabItemView(
                title: item.title,
                symbolName: item.symbolName,
                placement: .horizontal,
                showsClose: true
            )
            tab.isSelected = item.isActive
            tab.onSelect = { [weak self] in self?.onSelect?(item.id) }
            tab.onClose = { [weak self] in self?.onClose?(item.id) }
            tab.widthAnchor.constraint(
                lessThanOrEqualToConstant: DisplayPaneDefaults.tabChipMaxWidth
            ).isActive = true
            stack.addArrangedSubview(tab)
        }
    }
}
