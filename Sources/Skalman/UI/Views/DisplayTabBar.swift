import AppKit
import SkalmanExtensionKit

// MARK: - Tab Bar Item

/// A lightweight description of one tab, so the strip can draw itself without reaching into a
/// tab's live content (an image, a document, or a whole browser view controller).
struct DisplayTabBarItem {
    let id: UUID
    let title: String
    let symbolName: String
    let isActive: Bool
    let customizationTarget: ExtensionComponentTarget
}

// MARK: - Display Tab Bar

/// The strip of tabs along the top of the display pane, in the app's flat, quiet style.
///
/// It *is* the pane's header — there is no titled row above it — so it is always drawn, and a
/// lone tab names the pane. It scrolls horizontally when it runs out of room rather than
/// shrinking chips to nothing, and reports a selection or a close back to the pane; it owns no
/// state of its own beyond what it is handed.
final class DisplayTabBar: NSView {

    // MARK: - Callbacks

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    // MARK: - Views

    private let stack = NSStackView()
    private let scrollView = ThemedScrollView()
    private let customizationLookup: ComponentCustomizationHost.Lookup

    /// Fades the strip's clipped edge instead of cutting a tab off mid-label.
    ///
    /// The strip scrolls rather than shrinking its chips, so in a narrow pane a tab ends in a
    /// hard vertical slice against the `+` beside it — which reads as a defect, not as "there
    /// is more". A short alpha ramp at whichever edge actually clips is the quiet version of a
    /// scroll affordance: it appears only while there is content beyond it, and only on that
    /// side. Alpha-only, so no theme owns it and no appearance can strand it.
    private let fadeMask = CAGradientLayer()
    private static let fadeLength: CGFloat = Design.Spacing.large

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        customizationLookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
        super.init(frame: frameRect)
        setup()
    }

    init(
        frame frameRect: NSRect,
        customizationLookup: @escaping ComponentCustomizationHost.Lookup
    ) {
        self.customizationLookup = customizationLookup
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

        scrollView.wantsLayer = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollView.layer?.mask = fadeMask

        // The fade follows the scroll position as well as the width: scrolling to the end must
        // take the trailing ramp with it, or the last tab would fade for nothing.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateFade),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

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

        // No hairline here: the strip does not span the pane — the customization slot and `+`
        // sit beside it — so a rule pinned to the strip stopped mid-air short of the pane's
        // edge. The pane's header owns the full-width rule; see
        // `DisplayPaneController.setupHeader`.
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
                showsClose: true,
                inkSource: .chrome
            )
            tab.isSelected = item.isActive
            tab.onSelect = { [weak self] in self?.onSelect?(item.id) }
            tab.onClose = { [weak self] in self?.onClose?(item.id) }
            tab.widthAnchor.constraint(
                lessThanOrEqualToConstant: DisplayPaneDefaults.tabChipMaxWidth
            ).isActive = true
            let customized = DisplayTabHeaderCustomizationView(
                nativeContent: tab,
                target: item.customizationTarget,
                lookup: customizationLookup
            )
            stack.addArrangedSubview(customized)
        }

        needsLayout = true
    }

    // MARK: - Overflow Fade

    override func layout() {
        super.layout()
        updateFade()
    }

    @objc private func updateFade() {
        let clip = scrollView.contentView.bounds
        let content = stack.frame
        guard clip.width > 0 else { return }

        let clipsLeading = clip.minX > 0.5
        let clipsTrailing = content.maxX - clip.maxX > 0.5
        let ramp = min(Self.fadeLength / clip.width, 0.5)

        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor

        // Resizing a layer animates by default, and a mask that glides while the pane is
        // dragged leaves a visible band of half-faded tabs trailing the divider.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = scrollView.bounds
        fadeMask.colors = [
            clipsLeading ? clear : opaque,
            opaque,
            opaque,
            clipsTrailing ? clear : opaque
        ]
        fadeMask.locations = [0, NSNumber(value: ramp), NSNumber(value: 1 - ramp), 1]
        CATransaction.commit()
    }
}
