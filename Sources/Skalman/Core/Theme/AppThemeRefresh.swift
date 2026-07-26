import AppKit
import ObjectiveC

// MARK: - Surface Recording

/// The tokens a view's layer was filled with, remembered so they can be applied again.
///
/// A `CALayer` resolves its `backgroundColor` to a `CGColor` at assignment and keeps that
/// value — measured, and the same trap that made the terminal's pane keep a stale colour. A
/// dynamic `NSColor` cannot help, because the layer never asks it again. So the view remembers
/// the `NSColor` *objects* it was given and re-reads `.cgColor` from them on a theme change,
/// which is where the dynamic provider runs a second time.
///
/// Recording the object rather than the role means this works for static colours too: a view
/// filled with a terminal theme's background re-applies the same value harmlessly.
private final class RecordedSurface {
    let fill: NSColor
    let border: NSColor?
    let borderWidth: CGFloat?
    /// Recorded because a theme changes a surface's *shape* as well as its colour, and a layer
    /// keeps whatever radius it was last given.
    let radius: SurfaceRadius
    let glow: Bool

    init(
        fill: NSColor,
        border: NSColor?,
        borderWidth: CGFloat?,
        radius: SurfaceRadius,
        glow: Bool
    ) {
        self.fill = fill
        self.border = border
        self.borderWidth = borderWidth
        self.radius = radius
        self.glow = glow
    }
}

private var recordedSurfaceKey: UInt8 = 0
private var recordedLayerColorsKey: UInt8 = 0

/// Layer colours that were assigned outside `applySurface`.
///
/// These are kept separately from a surface because a view may use `applySurface` for its
/// geometry and glow, then change only its fill as hover or selection changes.
private final class RecordedLayerColors {
    var background: NSColor?
    var border: NSColor?
    var shadow: NSColor?
}

extension NSView {

    fileprivate var recordedSurface: RecordedSurface? {
        get { objc_getAssociatedObject(self, &recordedSurfaceKey) as? RecordedSurface }
        set { objc_setAssociatedObject(self, &recordedSurfaceKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    private var recordedLayerColors: RecordedLayerColors {
        if let recorded = objc_getAssociatedObject(self, &recordedLayerColorsKey) as? RecordedLayerColors {
            return recorded
        }
        let recorded = RecordedLayerColors()
        objc_setAssociatedObject(self, &recordedLayerColorsKey, recorded, .OBJC_ASSOCIATION_RETAIN)
        return recorded
    }

    /// Re-applies whatever `applySurface` last set, resolving its colours again.
    fileprivate func reapplyRecordedSurface() {
        guard let recorded = recordedSurface else { return }
        // Re-run the whole application rather than only the fill: radius, border weight and the
        // halo are all theme-derived, and a style that changed only the colours would leave
        // every card wearing the previous theme's silhouette.
        applySurface(
            fill: recorded.fill,
            radius: recorded.radius,
            border: recorded.border,
            borderWidth: recorded.borderWidth,
            glow: recorded.glow
        )
    }

    fileprivate func reapplyRecordedLayerColors() {
        guard let recorded = objc_getAssociatedObject(
            self,
            &recordedLayerColorsKey
        ) as? RecordedLayerColors else { return }

        if let background = recorded.background { layer?.backgroundColor = background.cgColor }
        if let border = recorded.border { layer?.borderColor = border.cgColor }
        if let shadow = recorded.shadow { layer?.shadowColor = shadow.cgColor }
    }

    /// Assigns a layer fill while retaining the `NSColor` that produced the frozen `CGColor`.
    /// The app-theme sweep asks that colour again after a live switch.
    func applyLayerBackground(_ color: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        recordedLayerColors.background = color
    }

    func applyLayerBorder(_ color: NSColor) {
        wantsLayer = true
        layer?.borderColor = color.cgColor
        recordedLayerColors.border = color
    }

    func applyLayerShadow(_ color: NSColor) {
        wantsLayer = true
        layer?.shadowColor = color.cgColor
        recordedLayerColors.shadow = color
    }

    /// Remembers the colours a surface was drawn with. Called by `applySurface`, so its
    /// eighteen call sites need no change of their own.
    func recordSurface(
        fill: NSColor,
        border: NSColor?,
        borderWidth: CGFloat?,
        radius: SurfaceRadius,
        glow: Bool
    ) {
        recordedSurface = RecordedSurface(
            fill: fill,
            border: border,
            borderWidth: borderWidth,
            radius: radius,
            glow: glow
        )
    }

    /// The re-apply on its own, for the test that pins the `CGColor` freeze this exists to fix.
    /// The sweep itself needs a window, which a unit test has no business standing up.
    func reapplyRecordedSurfaceForTesting() {
        reapplyRecordedSurface()
    }

    func reapplyRecordedLayerColorsForTesting() {
        reapplyRecordedLayerColors()
    }
}

// MARK: - Refresh

/// Repaints what is already on screen after the app's theme changes.
///
/// Two different jobs, because the two halves of the app's colour fail differently:
///
/// - **Text, strokes and fills drawn in `draw(_:)`** resolve their colour every time they are
///   drawn, so marking the view dirty is the whole fix.
/// - **Layer background and border colours** were frozen at assignment and have to be set
///   again from the colours the view recorded.
///
/// A theme change is rare and this walk is cheap, so it is deliberately a full sweep rather
/// than a subscription every view has to remember to join — the failure mode of the latter is
/// one view in the corner keeping the old theme, which is exactly the kind of bug nobody
/// notices until a screenshot.
@MainActor
enum AppThemeRefresh {

    private static let accessibilityObserver = AccessibilityDisplayOptionsObserver()
    private static var observesAccessibilityDisplayOptions = false
    private static var appearanceObservation: NSKeyValueObservation?

    /// AppKit refreshes stock controls when these preferences move; app-owned chrome needs the
    /// same signal. Installed once at launch, after the palette is restored and before windows
    /// are built.
    static func startObservingAccessibilityDisplayOptions() {
        guard !observesAccessibilityDisplayOptions else { return }
        observesAccessibilityDisplayOptions = true
        NSWorkspace.shared.notificationCenter.addObserver(
            accessibilityObserver,
            selector: #selector(AccessibilityDisplayOptionsObserver.displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    /// Repaints when the user switches macOS between light and dark.
    ///
    /// Every colour this app resolves is either a dynamic `NSColor` — which follows the
    /// appearance on its own — or a `CGColor` frozen onto a layer, which does not. So a live
    /// switch used to leave the two halves of the window disagreeing: labels turned dark while
    /// the surfaces under them stayed dark too, and a conversation became black on black. It
    /// was invisible for a long time because the largest surface, the sidebar, was a *system
    /// material* that AppKit repainted itself, and the terminal beside it is a palette that has
    /// no light and dark to switch between.
    ///
    /// The sweep for this is the one a theme change already uses; only the trigger was missing.
    /// Installed once at launch, alongside the accessibility observer, for the same reason:
    /// AppKit refreshes its own controls on these signals and app-owned chrome needs telling.
    static func startObservingSystemAppearance() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            // KVO lands before AppKit has finished handing the new appearance down the view
            // tree, and a repaint that runs first re-resolves every colour in the *old* one.
            DispatchQueue.main.async {
                repaintEverything()
                // An adaptive theme changes more than dynamic NSColor: its material and paired
                // terminal palette are variant-owned values. Reuse the ordinary theme event so
                // every non-colour consumer resolves the newly active variant as well.
                guard AppThemeLibrary.current.isAdaptive else { return }
                NotificationCenter.default.post(
                    AppThemeDidChange(themeID: AppThemeLibrary.current.id)
                )
            }
        }
    }

    static func accessibilityDisplayOptionsChanged() {
        repaintEverything()
        NotificationCenter.default.post(AccessibilityDisplayOptionsDidChange())
    }

    static func repaintEverything() {
        for window in NSApp.windows {
            window.appearance = NSApp.appearance
            guard let root = window.contentView else { continue }
            repaint(root)
            window.invalidateShadow()
        }
    }

    /// Re-resolves one view tree in that tree's own effective appearance.
    ///
    /// Most windows follow `NSApp.appearance`, but the Component Gallery deliberately previews
    /// Aqua and Dark Aqua locally. Layer colours are frozen `CGColor`s, so changing a root
    /// view's appearance without this pass leaves dark surfaces behind light text (or vice
    /// versa). Keeping the scoped repaint here gives local previews the same complete refresh
    /// as an app-wide theme change without mutating any other window.
    static func repaint(_ view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.reapplyRecordedSurface()
            // A state-specific layer colour is applied after the base surface, because it
            // represents the most recent visible state (hovered, selected, and so on).
            view.reapplyRecordedLayerColors()
            view.needsDisplay = true

            // Effect views and anything else deriving from the appearance need their own nudge,
            // and a view that draws into its layer will not redraw from `needsDisplay` alone.
            if view.wantsLayer, view.layerContentsRedrawPolicy != .never {
                view.layer?.setNeedsDisplay()
            }
        }

        for subview in view.subviews { repaint(subview) }
    }
}

@MainActor
private final class AccessibilityDisplayOptionsObserver: NSObject {
    @objc func displayOptionsChanged() {
        AppThemeRefresh.accessibilityDisplayOptionsChanged()
    }
}

struct AccessibilityDisplayOptionsDidChange: AppEvent {
    static let name = Notification.Name("accessibilityDisplayOptionsDidChange")
}
