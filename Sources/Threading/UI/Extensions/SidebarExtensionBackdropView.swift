import AppKit
import ThreadingExtensionKit

/// Where `sidebar.backdrop@1` lands: a passive plane between the theme's sidebar dressing and
/// the sidebar's own content.
///
/// The composition is the ordinary one — `ComponentCustomizationHost` with the shared registry
/// lookup, the shared renderer, the same refresh on `ComponentCustomizationDidChange` and the
/// same atomic skip of a hook that fails to render — with an *empty* `.proceed`. The sidebar's
/// brand row, list and footer are not re-parented into the hook tree; they sit above this view
/// in the controller's hierarchy, which is the depth the contract promises. That is the
/// display-pane header's precedent (an empty proceed anchor) rather than the window hook's (a
/// re-parented child): the list owns selection, focus, drag state and thousands of reused rows,
/// gains nothing from living inside a tree whose only job is to be beneath it, and would have
/// to be handed all of that back on every republish.
///
/// What this view holds on the host's behalf, whatever the extension publishes:
///
/// - **Legibility ceiling.** The whole plane is composited at
///   `ExtensionBackdropLimits.maximumOpacity`, so a shader drawing at full alpha still leaves
///   the rows a floor of their own contrast. Content cannot raise it; only this file can.
/// - **Pointer passthrough.** `hitTest` answers nil for every point, so nothing composed here
///   can take a click, a hover or a cursor — the rows above own all three.
/// - **Frame cadence.** A custom surface is built through `ExtensionCustomSurfaceRenderer` with
///   the contract's ceiling, and the Metal view holds its frames while the window is occluded.
/// - **Accessibility.** Not an element, and no descendant is: nothing beneath the rows is
///   announced, because nothing beneath them can be acted on.
///
/// Layering the theme decides: the theme's own gradient and picture (`SidebarBackdropView`)
/// stay beneath this plane, and an opaque navigator well a theme states stays above it — so
/// under such a theme the backdrop shows only around the well. That is the theme's call, not
/// the extension's.
final class SidebarExtensionBackdropView: NSView {

    private let contentContainer: ComponentContentContainer
    private let customizationHost: ComponentCustomizationHost

    // MARK: - Initialization

    init(
        lookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        },
        customSurfaceResolver: @escaping ComponentCustomizationHost.CustomSurfaceResolver =
            SidebarExtensionBackdropView.renderCustomSurface,
        imageResolver: @escaping ComponentCustomizationHost.ImageResolver =
            ExtensionComponentResourceResolver.image
    ) {
        let anchor = NSView()
        anchor.translatesAutoresizingMaskIntoConstraints = false
        anchor.setAccessibilityElement(false)
        contentContainer = ComponentContentContainer(defaultContent: anchor)
        customizationHost = ComponentCustomizationHost(
            target: .sidebarBackdrop(),
            contentContainer: contentContainer,
            lookup: lookup,
            imageResolver: imageResolver,
            customSurfaceResolver: customSurfaceResolver
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        alphaValue = ExtensionBackdropLimits.maximumOpacity
        setAccessibilityElement(false)
        setAccessibilityIdentifier("sidebar.extension-backdrop")

        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        customizationHost.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Host-Owned Behaviour

    /// Passive, all the way down: the rows above own every click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Whether an extension currently dresses the sidebar — what a test and the inspector can
    /// ask without reading pixels.
    var isDressed: Bool {
        contentContainer.replacementContent != nil
    }

    /// The composed extension tree, when there is one.
    var composedContent: NSView? {
        contentContainer.replacementContent
    }

    /// Builds a custom surface at the cadence the contract promised, not the one the patch
    /// asked for. The number comes from the catalogue so the host and the SDK cannot disagree.
    static func renderCustomSurface(
        _ surface: ExtensionCustomSurface,
        _ extensionIdentifier: String
    ) -> NSView? {
        ExtensionCustomSurfaceRenderer.render(
            surface,
            extensionIdentifier: extensionIdentifier,
            maximumFramesPerSecond: ThreadingComponentCatalog.sidebarBackdrop
                .hookConstraints?.maximumCustomSurfaceFramesPerSecond
                ?? ExtensionMetalSurface.maximumFramesPerSecond
        )
    }
}

// MARK: - Limits

/// The bounds the host puts around an extension backdrop, stated once beside the view that
/// enforces them so the number and the reason travel together.
enum ExtensionBackdropLimits {
    /// The plane's composited opacity, and the most an extension can ask for.
    ///
    /// A theme's own sidebar image is uncapped, because a theme is a choice made in Settings
    /// with the result in view. An extension's backdrop is published by a process the user
    /// enabled once and may not be looking at when it changes its mind, so the host keeps a
    /// floor: at this ceiling the rows' ground can move no more than three fifths of the way
    /// toward whatever the surface draws, which leaves a 3:1 label at least readable. Below
    /// it a shader's own alpha is the author's to choose, and the example draws at half.
    static let maximumOpacity: CGFloat = 0.6
}
