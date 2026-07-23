import AppKit

/// The base for a control that draws itself from the theme rather than from AppKit's stock
/// chrome.
///
/// This exists because of a lesson learned the hard way: a stock `NSSwitch`, `NSPopUpButton` or
/// `NSButton` bakes in the *system* accent and bezel, so under an app style it stays
/// system-blue on a page that has gone red or neon — the theme reaches the cards around it and
/// stops at the control. The design system's rule ("built from `UI/Design/`, not stock AppKit")
/// was already written; this is the machinery that lets it actually hold, and a lint rule keeps
/// raw controls out of the rest of the app so it cannot quietly erode again.
///
/// **Draws in `draw(_:)`, never into a frozen layer.** That is the second half of the lesson:
/// `layer.backgroundColor = colour.cgColor` resolves once and keeps that value, so a live theme
/// switch left stale colours all over the app. A `ThemedControl` reads its roles at *draw
/// time* — where a dynamic colour resolves correctly — and a theme change is answered by a
/// single `needsDisplay = true`. Nothing to record, nothing to re-apply, nothing to freeze.
///
/// Subclasses override `layout()`/`draw(_:)` and read `Design.*`. The only obligation is to
/// draw from roles; the redraw-on-change is handled here.
///
/// No explicit `@MainActor`: `NSControl` already carries it from the SDK, and adding it again
/// over-isolates the control's own properties relative to the plain `SettingsUI` helpers that
/// build these.
class ThemedControl: NSControl {

    private let appEvents = AppEventObservations()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        observeTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Redraws on every theme change — the app theme, and the profile/assignment changes that
    /// can move a role too. A control drawn from roles needs nothing more.
    private func observeTheme() {
        for observe in [
            { self.appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.needsDisplay = true } },
            { self.appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.needsDisplay = true } }
        ] { observe() }
    }

    /// Themed controls draw their own appearance top to bottom, so the layer-backed view never
    /// needs the extra pass AppKit would otherwise take.
    override var wantsUpdateLayer: Bool { false }
}
