import AppKit

// The retained Linux shell uses the production chip's modern anatomy. Period-specific chooser
// styles are not present in the checked Linux theme export yet.
extension Design.Size {
    static let choiceHeight: CGFloat = 26
}

extension Design.Symbol {
    static let chevron: CGFloat = 9

    static func configuration(_ pointSize: CGFloat,
                              weight: NSFont.Weight = .medium) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    }
}

public enum SurfaceRadius {
    case pill(height: CGFloat)
    case fixed(CGFloat)

    var value: CGFloat {
        switch self {
        case .pill(let height): return max(0, height / 2)
        case .fixed(let radius): return max(0, radius)
        }
    }
}

extension ThemedControl {
    public func applySurface(fill: NSColor, radius: SurfaceRadius,
                             border: NSColor? = nil,
                             controlGlow: Bool = false,
                             bevel: SurfaceBevel = .automatic) {
        if case .automatic = bevel {} else {
            preconditionFailure("classic Linux chip bevels require a historical theme implementation")
        }
        // The checked Linux palette has no glow; its hover state is the raised fill and ink.
        setAppliedSurface(fill: fill, radius: radius.value, border: border)
    }
}

@MainActor
protocol LinuxThemedMenuSession: AnyObject {
    func dismiss()
}

@MainActor
public enum ThemedMenuPresenter {
    typealias PresentationProvider = (ThemedMenuPresentation, NSView, Int?,
        @escaping (Int, ThemedMenuItem) -> Void, @escaping () -> Void) -> AnyObject?
    static var presentationProvider: PresentationProvider?

    public static func present(_ presentation: ThemedMenuPresentation, from source: NSView,
                               selectedEntryIndex: Int?,
                               onChoose: @escaping (Int, ThemedMenuItem) -> Void,
                               onDismiss: @escaping () -> Void) -> AnyObject? {
        presentationProvider?(presentation, source, selectedEntryIndex, onChoose, onDismiss)
    }

    public static func dismiss(_ session: AnyObject?) {
        (session as? LinuxThemedMenuSession)?.dismiss()
    }
}
