import AppKit

// Only the neighboring theme and menu contracts needed to mount unchanged ThemedControl and
// ThemedIconButton. WindowHarness consumes a checked production theme snapshot.
@MainActor public protocol ThemedComponent: AnyObject {}
@MainActor public protocol SystemChromeBoundary: AnyObject {
    func permitsSystemChrome(_ view: NSView) -> Bool
}

@MainActor public enum SurfaceBevel { case automatic, sunken, none }
@MainActor public enum AppThemePalette {
    public enum ColorRole { case selection }
    public struct Material {
        public let bevel: Bevel? = nil
    }
    public struct Bevel {
        public enum Style { case hard, soft }
        public let style: Style
        public let width: CGFloat
    }
    public struct Palette {
        public let material = Material()
    }
    public static let current = Palette()
    public static func color(_ role: ColorRole) -> NSColor {
        switch role {
        case .selection: LinuxTheme.color("selection")
        }
    }
}
@MainActor public enum BevelArtwork {
    public struct Edges {
        public let topLeftOuter: NSColor
        public let topLeftInner: NSColor
        public let bottomRightOuter: NSColor
        public let bottomRightInner: NSColor
    }
    public static func edgeColors(highlight: NSColor, shadow: NSColor, sunken: Bool) -> Edges {
        preconditionFailure("WindowHarness has no bevel material")
    }
    public static func ringWidths(for width: CGFloat) -> (outer: CGFloat, inner: CGFloat) {
        preconditionFailure("WindowHarness has no bevel material")
    }
}
@MainActor public enum SoftBevelArtwork {
    public static func draw(shape: SurfaceDrawing.Shape, edgeWidth: CGFloat,
                            highlight: NSColor, shadow: NSColor, sunken: Bool) {
        preconditionFailure("WindowHarness has no bevel material")
    }
}

public struct AppThemeDidChange: AppEvent {
    public static let name = Notification.Name("appThemeDidChange")
}
public struct ProfileDidChange: AppEvent {
    public static let name = Notification.Name("profileDidChange")
}
public struct AccessibilityDisplayOptionsDidChange: AppEvent {
    public static let name = Notification.Name("accessibilityDisplayOptionsDidChange")
}

#if !THREADING_WINDOW_HARNESS && !THREADING_PANE_HEADER_HARNESS
@MainActor public protocol OpticalInsetProviding {
    var opticalHorizontalInset: CGFloat { get }
    func opticalVerticalInset(forFrameHeight frameHeight: CGFloat) -> CGFloat
}
#endif
@MainActor public protocol ThemedMenuPresentationObserving {
    func themedMenuPresentationDidChange(isPresented: Bool)
}
public enum ThemedMenuAnchor { case pointer(NSPoint), control }
#if !THREADING_WINDOW_HARNESS
// The window host links the production ControlRow; the narrower harnesses keep this shape.
@MainActor public protocol ControlRowMember { func adopt(_ metrics: ControlRowMetrics) }
public struct ControlRowMetrics {
    public let height: CGFloat
    public let glyphSlot: CGFloat
    public let glyphRole: Design.Symbol.Role
}
#endif

extension NSView {
    /// No diagnostic host view applies a rounded layer surface around the icon button.
    var appliedSurfaceRadius: CGFloat? { nil }
}
