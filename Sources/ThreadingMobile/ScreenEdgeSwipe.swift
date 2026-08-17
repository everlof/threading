import SwiftUI
import UIKit

/// The rule that separates a swipe from a graze at the bezel.
enum ScreenEdgeSwipeGesture {
    /// Short enough to stay a flick, long enough that the tail of a scroll or a mis-grab at the
    /// edge of the screen does not open anything.
    static let minimumTravel: CGFloat = 44

    static func isDeliberate(travel: CGPoint) -> Bool {
        abs(travel.x) >= minimumTravel && abs(travel.x) > abs(travel.y)
    }
}

extension View {
    /// Runs `action` when a swipe starts at `edge` and travels far enough to be meant.
    ///
    /// Reach for this when a surface has one destination worth a gesture and no room left in its
    /// chrome to name it, and keep the same destination reachable by a control as well: an edge
    /// swipe is a shortcut for the people who find it, never the only way in.
    func onScreenEdgeSwipe(
        from edge: UIRectEdge,
        perform action: @escaping () -> Void
    ) -> some View {
        background(ScreenEdgeSwipe(edge: edge, action: action).allowsHitTesting(false))
    }
}

/// A swipe that begins at a screen edge, attached to the enclosing controller's view.
///
/// `UIScreenEdgePanGestureRecognizer` is the only reader of this gesture that takes nothing
/// away: it claims a touch only once that touch begins inside the system's edge margin and
/// fails otherwise, so the terminal keeps its selection drag and the conversation keeps its
/// scrolling. A transparent SwiftUI strip along the edge would have to swallow every touch in
/// that column to discover whether it was a swipe at all.
///
/// The recogniser cannot live on this representable's own view: a gesture recogniser only sees
/// touches that land in its view or a descendant, and a SwiftUI background is a sibling of the
/// content in front of it. It goes on the nearest view controller's view instead, which is an
/// ancestor of both.
private struct ScreenEdgeSwipe: UIViewRepresentable {
    let edge: UIRectEdge
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.onEnterWindow = { [coordinator = context.coordinator] host in
            coordinator.attach(edge: edge, from: host)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class HostView: UIView {
        var onEnterWindow: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            onEnterWindow?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        private weak var host: UIView?
        private var recognizer: UIScreenEdgePanGestureRecognizer?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func attach(edge: UIRectEdge, from view: UIView) {
            guard recognizer == nil, let target = view.enclosingViewControllerView else { return }
            let pan = UIScreenEdgePanGestureRecognizer(
                target: self,
                action: #selector(handle(_:))
            )
            pan.edges = edge
            target.addGestureRecognizer(pan)
            recognizer = pan
            host = target
        }

        func detach() {
            if let recognizer {
                host?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            host = nil
        }

        @objc
        private func handle(_ sender: UIScreenEdgePanGestureRecognizer) {
            guard sender.state == .ended, let view = sender.view else { return }
            guard ScreenEdgeSwipeGesture.isDeliberate(
                travel: sender.translation(in: view)
            ) else { return }
            action()
        }
    }
}

private extension UIView {
    var enclosingViewControllerView: UIView? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller.view }
            responder = next
        }
        return nil
    }
}
