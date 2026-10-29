import Foundation

/// A view holding content **baked** from a theme rather than drawn from it.
///
/// The sweep re-resolves recorded surfaces, layer colours and fonts, then marks the view dirty —
/// which covers everything resolved *at draw time*. An `NSImage` composed against a role is not:
/// the pixels were decided when the image was made, and no amount of redrawing revisits them.
/// A session row's agent mark is plated or not by measuring it against the sidebar; a project
/// tile is composed the same way. Both were baked once and left.
///
/// It survived review because it *appeared* to work: changing a light theme to a dark one fires
/// `viewDidChangeEffectiveAppearance` and every row re-derives by accident. A light-to-light or
/// dark-to-dark switch left those pixels stale until something else re-derived the row.
///
/// The app-theme sweep calls this hook for visible views rather than relying on each view to
/// subscribe. The view's appearance-change path calls it for a system light/dark flip.
@MainActor
public protocol ThemeDerivedContent: AnyObject {
    func rederiveThemedContent()
}

public struct AccessibilityDisplayOptionsDidChange: AppEvent {
    public static let name = Notification.Name("accessibilityDisplayOptionsDidChange")
}
