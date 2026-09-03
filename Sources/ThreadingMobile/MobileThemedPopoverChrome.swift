import SwiftUI

#if os(iOS)
import UIKit

/// Presents anchored app content through UIKit's public popover-background seam.
///
/// SwiftUI forwards `presentationBackground` to a compact popover, but as of iOS 26 it ignores
/// `presentationCornerRadius` there and keeps UIKit's large system mask. Owning the presentation
/// lets the remote theme provide the one body-and-arrow outline instead of painting inside a
/// silhouette that remains system-owned.
private struct MobileThemedPopoverPresenter<PopoverContent: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let theme: RemoteThemePalette
    let arrowEdge: Edge
    let makeRoom: (() -> Void)?
    let content: PopoverContent

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ presenter: UIViewController, context: Context) {
        context.coordinator.isPresented = $isPresented
        let style = MobileThemedPopoverBackgroundView.Style(
            fill: theme.uiFloatingSurface,
            border: theme.uiBorder,
            borderWidth: max(theme.borderWidth, 1),
            cornerRadius: theme.panelRadius
        )
        let root = AnyView(content.mobileTheme(theme))
        context.coordinator.update(
            presenter: presenter,
            isPresented: isPresented,
            root: root,
            style: style,
            arrowEdge: arrowEdge,
            makeRoom: makeRoom
        )
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var isPresented: Binding<Bool>
        private weak var presenter: UIViewController?
        private var hostingController: UIHostingController<AnyView>?
        private var style: MobileThemedPopoverBackgroundView.Style?
        private var makeRoom: (() -> Void)?
        private var presentationIsScheduled = false

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func update(
            presenter: UIViewController,
            isPresented: Bool,
            root: AnyView,
            style: MobileThemedPopoverBackgroundView.Style,
            arrowEdge: Edge,
            makeRoom: (() -> Void)?
        ) {
            self.presenter = presenter
            self.style = style
            self.makeRoom = makeRoom
            if let hostingController {
                hostingController.rootView = root
                apply(style, to: hostingController)
                if !isPresented {
                    dismiss(hostingController)
                }
                return
            }
            guard isPresented else { return }
            guard !presentationIsScheduled else { return }
            presentationIsScheduled = true
            DispatchQueue.main.async { [weak self, weak presenter] in
                guard let self else { return }
                self.presentationIsScheduled = false
                guard let presenter,
                      presenter.viewIfLoaded?.window != nil,
                      self.isPresented.wrappedValue,
                      self.hostingController == nil else { return }
                self.present(root, from: presenter, style: style, arrowEdge: arrowEdge)
            }
        }

        private func present(
            _ root: AnyView,
            from presenter: UIViewController,
            style: MobileThemedPopoverBackgroundView.Style,
            arrowEdge: Edge
        ) {
            let hosting = UIHostingController(rootView: root)
            hosting.view.backgroundColor = .clear
            hosting.modalPresentationStyle = .popover
            let width = min(420, max(1, presenter.view.window?.bounds.width ?? 420) - 24)
            hosting.preferredContentSize = hosting.sizeThatFits(
                in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
            )
            guard let popover = hosting.popoverPresentationController else { return }
            if let makeRoom, let window = presenter.view.window,
               !MobileThemedPopoverRoom.fits(
                   contentHeight: hosting.preferredContentSize.height,
                   arrowEdge: arrowEdge,
                   anchor: presenter.view.convert(presenter.view.bounds, to: window),
                   between: MobileThemedPopoverRoom.contentTop(of: window),
                   and: MobileThemedPopoverRoom.contentBottom(of: window)
               ) {
                makeRoom()
            }
            popover.sourceView = presenter.view
            popover.sourceRect = presenter.view.bounds
            popover.permittedArrowDirections = permittedDirection(for: arrowEdge)
            popover.delegate = self
            popover.backgroundColor = style.fill
            popover.popoverBackgroundViewClass = MobileThemedPopoverBackgroundView.self
            hostingController = hosting
            // UIKit instantiates the background view itself, during this call, and the first
            // hook this coordinator has into the created instance is the presentation's
            // completion — after the animation has run. Styling only there presented the whole
            // pop-in with a clear body and border: the content arrived, then its box faded in
            // behind it. The pending style is what the view is born with instead.
            MobileThemedPopoverBackgroundView.pendingStyle = style
            presenter.present(hosting, animated: true) { [weak self, weak hosting] in
                MobileThemedPopoverBackgroundView.pendingStyle = nil
                guard let self, let hosting, let style = self.style else { return }
                self.apply(style, to: hosting)
            }
        }

        private func dismiss(_ hosting: UIViewController) {
            hosting.dismiss(animated: true) { [weak self, weak hosting] in
                guard let self, self.hostingController === hosting else { return }
                self.hostingController = nil
            }
        }

        private func apply(
            _ style: MobileThemedPopoverBackgroundView.Style,
            to hosting: UIViewController
        ) {
            guard let popover = hosting.popoverPresentationController else { return }
            popover.backgroundColor = style.fill
            popover.containerView?
                .firstDescendant(of: MobileThemedPopoverBackgroundView.self)?
                .apply(style)
        }

        private func permittedDirection(for edge: Edge) -> UIPopoverArrowDirection {
            switch edge {
            case .top: return .up
            case .leading: return .left
            case .bottom: return .down
            case .trailing: return .right
            }
        }

        func adaptivePresentationStyle(
            for controller: UIPresentationController
        ) -> UIModalPresentationStyle {
            .none
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            hostingController = nil
            guard isPresented.wrappedValue else { return }
            isPresented.wrappedValue = false
        }
    }
}

private struct MobileThemedPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let theme: RemoteThemePalette
    let arrowEdge: Edge
    let makeRoom: (() -> Void)?
    let popoverContent: PopoverContent

    func body(content: Content) -> some View {
        content.background {
            MobileThemedPopoverPresenter(
                isPresented: $isPresented,
                theme: theme,
                arrowEdge: arrowEdge,
                makeRoom: makeRoom,
                content: popoverContent
            )
        }
    }
}

/// Whether a popover has the room it asks for on the side of its anchor the arrow points from.
///
/// UIKit fits a popover into the container inside the safe area and its own ten-point layout
/// margins, and *shrinks* one that asks for more — the hosted content is then laid out short and
/// clipped, which for the model-by-effort matrix means rows cut off under the fold. A host with
/// something it could clear from under the anchor — the composer's keyboard — asks this first,
/// with the top and bottom the popover's body may stand between in window coordinates, and
/// clears it only when the answer is no. The arrow is the only chrome between the body and the
/// anchor; the layout margin is charged where UIKit charges it, at the safe-area edge, and not
/// again at a navigation bar — counted twice, a full five-row page of the picker came out one
/// point too tall for an iPhone 17 Pro that has nine to spare. Measured on the phone: the
/// picker stands above the keyboard-riding composer on an iPhone 17 Pro, and an iPhone SE fits
/// three rows and asks for the keyboard's room at five, the way every chooser used to
/// unconditionally.
@MainActor
enum MobileThemedPopoverRoom {
    /// `UIPopoverPresentationController.popoverLayoutMargins`' default, on every side.
    static let layoutMargin: CGFloat = 10

    static func fits(
        contentHeight: CGFloat,
        arrowEdge: Edge,
        anchor: CGRect,
        between top: CGFloat,
        and bottom: CGFloat
    ) -> Bool {
        let arrow = MobileThemedPopoverBackgroundView.arrowHeight()
        switch arrowEdge {
        case .bottom:
            return contentHeight <= anchor.minY - top - arrow
        case .top:
            return contentHeight <= bottom - anchor.maxY - arrow
        case .leading, .trailing:
            // Beside the anchor the popover has the whole height; it moves along the edge rather
            // than shrinking, and nothing the host could clear would change that.
            return true
        }
    }

    /// The highest edge a popover's body may reach in a window: below the navigation bar when
    /// one is on screen — a popover standing over the bar would hide Back behind a modal
    /// surface — and otherwise UIKit's own bound, the top safe-area inset plus its margin.
    static func contentTop(of window: UIWindow) -> CGFloat {
        let bars = window.allDescendants(of: UINavigationBar.self)
            .filter { !$0.isHidden && $0.window != nil }
            .map { $0.convert($0.bounds, to: window).maxY }
        return max(window.safeAreaInsets.top + layoutMargin, bars.max() ?? 0)
    }

    /// The lowest edge a popover's body may reach in a window: UIKit's bound, the bottom
    /// safe-area inset plus its margin.
    static func contentBottom(of window: UIWindow) -> CGFloat {
        window.bounds.maxY - window.safeAreaInsets.bottom - layoutMargin
    }
}

extension View {
    /// - Parameter makeRoom: Called once, just before the popover is presented, when its
    ///   content would not fit on its arrow's side of the anchor — so the host can clear what
    ///   stands under the anchor (a keyboard) and the popover lays itself out again as that
    ///   room arrives. Omitted, the popover is presented into whatever room there is.
    func mobileThemedPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        theme: RemoteThemePalette,
        arrowEdge: Edge,
        makeRoom: (() -> Void)? = nil,
        @ViewBuilder content: () -> PopoverContent
    ) -> some View {
        modifier(
            MobileThemedPopoverModifier(
                isPresented: isPresented,
                theme: theme,
                arrowEdge: arrowEdge,
                makeRoom: makeRoom,
                popoverContent: content()
            )
        )
    }
}

final class MobileThemedPopoverBackgroundView: UIPopoverBackgroundView {
    struct Style: Equatable {
        let fill: UIColor
        let border: UIColor
        let borderWidth: CGFloat
        let cornerRadius: CGFloat
    }

    private enum Metrics {
        static let arrowBase: CGFloat = 24
        static let arrowHeight: CGFloat = 12
    }

    /// The style the next UIKit-created instance is born with, staged by the presenter just
    /// before `present` because UIKit offers no seam between instantiating this class and the
    /// first frame it draws. Without it the popover animates in around a clear body and the
    /// theme's box arrives only with the presentation's completion, after its content.
    static var pendingStyle: Style?

    private var style = Style(
        fill: .clear,
        border: .clear,
        borderWidth: 1,
        cornerRadius: 0
    )
    private var storedArrowOffset: CGFloat = 0
    private var storedArrowDirection: UIPopoverArrowDirection = .unknown

    override class func arrowBase() -> CGFloat { Metrics.arrowBase }
    override class func arrowHeight() -> CGFloat { Metrics.arrowHeight }
    override class func contentViewInsets() -> UIEdgeInsets { .zero }

    override var arrowOffset: CGFloat {
        get { storedArrowOffset }
        set {
            storedArrowOffset = newValue
            setNeedsLayout()
        }
    }

    override var arrowDirection: UIPopoverArrowDirection {
        get { storedArrowDirection }
        set {
            storedArrowDirection = newValue
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        if let pendingStyle = Self.pendingStyle {
            style = pendingStyle
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ style: Style) {
        guard self.style != style else { return }
        self.style = style
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // `UIPopoverPresentationController` owns this layer's moving shadow. Replacing its
        // path here starts a second implicit animation whenever UIKit follows an anchor that is
        // moving with the keyboard, so the shadow trails the body during presentation.
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let body = UIBezierPath(
            roundedRect: bodyRect,
            cornerRadius: fittedCornerRadius
        )
        let arrow = arrowPath(body: bodyRect, cornerRadius: fittedCornerRadius)
        style.fill.setFill()
        body.fill()
        arrow.fill()
        style.border.setStroke()
        body.lineWidth = style.borderWidth
        body.stroke()
        // Repaint the arrow over the body's stroke, then draw only its two exposed sides. The
        // result is one visible outline rather than a horizontal rule through the arrow's base.
        style.fill.setFill()
        arrow.fill()
        style.border.setStroke()
        let arrowSides = arrowSidesPath(body: bodyRect, cornerRadius: fittedCornerRadius)
        arrowSides.lineWidth = style.borderWidth
        arrowSides.lineJoinStyle = .round
        arrowSides.stroke()
    }

    private var fittedCornerRadius: CGFloat {
        min(
            max(style.cornerRadius, 0),
            min(bodyRect.width, bodyRect.height) / 2
        )
    }

    private var bodyRect: CGRect {
        switch arrowDirection {
        case .up:
            return bounds.inset(by: UIEdgeInsets(top: Self.arrowHeight(), left: 0, bottom: 0, right: 0))
        case .down:
            return bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: Self.arrowHeight(), right: 0))
        case .left:
            return bounds.inset(by: UIEdgeInsets(top: 0, left: Self.arrowHeight(), bottom: 0, right: 0))
        case .right:
            return bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: Self.arrowHeight()))
        default:
            return bounds
        }
    }

    private func arrowPath(body: CGRect, cornerRadius: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let points = arrowPoints(body: body, cornerRadius: cornerRadius)
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.close()
        return path
    }

    private func arrowSidesPath(body: CGRect, cornerRadius: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let points = arrowPoints(body: body, cornerRadius: cornerRadius)
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    private func arrowPoints(body: CGRect, cornerRadius: CGFloat) -> [CGPoint] {
        let halfBase = Self.arrowBase() / 2
        let overlap = style.borderWidth
        switch arrowDirection {
        case .up:
            let center = clamped(
                body.midX + arrowOffset,
                lower: body.minX + cornerRadius + halfBase,
                upper: body.maxX - cornerRadius - halfBase
            )
            return [
                CGPoint(x: center - halfBase, y: body.minY + overlap),
                CGPoint(x: center, y: bounds.minY),
                CGPoint(x: center + halfBase, y: body.minY + overlap),
            ]
        case .down:
            let center = clamped(
                body.midX + arrowOffset,
                lower: body.minX + cornerRadius + halfBase,
                upper: body.maxX - cornerRadius - halfBase
            )
            return [
                CGPoint(x: center - halfBase, y: body.maxY - overlap),
                CGPoint(x: center, y: bounds.maxY),
                CGPoint(x: center + halfBase, y: body.maxY - overlap),
            ]
        case .left:
            let center = clamped(
                body.midY + arrowOffset,
                lower: body.minY + cornerRadius + halfBase,
                upper: body.maxY - cornerRadius - halfBase
            )
            return [
                CGPoint(x: body.minX + overlap, y: center - halfBase),
                CGPoint(x: bounds.minX, y: center),
                CGPoint(x: body.minX + overlap, y: center + halfBase),
            ]
        case .right:
            let center = clamped(
                body.midY + arrowOffset,
                lower: body.minY + cornerRadius + halfBase,
                upper: body.maxY - cornerRadius - halfBase
            )
            return [
                CGPoint(x: body.maxX - overlap, y: center - halfBase),
                CGPoint(x: bounds.maxX, y: center),
                CGPoint(x: body.maxX - overlap, y: center + halfBase),
            ]
        default:
            return []
        }
    }

    private func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return value }
        return min(max(value, lower), upper)
    }
}

private extension UIView {
    func firstDescendant<View: UIView>(of type: View.Type) -> View? {
        if let match = self as? View { return match }
        for child in subviews {
            if let match = child.firstDescendant(of: type) { return match }
        }
        return nil
    }

    func allDescendants<View: UIView>(of type: View.Type) -> [View] {
        let own = (self as? View).map { [$0] } ?? []
        return own + subviews.flatMap { $0.allDescendants(of: type) }
    }
}
#endif
