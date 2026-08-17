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
    let controlGlow: Bool
    /// Recorded as participation because the next theme decides whether a pattern exists.
    let pattern: SurfacePattern
    /// Recorded as participation rather than result, like the radius: whether an edge is
    /// actually drawn is the *next* theme's material to decide.
    let bevel: SurfaceBevel
    let corners: SurfaceCorners
    let clipsContent: Bool

    init(
        fill: NSColor,
        border: NSColor?,
        borderWidth: CGFloat?,
        radius: SurfaceRadius,
        glow: Bool,
        controlGlow: Bool,
        pattern: SurfacePattern,
        bevel: SurfaceBevel,
        corners: SurfaceCorners,
        clipsContent: Bool
    ) {
        self.fill = fill
        self.border = border
        self.borderWidth = borderWidth
        self.radius = radius
        self.glow = glow
        self.controlGlow = controlGlow
        self.pattern = pattern
        self.bevel = bevel
        self.corners = corners
        self.clipsContent = clipsContent
    }
}

@MainActor private var recordedSurfaceKey: UInt8 = 0
@MainActor private var recordedLayerColorsKey: UInt8 = 0
@MainActor private var appliedRefreshGenerationKey: UInt8 = 0

/// Layer colours that were assigned outside `applySurface`.
///
/// These are kept separately from a surface because a view may use `applySurface` for its
/// geometry and glow, then change only its fill as hover or selection changes.
private final class RecordedLayerColors {
    var background: NSColor?
    var border: NSColor?
    var shadow: NSColor?
    var companionShadows: [ObjectIdentifier: RecordedCompanionShadow] = [:]
}

private final class RecordedCompanionShadow {
    weak var layer: CALayer?
    var color: NSColor

    init(layer: CALayer, color: NSColor) {
        self.layer = layer
        self.color = color
    }
}

extension NSView {

    fileprivate var appliedAppThemeRefreshGeneration: UInt64? {
        get {
            (objc_getAssociatedObject(self, &appliedRefreshGenerationKey) as? NSNumber)?
                .uint64Value
        }
        set {
            objc_setAssociatedObject(
                self,
                &appliedRefreshGenerationKey,
                newValue.map(NSNumber.init(value:)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

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

    /// The corner an `applySurface` put on this view's *layer*, resolved for the current theme.
    ///
    /// A layer corner clips what `draw(_:)` lays down, so a control drawing over its own applied
    /// surface has to draw the same silhouette — a rounded rect drawn inside a disc is cut to
    /// pieces by it. Nil when no surface was applied, where the view's own drawing is the shape.
    var appliedSurfaceRadius: CGFloat? {
        recordedSurface?.radius.current
    }

    /// Re-applies whatever `applySurface` last set, resolving its colours again.
    fileprivate func reapplyRecordedSurface() {
        guard let recorded = recordedSurface else { return }
        // Re-run the whole application rather than only the fill: radius, border weight, the
        // halo and the bevel are all theme-derived, and a style that changed only the colours
        // would leave every card wearing the previous theme's silhouette.
        applySurface(
            fill: recorded.fill,
            radius: recorded.radius,
            border: recorded.border,
            borderWidth: recorded.borderWidth,
            glow: recorded.glow,
            controlGlow: recorded.controlGlow,
            pattern: recorded.pattern,
            bevel: recorded.bevel,
            corners: recorded.corners,
            clipsContent: recorded.clipsContent
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
        recorded.companionShadows = recorded.companionShadows.filter { _, entry in
            guard let layer = entry.layer else { return false }
            layer.shadowColor = entry.color.cgColor
            return true
        }
    }

    /// Assigns a layer fill while retaining the `NSColor` that produced the frozen `CGColor`.
    /// The app-theme sweep asks that colour again after a live switch.
    ///
    /// The freeze is taken in the view's **own** effective appearance, not the thread's ambient
    /// drawing appearance: these run from setup code and notification handlers, where the
    /// ambient appearance is whatever AppKit last had in hand — which is how a pane came to
    /// freeze dark in a light window. The view's answer is right even before it joins a window,
    /// where it inherits the application's.
    func applyLayerBackground(_ color: NSColor) {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
        recordedLayerColors.background = color
    }

    func applyLayerBorder(_ color: NSColor) {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = color.cgColor
        }
        recordedLayerColors.border = color
    }

    func applyLayerShadow(_ color: NSColor) {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.shadowColor = color.cgColor
        }
        recordedLayerColors.shadow = color
    }

    /// The companion-layer form of `applyLayerShadow(_:)`, used when a material carries a
    /// second cast (for example Clay's pale upper-left lift). The layer is held weakly so
    /// replacing a material cannot strand detached artwork, while the colour remains available
    /// to the ordinary theme/appearance refresh sweep.
    func applyLayerShadow(_ color: NSColor, to companion: CALayer) {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            companion.shadowColor = color.cgColor
        }
        recordedLayerColors.companionShadows[ObjectIdentifier(companion)] =
            RecordedCompanionShadow(layer: companion, color: color)
    }

    /// Remembers the colours a surface was drawn with. Called by `applySurface`, so its
    /// eighteen call sites need no change of their own.
    func recordSurface(
        fill: NSColor,
        border: NSColor?,
        borderWidth: CGFloat?,
        radius: SurfaceRadius,
        glow: Bool,
        controlGlow: Bool = false,
        pattern: SurfacePattern = .none,
        bevel: SurfaceBevel = .automatic,
        corners: SurfaceCorners = .all,
        clipsContent: Bool = false
    ) {
        recordedSurface = RecordedSurface(
            fill: fill,
            border: border,
            borderWidth: borderWidth,
            radius: radius,
            glow: glow,
            controlGlow: controlGlow,
            pattern: pattern,
            bevel: bevel,
            corners: corners,
            clipsContent: clipsContent
        )
    }

    /// The **opaque** colour actually behind this view.
    ///
    /// Every colour the app derives from a ground — the ink on the backdrop, a diff's wash —
    /// needs the answer to "what is underneath this", and no view knows it: the same
    /// `DiffView` is hosted over a conversation's terminal backdrop, over a review card's
    /// resting fill, and inside a permission panel, and each of those is a different colour
    /// under a different theme. Passing it in from the host means three call sites that must
    /// each work out their own ancestry, which is exactly the arithmetic that goes stale.
    ///
    /// So it is measured. Every ancestor already records the `NSColor` it was filled with, for
    /// the theme sweep above; walking up and compositing those records down onto the window's
    /// own backdrop is the same sum AppKit performs when it draws them. Translucent fills stack
    /// — a 14% card over a pane is both — and the walk stops at the first opaque one, since
    /// nothing above it can show through.
    ///
    /// Call inside `performAsCurrentDrawingAppearance`, as the drawing itself does: the records
    /// are dynamic colours, and a dynamic colour answers for whichever appearance is asking.
    func resolvedGround() -> NSColor {
        var fills: [NSColor] = []
        var node: NSView? = self

        while let current = node {
            if let fill = current.recordedFill,
               let resolved = fill.usingColorSpace(.sRGB),
               resolved.alphaComponent > 0 {
                fills.append(resolved)
                if resolved.alphaComponent >= 1 { break }
            }
            node = current.superview
        }

        // The window's own colour is the last thing under everything — and in a terminal pane it
        // is the *terminal palette's* background rather than the chrome's, which is the case
        // this walk exists to get right. A view with no window yet falls back to the chrome's
        // ground and is re-measured when it joins one.
        let backdrop = window?.backgroundColor ?? Design.Surface.ground
        return fills.reversed().reduce(backdrop) { ground, fill in fill.composited(over: ground) }
    }

    /// What this view was filled with, whichever way it was filled.
    private var recordedFill: NSColor? {
        recordedSurface?.fill
            ?? (objc_getAssociatedObject(self, &recordedLayerColorsKey) as? RecordedLayerColors)?
                .background
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

// MARK: - Derived Content

/// A view holding content **baked** from a theme rather than drawn from it.
///
/// The sweep below re-resolves recorded surfaces, layer colours and fonts, then marks the view
/// dirty — which covers everything resolved *at draw time*. An `NSImage` composed against a role
/// is not: the pixels were decided when the image was made, and no amount of redrawing revisits
/// them. A session row's agent mark is plated or not by measuring the mark against the sidebar it
/// sits on; a project tile is composed the same way. Both were baked once and left.
///
/// It survived review because it *appeared* to work: `AppThemeLibrary.apply` pins
/// `NSApp.appearance` to the theme's mode, so switching between a light theme and a dark one fires
/// `viewDidChangeEffectiveAppearance` and every row re-derives by accident. Only a light→light or
/// dark→dark switch — Windows 98 arriving from any other light theme — left the plates deciding
/// against the previous theme's surface, until something else happened to re-derive the row.
/// Selecting it did, which is what the report described: *the icon fixes itself once you click it*.
///
/// Stated as a hook on the sweep rather than as a notification each view subscribes to, for the
/// reason the sweep gives for existing at all: the failure mode of a subscription is one view in
/// the corner keeping the old theme, and that is precisely the bug this is.
@MainActor
protocol ThemeDerivedContent: AnyObject {

    /// Bake again against the theme now in force. Called by the app-theme sweep, and by the
    /// view's own `viewDidChangeEffectiveAppearance` for a system light/dark flip.
    func rederiveThemedContent()
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
    private static let interfaceThemeObserver = InterfaceThemeObserver()
    private static var observesAccessibilityDisplayOptions = false
    private static var appearanceObservation: NSKeyValueObservation?

    /// The appearance the last adaptive-theme notification was posted for, so two triggers
    /// firing for one switch re-resolve the terminal palettes once rather than twice.
    private static var lastNotifiedAppearance: NSAppearance.Name?

    /// Advances only for a whole-app sweep. A detached retained tree keeps the generation it
    /// last saw, which lets its host distinguish a real missed theme change from an ordinary
    /// remove-and-reinsert cycle without subscribing every view to notifications.
    private(set) static var generation: UInt64 = 0

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
    ///
    /// Two triggers, deliberately. The KVO on `NSApp.effectiveAppearance` was the original one
    /// and it is not enough on its own — measured on a live switch that left the chrome light
    /// and every frozen layer dark: whether it fires at all, and whether it fires before AppKit
    /// has handed the new appearance down the view tree, are both at the framework's pleasure.
    /// The distributed interface-theme notification is the signal the system itself posts for a
    /// light/dark switch, so both routes converge on `systemAppearanceDidChange`, which waits
    /// for the windows to actually wear the new appearance before resolving anything against it.
    static func startObservingSystemAppearance() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { systemAppearanceDidChange() }
        }
        DistributedNotificationCenter.default().addObserver(
            interfaceThemeObserver,
            selector: #selector(InterfaceThemeObserver.interfaceThemeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    /// Repaints once the windows have caught up with the system's new appearance.
    ///
    /// Both triggers land around the switch rather than after it, and a sweep that runs first
    /// re-freezes every layer colour in the *old* appearance — which is indistinguishable from
    /// the bug it exists to fix. So this checks that every unpinned window already resolves to
    /// the application's appearance and gives AppKit another run-loop turn when one does not,
    /// bounded so a hidden window that never catches up cannot park the sweep forever.
    static func systemAppearanceDidChange(retriesLeft: Int = 8) {
        let target = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let lagging = NSApp.windows.contains { window in
            window.appearance == nil
                && window.isVisible
                && window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != target
        }
        if lagging, retriesLeft > 0 {
            DispatchQueue.main.async { systemAppearanceDidChange(retriesLeft: retriesLeft - 1) }
            return
        }

        repaintEverything()

        // An adaptive theme changes more than dynamic NSColor: its material and paired
        // terminal palette are variant-owned values. Reuse the ordinary theme event so
        // every non-colour consumer resolves the newly active variant as well.
        guard let resolved = target, resolved != lastNotifiedAppearance else { return }
        lastNotifiedAppearance = resolved
        guard AppThemeLibrary.current.isAdaptive else { return }
        NotificationCenter.default.post(
            AppThemeDidChange(themeID: AppThemeLibrary.current.id)
        )
    }

    /// Repaints when the user's typography preferences move.
    ///
    /// A chrome or conversation font is not a theme, but *everything that has to happen* when
    /// one changes is what already happens when a theme does: the sweep re-resolves recorded
    /// roles, drawn controls redraw, and the surfaces built from attributed strings — Git
    /// Review's counters, a `ThemedTextField`'s placeholder — rebuild. Rather than teach a
    /// dozen consumers a second event, this reuses the one they already answer.
    ///
    /// It is **guarded on the values**, because `AppSettingsDidChange` fires for every setting
    /// in the app: without the comparison, toggling branch grouping would repaint every window
    /// and re-read git in every open review pane.
    static func startObservingFontOverrides() {
        guard fontOverrideObservation == nil else { return }
        lastFontOverrides = currentFontOverrides
        fontOverrideObservation = NotificationCenter.default.addObserver(
            forName: AppSettingsDidChange.name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let overrides = currentFontOverrides
                guard overrides != lastFontOverrides else { return }
                lastFontOverrides = overrides
                repaintEverything()
                NotificationCenter.default.post(
                    AppThemeDidChange(themeID: AppThemeLibrary.current.id)
                )
            }
        }
    }

    private static var fontOverrideObservation: NSObjectProtocol?
    private static var lastFontOverrides: [String?] = []

    private static var currentFontOverrides: [String?] {
        [
            AppSettings.chromeFontFamily,
            AppSettings.conversationFontFamily,
            AppSettings.appTextSize.rawValue
        ]
    }

    static func accessibilityDisplayOptionsChanged() {
        repaintEverything()
        NotificationCenter.default.post(AccessibilityDisplayOptionsDidChange())
    }

    static func repaintEverything() {
        generation &+= 1
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
            // A theme states a typeface as well as a palette, and an `NSFont` freezes onto a
            // label the way a `CGColor` freezes onto a layer. Same answer: the view recorded the
            // role it asked for, so the role is resolved again here. Controls that draw their own
            // text ask `Design.Typography` inside `draw(_:)` and need nothing.
            view.reapplyRecordedFont()
            // A panel's padding is fitted to the corner the line above just re-applied, so the
            // two are re-stated together — a constraint's constant freezes exactly the way a
            // layer's corner does. See `PanelContentInset`.
            view.reapplyRecordedContentInset()
            // And a mark is weighed against the font two lines up, so it is re-stated beside
            // it: a symbol size follows the chrome's type scale, and a rendered glyph freezes
            // the same way its label's `NSFont` does. See `SymbolMetric`.
            view.reapplyRecordedSymbolSize()
            // Content baked against a role rather than resolved from one — see
            // `ThemeDerivedContent`. Inside the appearance block, because what it bakes against
            // is a themed colour and the answer differs per appearance.
            (view as? ThemeDerivedContent)?.rederiveThemedContent()
            view.needsDisplay = true

            // Effect views and anything else deriving from the appearance need their own nudge,
            // and a view that draws into its layer will not redraw from `needsDisplay` alone.
            if view.wantsLayer, view.layerContentsRedrawPolicy != .never {
                view.layer?.setNeedsDisplay()
            }
        }

        view.appliedAppThemeRefreshGeneration = generation

        for subview in view.subviews { repaint(subview) }
    }

    /// Repaints a cached tree only when it missed a whole-app sweep while detached.
    ///
    /// The first call intentionally paints: a newly created tree has no stamp yet. Later hot
    /// attaches are O(1), while `repaintEverything` advances `generation` before walking visible
    /// windows, leaving only genuinely detached trees stale.
    @discardableResult
    static func repaintIfNeeded(_ view: NSView) -> Bool {
        guard view.appliedAppThemeRefreshGeneration != generation else { return false }
        repaint(view)
        return true
    }
}

@MainActor
private final class AccessibilityDisplayOptionsObserver: NSObject {
    @objc func displayOptionsChanged() {
        AppThemeRefresh.accessibilityDisplayOptionsChanged()
    }
}

/// Receives the system's distributed light/dark notification, which may arrive off the main
/// actor and before `NSApp.effectiveAppearance` has moved — both are the convergence routine's
/// problem, not the observer's.
private final class InterfaceThemeObserver: NSObject {
    @objc func interfaceThemeChanged() {
        DispatchQueue.main.async {
            AppThemeRefresh.systemAppearanceDidChange()
        }
    }
}

struct AccessibilityDisplayOptionsDidChange: AppEvent {
    static let name = Notification.Name("accessibilityDisplayOptionsDidChange")
}
