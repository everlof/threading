import AppKit

// Only the neighboring theme and menu contracts needed to mount unchanged ThemedControl and
// ThemedIconButton. WindowHarness consumes a checked production theme snapshot.
@MainActor public protocol ThemedComponent: AnyObject {}

@MainActor public enum SurfaceBevel { case automatic, sunken, none }
@MainActor public enum AppThemePalette {
    public struct Material { public let bevel: Bevel? = nil }
    public struct Bevel {
        public enum Style { case hard, soft }
        public let style: Style
        public let width: CGFloat
    }
    public struct Palette { public let material = Material() }
    public static let current = Palette()
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

public struct AppThemeDidChange {}
public struct ProfileDidChange {}
public struct AccessibilityDisplayOptionsDidChange {}
@MainActor public final class AppEventObservations {
    public func observe<Event>(_ event: Event.Type, _ handler: @escaping (Event) -> Void) {
        // WindowHarness explicitly invalidates its bounded retained views on theme changes.
    }
}

@MainActor public enum InkSource: Equatable {
    case backdrop, chrome, selection
    static var backdropGround: NSColor { LinuxTheme.color("terminal.background") }
    private static let backdropInk = Design.Ink(on: backdropGround)
    private static let chromeInk = Design.Ink(on: LinuxTheme.color("surface"))
    private static let selectionInk = Design.Ink.selection
    public var ink: Design.Ink {
        switch self {
        case .backdrop: return Self.backdropInk
        case .chrome: return Self.chromeInk
        case .selection: return Self.selectionInk
        }
    }
}

/// The Linux host's counterpart of production BackdropThemedControl. The actual icon button
/// and its ThemedControl base are linked unchanged; this seam provides the host's theme roles.
@MainActor
public class BackdropThemedControl: ThemedControl {
    public let inkSource: InkSource
    public var hostGround: InkSource? {
        didSet {
            guard hostGround != oldValue else { return }
            applyInk(ink)
            needsDisplay = true
        }
    }
    public var ink: Design.Ink { (hostGround ?? inkSource).ink }

    public init(frame frameRect: NSRect, inkSource: InkSource) {
        self.inkSource = inkSource
        super.init(frame: frameRect)
    }
    public override init(frame frameRect: NSRect) {
        self.inkSource = .backdrop
        super.init(frame: frameRect)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public func applyInk(_ ink: Design.Ink) {
        preconditionFailure("A BackdropThemedControl must implement applyInk(_:)")
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyInk(ink) }
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInk(ink)
    }
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
@MainActor public protocol ControlRowMember { func adopt(_ metrics: ControlRowMetrics) }
public struct ControlRowMetrics {
    public let height: CGFloat
    public let glyphSlot: CGFloat
    public let glyphRole: Design.Symbol.Role
}

extension NSView {
    /// No diagnostic host view applies a rounded layer surface around the icon button.
    var appliedSurfaceRadius: CGFloat? { nil }
}
