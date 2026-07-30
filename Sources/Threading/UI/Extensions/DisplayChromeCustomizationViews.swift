import AppKit
import ThreadingExtensionKit

/// Retains a native display tab and fills its one status-only `after-title` slot.
///
/// The slot lives inside `ThemedTabItemView`, so the extension never becomes the selectable
/// object and cannot take ownership of active state, close, focus, hover, overflow or ordering.
@MainActor
final class DisplayTabHeaderCustomizationView: NSView {
    let target: ExtensionComponentTarget
    let nativeContent: ThemedTabItemView

    private let contentContainer: ComponentContentContainer
    private let customizationHost: ComponentCustomizationHost

    init(
        nativeContent: ThemedTabItemView,
        target: ExtensionComponentTarget,
        lookup: @escaping ComponentCustomizationHost.Lookup
    ) {
        self.target = target
        self.nativeContent = nativeContent

        let container = ComponentContentContainer(defaultContent: nativeContent)
        contentContainer = container
        customizationHost = ComponentCustomizationHost(
            target: target,
            contentContainer: container,
            slots: ["after-title": nativeContent.extensionAccessoryStack],
            lookup: lookup,
            imageResolver: ExtensionComponentResourceResolver.image
        )

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("display.tab-header.component")

        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        customizationHost.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The compact extension accessory region immediately before the host's new-tab button.
///
/// `.proceed` is a zero-sized native anchor rather than the tab strip. That gives hooks normal
/// swizzle-style composition while making it structurally impossible for them to replace or
/// wrap selection, close, ordering, overflow or the new-tab menu.
@MainActor
final class DisplayPaneHeaderCustomizationView: NSView {
    private let contentContainer: ComponentContentContainer
    private let customizationHost: ComponentCustomizationHost

    init(
        lookup: @escaping ComponentCustomizationHost.Lookup,
        onAction: @escaping @MainActor (ComponentCustomizationAction) -> Void
    ) {
        let anchor = NSView()
        anchor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            anchor.widthAnchor.constraint(equalToConstant: 0),
            anchor.heightAnchor.constraint(equalToConstant: 0)
        ])

        let container = ComponentContentContainer(defaultContent: anchor)
        contentContainer = container
        customizationHost = ComponentCustomizationHost(
            target: .displayPaneHeader(),
            contentContainer: container,
            lookup: lookup,
            imageResolver: ExtensionComponentResourceResolver.image,
            onAction: onAction
        )

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("display.pane-header.component")
        setContentHuggingPriority(.required, for: .horizontal)
        // Below the split item's holding priority (`DisplayPaneDefaults.holdingPriority`),
        // deliberately: at `.required` this view's fitting width outranked the divider, so an
        // extension chip arriving or changing with the active tab yanked the whole pane wider.
        // The pane's width is the user's answer; oversized accessory content compresses instead.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        container.onReplacementChanged = { [weak self] _ in
            self?.invalidateIntrinsicContentSize()
        }
        customizationHost.deactivate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ceil(contentContainer.fittingSize.width),
            height: NSView.noIntrinsicMetric
        )
    }

    func showSession(_ sessionID: String?) {
        guard let sessionID else {
            customizationHost.deactivate()
            return
        }
        customizationHost.updateTarget(.displayPaneHeader(sessionID: sessionID))
    }
}
