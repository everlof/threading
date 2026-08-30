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
            arrowEdge: arrowEdge
        )
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var isPresented: Binding<Bool>
        private weak var presenter: UIViewController?
        private var hostingController: UIHostingController<AnyView>?
        private var style: MobileThemedPopoverBackgroundView.Style?
        private var presentationIsScheduled = false

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func update(
            presenter: UIViewController,
            isPresented: Bool,
            root: AnyView,
            style: MobileThemedPopoverBackgroundView.Style,
            arrowEdge: Edge
        ) {
            self.presenter = presenter
            self.style = style
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
            popover.sourceView = presenter.view
            popover.sourceRect = presenter.view.bounds
            popover.permittedArrowDirections = permittedDirection(for: arrowEdge)
            popover.delegate = self
            popover.backgroundColor = style.fill
            popover.popoverBackgroundViewClass = MobileThemedPopoverBackgroundView.self
            hostingController = hosting
            presenter.present(hosting, animated: true) { [weak self, weak hosting] in
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
    let popoverContent: PopoverContent

    func body(content: Content) -> some View {
        content.background {
            MobileThemedPopoverPresenter(
                isPresented: $isPresented,
                theme: theme,
                arrowEdge: arrowEdge,
                content: popoverContent
            )
        }
    }
}

extension View {
    func mobileThemedPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        theme: RemoteThemePalette,
        arrowEdge: Edge,
        @ViewBuilder content: () -> PopoverContent
    ) -> some View {
        modifier(
            MobileThemedPopoverModifier(
                isPresented: isPresented,
                theme: theme,
                arrowEdge: arrowEdge,
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
        layer.shadowPath = outlinePath().cgPath
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

    private func outlinePath() -> UIBezierPath {
        let body = bodyRect
        let path = UIBezierPath(roundedRect: body, cornerRadius: fittedCornerRadius)
        path.append(arrowPath(body: body, cornerRadius: fittedCornerRadius))
        return path
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
}
#endif
