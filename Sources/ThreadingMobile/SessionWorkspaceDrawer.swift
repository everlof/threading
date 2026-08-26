import SwiftUI
import UIKit

// MARK: - Rules

/// The arithmetic of the workspace drawer, with no view attached.
///
/// The drawer is a panel that comes in from the right edge and follows the finger that pulls
/// it: a right-edge pan opens it by however far the finger has travelled, a rightward pan on the
/// panel closes it the same way, and a release settles whichever side the finger was heading
/// for. Everything a gesture asks is answered here, so the answers can be tested without a
/// window, the way `MobileRowSwipe` answers the dashboard row's swipe.
enum SessionWorkspaceDrawer {
    /// What stays visible of the chat beside the open panel: a tap target's worth, enough to
    /// say where the panel came from and to be tapped to go back there.
    static let reveal: CGFloat = MobileDesign.Size.minimumTapTarget
    /// The panel is a phone's width less the reveal; on a wider screen it stops being a drawer
    /// and becomes a column, so it is capped at about a phone.
    static let maximumWidth: CGFloat = 420
    /// How dark the chat goes behind the open panel.
    static let scrimOpacity: CGFloat = 0.4
    /// A throw is read this far ahead, in seconds — the same read the row swipe uses, so a flick
    /// that stops short still lands where it was aimed.
    static let projection: CGFloat = MobileRowSwipe.projection
    /// The settle after a release: the whole slide's time, the least a short remainder may
    /// take, and the spring that stops it ringing.
    static let settleDuration: TimeInterval = 0.34
    static let minimumSettleDuration: TimeInterval = 0.16
    static let settleDamping: CGFloat = 0.9
    /// The most of a throw the settle's spring is handed, in remaining distances per second. A
    /// flick released a few points short of home would otherwise arrive at hundreds, and a
    /// spring started that hard overshoots: the panel past its edge, then back.
    static let maximumSettleVelocity: CGFloat = 10
    /// A drag that starts this close to the panel's leading edge belongs to the navigation
    /// stack inside it when that stack has somewhere to pop to.
    static let navigationPopEdge: CGFloat = 24
    /// How far in from the right bezel a touch may begin and still be the drawer's. The system
    /// back gesture's own margin is thirteen points; a little more, because the drawer is
    /// reached for rather than expected, and a graze that misses it by a few points opens
    /// nothing else either.
    static let openingEdge: CGFloat = 20

    static func width(in containerWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(0, containerWidth - reveal))
    }

    /// How open the drawer is for a right-edge pan that has travelled `translation` points
    /// (negative is leftward, into the screen).
    static func openingProgress(translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(1, max(0, -translation / width))
    }

    /// How far a dismissal has got for a pan on the open panel that has travelled
    /// `translation` points (positive is rightward, off the screen).
    static func closingProgress(translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(1, max(0, translation / width))
    }

    /// Whether a release leaves the drawer open. `openness` is how open it is now; `velocity`
    /// is the finger's horizontal speed in points per second, negative toward the open side.
    /// The throw is projected ahead before the halfway rule is applied, so a flick decides.
    static func settlesOpen(openness: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        let projected = openness - velocity * projection / width
        return projected >= 0.5
    }

    /// Whether a pan on the open panel is the one that closes it: rightward, and more sideways
    /// than down, so a list inside the panel keeps its scroll.
    static func isDismissDirection(velocity: CGPoint) -> Bool {
        velocity.x > 0 && velocity.x > abs(velocity.y)
    }

    /// Whether a pan on the chat is the one that opens the drawer: it touched down at the right
    /// bezel and has headed leftward since, more sideways than down.
    ///
    /// Asked at the moment the pan would begin, the way the row swipe is, so a scroll that
    /// happens to start near the edge is declined before the list has waited for anything. By
    /// then the finger has already travelled the recogniser's own hysteresis — ten points on a
    /// quiet frame, and on a frame the terminal was busy drawing, however far it got before the
    /// next touch arrived. So the edge is judged where the touch *began*, recovered as the
    /// location less the translation, not where the finger is now: judged there, a quick swipe
    /// from the bezel had left the edge zone before anyone asked, and opened nothing. The
    /// direction is read off the same path rather than the velocity, because a whole path is
    /// steadier than the last two samples; the velocity answers only for a pan that reports no
    /// travel.
    static func isOpeningEdgeTouch(
        location: CGPoint,
        translation: CGPoint,
        velocity: CGPoint,
        width: CGFloat
    ) -> Bool {
        guard location.x - translation.x >= width - openingEdge else { return false }
        let heading = translation == .zero ? velocity : translation
        return heading.x < 0 && -heading.x > abs(heading.y)
    }

    /// Which recognisers under the finger wait for the drawer's pans: the pans on scroll views,
    /// which are the ones competing for the same drag — the list's own scroll, the terminal's
    /// mouse and selection pans. Nothing else waits. A wait ends only when the drawer's pan
    /// fails, and a pan does not fail while a finger rests on the glass, so a long press made to
    /// wait for it fired at touch-up instead of after its own delay; the terminal's word
    /// selection did exactly that.
    static func isCompetingPan(_ other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }

    /// How a release settles: which side, at what pace, and with how much of the throw.
    struct Settle: Equatable {
        let opens: Bool
        /// A multiplier on the remaining slide's own time. One keeps `settleDuration`'s pace
        /// over whatever is left; less slows a short remainder down to `minimumSettleDuration`,
        /// so a release a few points from home does not snap.
        let completionSpeed: CGFloat
        /// The finger's speed toward where the panel is going, as a spring reads it: in
        /// remaining distances per second, negative when the finger was heading the other way.
        let initialVelocity: CGFloat
    }

    /// The settle for a release with the drawer `openness` open and the finger moving at
    /// `velocity` points per second, negative toward the open side. The side is `settlesOpen`'s
    /// answer; the spring is handed the throw, so a flick carries on at the finger's speed
    /// rather than easing out from wherever it let go.
    static func settle(openness: CGFloat, velocity: CGFloat, width: CGFloat) -> Settle {
        settle(
            opens: settlesOpen(openness: openness, velocity: velocity, width: width),
            openness: openness,
            velocity: velocity,
            width: width
        )
    }

    /// The settle to a side already decided — a gesture the system cancelled goes back where it
    /// came from, whatever the position says.
    static func settle(opens: Bool, openness: CGFloat, velocity: CGFloat, width: CGFloat) -> Settle {
        let remaining = min(1, max(0, opens ? 1 - openness : openness))
        let distance = remaining * width
        let toward = opens ? -velocity : velocity
        let initialVelocity = distance > 0
            ? min(maximumSettleVelocity, max(-maximumSettleVelocity, toward / distance))
            : 0
        let remainingTime = Double(remaining) * settleDuration
        let completionSpeed = remainingTime > 0 ? min(1, remainingTime / minimumSettleDuration) : 1
        return Settle(
            opens: opens,
            completionSpeed: CGFloat(completionSpeed),
            initialVelocity: initialVelocity
        )
    }
}

// MARK: - SwiftUI seam

extension View {
    /// Presents `drawer` as the workspace drawer: a panel from the right edge that a right-edge
    /// pan pulls in and a rightward pan on it pushes out, both following the finger.
    ///
    /// Presented above the navigation stack rather than laid over this view, because a SwiftUI
    /// overlay on a destination stops at the navigation bar and the drawer has to cover it: a
    /// panel with its own bar under the chat's bar is two bars. UIKit's custom modal presentation
    /// is what covers everything, and its percent-driven transition is what lets a gesture scrub
    /// the slide.
    func sessionWorkspaceDrawer<Drawer: View>(
        isPresented: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder drawer: @escaping () -> Drawer
    ) -> some View {
        background(
            SessionWorkspaceDrawerPresenter(
                isPresented: isPresented,
                isEnabled: isEnabled,
                drawer: { AnyView(drawer()) }
            )
            .allowsHitTesting(false)
        )
    }
}

/// A non-interactive representable in the chat's background that owns the presentation: it
/// finds the enclosing view controller (the one the drawer must cover), puts the right-edge
/// recogniser on its view, and presents or dismisses the hosted panel as the binding asks.
///
/// The recogniser cannot live on this representable's own view: a gesture recogniser only sees
/// touches that land in its view or a descendant, and a SwiftUI background is a sibling of the
/// content in front of it. It goes on the nearest view controller's view instead, which is an
/// ancestor of both — the rule the dashboard's row swipe follows too.
private struct SessionWorkspaceDrawerPresenter: UIViewRepresentable {
    @Binding var isPresented: Bool
    /// Whether the edge may open it. A chat with nothing to show in the drawer — a share that
    /// may not manage the session — keeps its right edge quiet.
    let isEnabled: Bool
    let drawer: () -> AnyView
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> SessionWorkspaceDrawerCoordinator {
        SessionWorkspaceDrawerCoordinator(drawer: drawer)
    }

    func makeUIView(context: Context) -> UIView {
        let view = SessionWorkspaceDrawerAnchor()
        view.isUserInteractionEnabled = false
        view.onEnterWindow = { [coordinator = context.coordinator] anchor in
            coordinator.attach(to: anchor)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        // The panel's leading edge is a hairline in the theme's border colour rather than a
        // shadow: flat over bezelled, and the scrim already says which surface is in front.
        // Drawn here, with the presenting view's theme, because the hosted tree inherits no
        // environment and the caller's `mobileTheme` is applied inside `drawer`.
        let edge = theme.border
        let edgeWidth = theme.borderWidth
        let drawer = drawer
        coordinator.drawer = {
            AnyView(
                drawer().overlay(alignment: .leading) {
                    Rectangle()
                        .fill(edge)
                        .frame(width: edgeWidth)
                        .ignoresSafeArea()
                }
            )
        }
        coordinator.groundColor = theme.uiGround
        coordinator.reducesMotion = reduceMotion
        coordinator.isEdgeEnabled = isEnabled
        let binding = $isPresented
        coordinator.onPresentationChange = { presented in
            if binding.wrappedValue != presented { binding.wrappedValue = presented }
        }
        coordinator.refreshContent()
        // Off the update pass: presenting from inside a SwiftUI view update is presenting from
        // inside a layout, which UIKit answers with a warning and, under a transition already
        // in flight, with nothing at all.
        let isPresented = isPresented
        DispatchQueue.main.async {
            if isPresented {
                coordinator.presentIfNeeded()
            } else {
                coordinator.dismissIfNeeded()
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: SessionWorkspaceDrawerCoordinator) {
        coordinator.detach()
    }
}

private final class SessionWorkspaceDrawerAnchor: UIView {
    var onEnterWindow: ((UIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        onEnterWindow?(self)
    }
}

// MARK: - Coordinator

@MainActor
final class SessionWorkspaceDrawerCoordinator: NSObject, UIGestureRecognizerDelegate {
    var drawer: () -> AnyView
    var groundColor: UIColor = .black
    var reducesMotion = false
    var isEdgeEnabled = true {
        didSet { openRecognizer?.isEnabled = isEdgeEnabled }
    }
    var onPresentationChange: ((Bool) -> Void)?

    private weak var presenting: UIViewController?
    private weak var presentingView: UIView?
    private var openRecognizer: UIPanGestureRecognizer?
    private var hosting: UIHostingController<AnyView>?
    private var transition: SessionWorkspaceDrawerTransition?
    private var closeRecognizer: UIPanGestureRecognizer?
    /// The transition a finger is driving, while it is; nil for a tap's presentation.
    private var interaction: UIPercentDrivenInteractiveTransition?
    /// A content refresh that arrived under the finger, owed once it lets go.
    private var needsContentRefresh = false

    init(drawer: @escaping () -> AnyView) {
        self.drawer = drawer
    }

    // MARK: Attachment

    func attach(to anchor: UIView) {
        guard openRecognizer == nil,
              let controller = anchor.enclosingViewController else { return }
        presenting = controller
        presentingView = controller.view
        // A plain pan with the edge stated in `shouldBegin`, not `UIScreenEdgePanGestureRecognizer`:
        // the edge class sat on this hosting view receiving every bezel touch and never began
        // — on the conversation's collection view and the terminal alike — while the system's
        // own back swipe on the same touches did. The rule it would have applied is applied
        // here instead, where it can be tested.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(openPan(_:)))
        pan.isEnabled = isEdgeEnabled
        pan.delegate = self
        controller.view.addGestureRecognizer(pan)
        openRecognizer = pan
    }

    func detach() {
        if let openRecognizer { presentingView?.removeGestureRecognizer(openRecognizer) }
        openRecognizer = nil
        if let hosting, hosting.presentingViewController != nil {
            hosting.dismiss(animated: false)
        }
        hosting = nil
    }

    // MARK: Presentation

    var isPresentedOrPresenting: Bool {
        guard let hosting else { return false }
        return hosting.presentingViewController != nil || hosting.isBeingPresented
    }

    func refreshContent() {
        // Not under a finger. The chat re-renders as its title and activity change, and each
        // pass would hand the hosted tree a new root to diff on the frames the slide is
        // competing for; the refresh is applied once the finger lets go.
        guard interaction == nil else {
            needsContentRefresh = true
            return
        }
        needsContentRefresh = false
        hosting?.rootView = drawer()
    }

    func presentIfNeeded() {
        guard !isPresentedOrPresenting else { return }
        present(interactive: false)
    }

    func dismissIfNeeded() {
        // A finger mid-presentation has not told the binding anything yet; a view update that
        // lands while it is still pulling must not answer "not presented" by dismissing.
        guard interaction == nil,
              let hosting, hosting.presentingViewController != nil,
              !hosting.isBeingPresented, !hosting.isBeingDismissed else { return }
        hosting.dismiss(animated: true)
    }

    private func present(interactive: Bool) {
        // Another presentation on this controller — a sheet, or the last drawer still on its
        // way out — refuses a second, and UIKit says so only in the log. A finger that began
        // then would drive an interaction nothing ever started, and its record would sit here
        // holding every later dismissal off; so it is not begun.
        guard let presenting, presenting.presentedViewController == nil else { return }
        let transition = SessionWorkspaceDrawerTransition()
        transition.reducesMotion = reducesMotion
        transition.onPresentationEnd = { [weak self] completed in
            guard let self else { return }
            self.interaction = nil
            self.onPresentationChange?(completed)
            if !completed { self.hosting = nil }
            if self.needsContentRefresh { self.refreshContent() }
        }
        transition.onDismissalEnd = { [weak self] completed in
            guard let self else { return }
            self.interaction = nil
            if completed {
                self.hosting = nil
                self.onPresentationChange?(false)
            }
            if self.needsContentRefresh { self.refreshContent() }
        }
        transition.onScrimTapped = { [weak self] in self?.dismissIfNeeded() }
        let hosting = UIHostingController(rootView: drawer())
        hosting.view.backgroundColor = groundColor
        hosting.modalPresentationStyle = .custom
        hosting.transitioningDelegate = transition
        let close = UIPanGestureRecognizer(target: self, action: #selector(closePan(_:)))
        close.delegate = self
        hosting.view.addGestureRecognizer(close)
        closeRecognizer = close
        self.transition = transition
        self.hosting = hosting
        if interactive {
            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            self.interaction = interaction
            transition.presentationInteraction = interaction
        }
        presenting.present(hosting, animated: true)
    }

    // MARK: Opening pan

    @objc
    private func openPan(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        let width = SessionWorkspaceDrawer.width(in: view.bounds.width)
        let translation = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began:
            guard !isPresentedOrPresenting else { return }
            present(interactive: true)
        case .changed:
            interaction?.update(
                SessionWorkspaceDrawer.openingProgress(translation: translation, width: width)
            )
        case .ended, .cancelled, .failed:
            guard let interaction else { return }
            let openness = SessionWorkspaceDrawer.openingProgress(
                translation: translation,
                width: width
            )
            let settle = recognizer.state == .ended
                ? SessionWorkspaceDrawer.settle(
                    openness: openness,
                    velocity: recognizer.velocity(in: view).x,
                    width: width
                )
                : SessionWorkspaceDrawer.settle(
                    opens: false, openness: openness, velocity: 0, width: width
                )
            complete(interaction, finishing: settle.opens, settle: settle)
        default:
            break
        }
    }

    /// Lets the transition go where the release decided, at the pace and with the throw the
    /// arithmetic gave it. The timing curve stated here is the one the remainder runs on: a
    /// percent-driven transition finishes an interruptible animator on its `completionCurve`
    /// otherwise, which is a cubic that knows nothing of the finger — the spring on the animator
    /// only ever ran for a tap's presentation.
    private func complete(
        _ interaction: UIPercentDrivenInteractiveTransition,
        finishing: Bool,
        settle: SessionWorkspaceDrawer.Settle
    ) {
        interaction.completionSpeed = settle.completionSpeed
        interaction.timingCurve = UISpringTimingParameters(
            dampingRatio: SessionWorkspaceDrawer.settleDamping,
            initialVelocity: CGVector(dx: settle.initialVelocity, dy: 0)
        )
        if finishing {
            interaction.finish()
        } else {
            interaction.cancel()
        }
    }

    // MARK: Closing pan

    @objc
    private func closePan(_ recognizer: UIPanGestureRecognizer) {
        guard let hosting, let view = recognizer.view else { return }
        let width = view.bounds.width
        let translation = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began:
            guard hosting.presentingViewController != nil, interaction == nil else { return }
            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            self.interaction = interaction
            transition?.dismissalInteraction = interaction
            hosting.dismiss(animated: true)
        case .changed:
            interaction?.update(
                SessionWorkspaceDrawer.closingProgress(translation: translation, width: width)
            )
        case .ended, .cancelled, .failed:
            guard let interaction else { return }
            let openness = 1 - SessionWorkspaceDrawer.closingProgress(
                translation: translation,
                width: width
            )
            let settle = recognizer.state == .ended
                ? SessionWorkspaceDrawer.settle(
                    openness: openness,
                    velocity: recognizer.velocity(in: view).x,
                    width: width
                )
                : SessionWorkspaceDrawer.settle(
                    opens: true, openness: openness, velocity: 0, width: width
                )
            complete(interaction, finishing: !settle.opens, settle: settle)
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else {
            return true
        }
        if recognizer === openRecognizer {
            return !isPresentedOrPresenting && SessionWorkspaceDrawer.isOpeningEdgeTouch(
                location: pan.location(in: view),
                translation: pan.translation(in: view),
                velocity: pan.velocity(in: view),
                width: view.bounds.width
            )
        }
        guard recognizer === closeRecognizer else { return true }
        guard SessionWorkspaceDrawer.isDismissDirection(velocity: pan.velocity(in: view)) else {
            return false
        }
        // A horizontal scroller under the finger — a wide diff, the attachment ledger — keeps
        // its own sideways drag.
        if let scroller = horizontalScroller(under: pan.location(in: view), in: view),
           scroller.contentSize.width > scroller.bounds.width {
            return false
        }
        // The navigation stack inside the panel pops on a drag from its leading edge; when it
        // has somewhere to pop to, that edge is its.
        if pan.location(in: view).x <= SessionWorkspaceDrawer.navigationPopEdge,
           navigationControllerCanPop(in: view) {
            return false
        }
        return true
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        // A scroll view's pan under the finger waits for this recogniser's answer. For the edge
        // pan the answer is immediate — a touch that did not begin at the bezel fails it at
        // once — and without the wait the timeline's own pan took every edge touch first, which
        // is why the edge never opened anything over a conversation. For the closing pan the
        // answer comes on the first movement: sideways is the drawer's, anything else fails
        // here and the list scrolls at once. Only the pans wait: see `isCompetingPan` for what
        // making the terminal's long press wait did to it.
        (recognizer === openRecognizer || recognizer === closeRecognizer)
            && SessionWorkspaceDrawer.isCompetingPan(other)
    }

    private func horizontalScroller(under point: CGPoint, in view: UIView) -> UIScrollView? {
        var candidate = view.hitTest(point, with: nil)
        while let current = candidate {
            if let scroller = current as? UIScrollView, scroller.isScrollEnabled,
               scroller.contentSize.width > scroller.bounds.width + 1 {
                return scroller
            }
            if current === view { break }
            candidate = current.superview
        }
        return nil
    }

    private func navigationControllerCanPop(in view: UIView) -> Bool {
        var queue: [UIView] = [view]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let navigation = current.next as? UINavigationController {
                return navigation.viewControllers.count > 1
            }
            queue.append(contentsOf: current.subviews)
        }
        return false
    }
}

// MARK: - Transition

/// The slide from the right edge and the scrim that comes with it, presenting and dismissing,
/// driven by a finger or by a tap.
private final class SessionWorkspaceDrawerTransition: NSObject, UIViewControllerTransitioningDelegate {
    var reducesMotion = false
    var presentationInteraction: UIPercentDrivenInteractiveTransition?
    var dismissalInteraction: UIPercentDrivenInteractiveTransition?
    var onPresentationEnd: ((Bool) -> Void)?
    var onDismissalEnd: ((Bool) -> Void)?
    var onScrimTapped: (() -> Void)?

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        let controller = SessionWorkspaceDrawerPresentationController(
            presentedViewController: presented,
            presenting: presenting
        )
        controller.onPresentationEnd = onPresentationEnd
        controller.onDismissalEnd = onDismissalEnd
        controller.onScrimTapped = onScrimTapped
        return controller
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        SessionWorkspaceDrawerAnimator(isPresenting: true, reducesMotion: reducesMotion)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        SessionWorkspaceDrawerAnimator(isPresenting: false, reducesMotion: reducesMotion)
    }

    func interactionControllerForPresentation(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        defer { presentationInteraction = nil }
        return presentationInteraction
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        defer { dismissalInteraction = nil }
        return dismissalInteraction
    }
}

/// Where the panel stands and what lies behind it: right-aligned at the drawer's width, full
/// height, over a scrim that darkens with the slide and closes the drawer when tapped.
private final class SessionWorkspaceDrawerPresentationController: UIPresentationController {
    var onPresentationEnd: ((Bool) -> Void)?
    var onDismissalEnd: ((Bool) -> Void)?
    var onScrimTapped: (() -> Void)?
    private let scrim = UIView()

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let width = SessionWorkspaceDrawer.width(in: container.bounds.width)
        return CGRect(
            x: container.bounds.width - width,
            y: 0,
            width: width,
            height: container.bounds.height
        )
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }
        scrim.backgroundColor = .black
        scrim.alpha = 0
        scrim.frame = container.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.isAccessibilityElement = true
        scrim.accessibilityLabel = MobileL10n.string("Close workspace")
        scrim.accessibilityTraits = .button
        scrim.addGestureRecognizer(UITapGestureRecognizer(
            target: self,
            action: #selector(scrimTapped)
        ))
        container.insertSubview(scrim, at: 0)
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.scrim.alpha = SessionWorkspaceDrawer.scrimOpacity
        })
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { scrim.removeFromSuperview() }
        onPresentationEnd?(completed)
    }

    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.scrim.alpha = 0
        })
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed { scrim.removeFromSuperview() }
        onDismissalEnd?(completed)
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // A rotation re-places the panel; a transition in flight owns the frame and is left to it.
        guard presentedViewController.transitionCoordinator == nil else { return }
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    @objc
    private func scrimTapped() {
        onScrimTapped?()
    }
}

/// The slide itself, as an interruptible property animator so a percent-driven interaction
/// can scrub it and a release can spring it home from wherever the finger left it.
private final class SessionWorkspaceDrawerAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let reducesMotion: Bool
    private var animator: UIViewPropertyAnimator?

    init(isPresenting: Bool, reducesMotion: Bool) {
        self.isPresenting = isPresenting
        self.reducesMotion = reducesMotion
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        SessionWorkspaceDrawer.settleDuration
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: context).startAnimation()
    }

    func interruptibleAnimator(
        using context: UIViewControllerContextTransitioning
    ) -> UIViewImplicitlyAnimating {
        if let animator { return animator }
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = context.viewController(forKey: key) else {
            fatalError("a drawer transition has a controller on both sides")
        }
        let container = context.containerView
        // The dismissed controller's final frame is nothing; where it stands now is the place
        // it slides away from.
        let finalFrame = isPresenting ? context.finalFrame(for: controller) : controller.view.frame
        let offstage = finalFrame.offsetBy(dx: finalFrame.width, dy: 0)
        if isPresenting {
            container.addSubview(controller.view)
            controller.view.frame = reducesMotion ? finalFrame : offstage
            controller.view.alpha = reducesMotion ? 0 : 1
        }
        let timing = UISpringTimingParameters(dampingRatio: SessionWorkspaceDrawer.settleDamping)
        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: context),
            timingParameters: timing
        )
        animator.addAnimations {
            if self.reducesMotion {
                controller.view.alpha = self.isPresenting ? 1 : 0
            } else {
                controller.view.frame = self.isPresenting ? finalFrame : offstage
            }
        }
        animator.addCompletion { position in
            let completed = position == .end
            if self.reducesMotion { controller.view.alpha = 1 }
            if !self.isPresenting, completed {
                controller.view.removeFromSuperview()
            }
            context.completeTransition(completed)
        }
        self.animator = animator
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        animator = nil
    }
}

extension UIView {
    /// The nearest view controller up the responder chain — the one whose view is an ancestor
    /// of every SwiftUI sibling, and the one a presentation must come from.
    var enclosingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}
