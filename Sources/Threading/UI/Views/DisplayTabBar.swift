import AppKit
import ThreadingExtensionKit

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

/// The strip of tabs along the top of the display pane: `ThemedTabStripView` plus the one thing
/// that is the panel's own — the extension slot wrapped around each chip.
///
/// It *is* the pane's header — there is no titled row above it — so it is always drawn, and a
/// lone tab names the pane. Everything else the strip used to own here (the sideways overflow,
/// the clipped-edge fade, the chip spacing, reordering) moved to the design system the moment a
/// second pane needed the same geometry.
final class DisplayTabBar: NSView {

    // MARK: - Callbacks

    var onSelect: ((UUID) -> Void)? {
        get { strip.onSelect }
        set { strip.onSelect = newValue }
    }

    var onClose: ((UUID) -> Void)? {
        get { strip.onClose }
        set { strip.onClose = newValue }
    }

    var onReorder: ((UUID, Int) -> Void)? {
        get { strip.onReorder }
        set { strip.onReorder = newValue }
    }

    var contextEntries: ((UUID) -> [ThemedMenuEntry])? {
        get { strip.contextEntries }
        set { strip.contextEntries = newValue }
    }

    var externalDropTarget: ((UUID, NSPoint) -> Bool)? {
        get { strip.externalDropTarget }
        set { strip.externalDropTarget = newValue }
    }

    var onDropOut: ((UUID, NSPoint) -> Void)? {
        get { strip.onDropOut }
        set { strip.onDropOut = newValue }
    }

    var onDragEnded: ((UUID) -> Void)? {
        get { strip.onDragEnded }
        set { strip.onDragEnded = newValue }
    }

    var isDropTarget: Bool {
        get { strip.isDropTarget }
        set { strip.isDropTarget = newValue }
    }

    func insertionIndex(forWindowPoint point: NSPoint) -> Int {
        strip.insertionIndex(forWindowPoint: point)
    }

    // MARK: - Views

    private let strip = ThemedTabStripView(inkSource: .chrome)
    private let customizationLookup: ComponentCustomizationHost.Lookup

    /// The extension target the current items belong to, read by the chip decorator at the
    /// moment a chip is made. Tabs never move between sessions inside one strip, so a chip's
    /// target is settled at creation.
    private var currentTarget: ExtensionComponentTarget?

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

        strip.chipMaxWidth = DisplayPaneDefaults.tabChipMaxWidth
        strip.chipDecorator = { [weak self] tab, _ in
            guard let self, let target = self.currentTarget else { return tab }
            return DisplayTabHeaderCustomizationView(
                nativeContent: tab,
                target: target,
                lookup: self.customizationLookup
            )
        }
        addSubview(strip)

        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // No hairline here: the strip does not span the pane — the customization slot and `+`
        // sit beside it — so a rule pinned to the strip stopped mid-air short of the pane's
        // edge. The pane's header owns the full-width rule; see
        // `DisplayPaneController.setupHeader`.
    }

    // MARK: - Update

    /// Hands the items to the strip, which reuses chips by id — so a rename morphs and a drag
    /// survives the re-render that follows it.
    func update(items: [DisplayTabBarItem]) {
        currentTarget = items.first?.customizationTarget
        strip.update(items: items.map {
            TabStripItem(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName,
                isActive: $0.isActive,
                identity: $0.id
            )
        })
    }
}
