import AppKit
import ThreadingExtensionKit

/// Where a backdrop contract lands: a passive plane between a host surface's own ground and its
/// content. Three surfaces carry one — the sidebar (`sidebar.backdrop@1`), the display panel
/// (`display.backdrop@1`) and the new-session composer (`composer.backdrop@1`) — with one
/// contract shape and one set of host-owned promises, so they share this view and differ only
/// in the `Placement` they are built for.
///
/// The composition is the ordinary one — `ComponentCustomizationHost` with the shared registry
/// lookup, the shared renderer, the same refresh on `ComponentCustomizationDidChange` and the
/// same atomic skip of a hook that fails to render — with an *empty* `.proceed`. The host's own
/// content is not re-parented into the hook tree; it sits above this view in its controller's
/// hierarchy, which is the depth the contract promises. That is the display-pane header's
/// precedent (an empty proceed anchor) rather than the window hook's (a re-parented child): the
/// sidebar's list owns selection, focus, drag state and thousands of reused rows, the display
/// panel hosts live browsers and simulators, and the composer owns a prompt being typed into —
/// none gains anything from living inside a tree whose only job is to be beneath it, and each
/// would have to be handed all of that back on every republish.
///
/// What this view holds on the host's behalf, whatever the extension publishes:
///
/// - **Legibility ceiling.** The whole plane is composited at
///   `ExtensionBackdropLimits.maximumOpacity`, so a shader drawing at full alpha still leaves
///   the content a floor of its own contrast. Content cannot raise it; only this file can.
/// - **Pointer passthrough.** `hitTest` answers nil for every point, so nothing composed here
///   can take a click, a hover or a cursor — the content above owns all three.
/// - **Frame cadence.** A custom surface is built through `ExtensionCustomSurfaceRenderer` with
///   the contract's ceiling, and the Metal view holds its frames while the window is occluded.
/// - **Accessibility.** Not an element, and no descendant is: nothing beneath the content is
///   announced, because nothing beneath it can be acted on.
///
/// Layering beneath is the host's to decide and is the same everywhere: the surface's own
/// themed ground stays beneath this plane. What sits above differs — the sidebar's opaque
/// navigator well a theme may state, the display panel's hosted tab content, which is usually
/// opaque — so a backdrop shows wherever the content above it is transparent.
final class ExtensionBackdropPlaneView: NSView {

    /// One host surface that carries a backdrop plane: the contract it publishes and the
    /// identifier the plane answers to in an accessibility or UI-test query.
    struct Placement: Equatable {
        let contract: ExtensionComponentContract
        let accessibilityIdentifier: String
        /// Whether the host states focus regions here (`ThreadingSurfaceUniforms.focus`). Only
        /// the composer has a hero and a prompt box to design around; every other placement's
        /// surfaces read zeros whatever `focus` says.
        var statesFocus = false

        var target: ExtensionComponentTarget {
            ExtensionComponentTarget(component: contract.id, contractVersion: contract.version)
        }

        /// The contract's cadence ceiling — read from the catalogue so the host and the SDK
        /// cannot disagree.
        var maximumFramesPerSecond: Int {
            contract.hookConstraints?.maximumCustomSurfaceFramesPerSecond
                ?? ExtensionMetalSurface.maximumFramesPerSecond
        }

        /// Beneath the sidebar's brand row, list and footer.
        static let sidebar = Placement(
            contract: ThreadingComponentCatalog.sidebarBackdrop,
            accessibilityIdentifier: "sidebar.extension-backdrop"
        )

        /// Beneath the display panel's tab row and content.
        static let displayPanel = Placement(
            contract: ThreadingComponentCatalog.displayBackdrop,
            accessibilityIdentifier: "display.extension-backdrop"
        )

        /// Beneath the new-session composer's greeting, chips, prompt and actions.
        static let composer = Placement(
            contract: ThreadingComponentCatalog.composerBackdrop,
            accessibilityIdentifier: "composer.extension-backdrop",
            statesFocus: true
        )
    }

    let placement: Placement
    private let contentContainer: ComponentContentContainer
    private let customizationHost: ComponentCustomizationHost

    // MARK: - Initialization

    /// `customSurfaceResolver` defaults to the shared renderer at the placement's ceiling.
    init(
        placement: Placement,
        lookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        },
        customSurfaceResolver: ComponentCustomizationHost.CustomSurfaceResolver? = nil,
        imageResolver: @escaping ComponentCustomizationHost.ImageResolver =
            ExtensionComponentResourceResolver.image
    ) {
        self.placement = placement
        let anchor = NSView()
        anchor.translatesAutoresizingMaskIntoConstraints = false
        anchor.setAccessibilityElement(false)
        contentContainer = ComponentContentContainer(defaultContent: anchor)
        customizationHost = ComponentCustomizationHost(
            target: placement.target,
            contentContainer: contentContainer,
            lookup: lookup,
            imageResolver: imageResolver,
            customSurfaceResolver: customSurfaceResolver ?? { surface, extensionIdentifier in
                ExtensionBackdropPlaneView.renderCustomSurface(
                    surface,
                    extensionIdentifier,
                    placement: placement
                )
            }
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        alphaValue = ExtensionBackdropLimits.maximumOpacity
        setAccessibilityElement(false)
        setAccessibilityIdentifier(placement.accessibilityIdentifier)

        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        // A tree mounted after the host stated its regions — a later publish, a republish, a
        // reloaded extension — is told them as it lands, not on the next layout.
        contentContainer.onReplacementChanged = { [weak self] _ in self?.focusDidChange() }
        customizationHost.refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Host-Owned Behaviour

    /// Passive, all the way down: the content above owns every click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Where the host's working regions sit inside this plane, for a surface to design around
    /// (`composer.backdrop@1`: the hero over the greeting, and the prompt box). The host restates
    /// it on layout; a placement with no such regions leaves it empty.
    var focus = ExtensionSurfaceFocus() {
        didSet { if focus != oldValue { focusDidChange() } }
    }

    /// Hands the regions to every Metal surface in the composed tree, stated in this plane's
    /// coordinates with the plane as their space: each surface restates them in its own
    /// coordinates on every frame, so no ordering between this plane's layout and its
    /// descendants' can leave one drawing against a stale place. A plane showing nothing has
    /// nobody to tell; a placement that states no regions tells its surfaces there are none.
    /// The tree is the contract's (at most six nodes), so the walk is bounded.
    private func focusDidChange() {
        guard let content = contentContainer.replacementContent else { return }
        let stated = placement.statesFocus ? focus : ExtensionSurfaceFocus()
        for surface in Self.metalSurfaces(in: content) {
            surface.setFocus(stated, in: self)
        }
    }

    /// The Metal surfaces in `root`'s subtree, `root` included.
    private static func metalSurfaces(in root: NSView) -> [ExtensionMetalSurfaceView] {
        var found: [ExtensionMetalSurfaceView] = []
        var pending = [root]
        while let view = pending.popLast() {
            if let surface = view as? ExtensionMetalSurfaceView { found.append(surface) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Whether an extension currently dresses the plane — what a test and the inspector can
    /// ask without reading pixels.
    var isDressed: Bool {
        contentContainer.replacementContent != nil
    }

    /// The composed extension tree, when there is one.
    var composedContent: NSView? {
        contentContainer.replacementContent
    }

    /// Pins the plane to every edge of `host`, the one geometry every placement uses.
    func pinToEdges(of host: NSView) {
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
    }

    /// Builds a custom surface at the cadence the contract promised, not the one the patch
    /// asked for.
    static func renderCustomSurface(
        _ surface: ExtensionCustomSurface,
        _ extensionIdentifier: String,
        placement: Placement
    ) -> NSView? {
        ExtensionCustomSurfaceRenderer.render(
            surface,
            extensionIdentifier: extensionIdentifier,
            maximumFramesPerSecond: placement.maximumFramesPerSecond
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
    /// floor: at this ceiling the content's ground can move no more than three fifths of the
    /// way toward whatever the surface draws, which leaves a 3:1 label at least readable. Below
    /// it a shader's own alpha is the author's to choose, and the example draws at half.
    static let maximumOpacity: CGFloat = 0.6
}
