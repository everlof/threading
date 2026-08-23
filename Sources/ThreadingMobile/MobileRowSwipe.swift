import SwiftUI
import UIKit

/// A trailing action a row reveals when it is dragged sideways.
///
/// The title crosses the localization boundary here, the way ``ThemedDialogAction`` does, so a
/// call site reads as plainly as `.swipeActions` did.
struct MobileRowSwipeAction {
    enum Role {
        case standard
        case destructive
    }

    let title: String
    let systemImage: String
    let role: Role
    let perform: () -> Void

    init(
        _ title: String,
        systemImage: String,
        role: Role = .standard,
        perform: @escaping () -> Void
    ) {
        self.title = MobileL10n.string(title)
        self.systemImage = systemImage
        self.role = role
        self.perform = perform
    }
}

/// The rules a row's trailing swipe follows, with no view attached.
///
/// `.swipeActions` is a `List` modifier. The dashboard's rows are not in a `List`: they sit in a
/// `LazyVStack` on one ``ThemedRowGroup`` plate, which is what lets the phone draw a grouped
/// table without handing UIKit the row background. Outside a `List` that modifier is not an
/// error and not a warning — SwiftUI simply ignores it. Archive-by-swipe shipped that way and
/// did nothing for anybody who tried it, while every assertion anyone would have written about
/// it would have passed, because the modifier was right there in the source.
///
/// So the gesture is ours. The part worth testing is arithmetic rather than UIKit: how far the
/// row follows a finger, and what letting go of it means.
enum MobileRowSwipe {
    /// The resting width of the revealed button: one tap target plus the air a word needs
    /// under a glyph.
    static let actionWidth: CGFloat = 92

    /// Past this much of the row's own width, letting go performs the action instead of resting
    /// open — UIKit's full swipe, which is the gesture that people who swipe already know.
    static let fullSwipeFraction: CGFloat = 0.55

    /// Past this much of the button, letting go rests open rather than snapping shut.
    static let openFraction: CGFloat = 0.5

    /// How much of the drag past the button a row that cannot be swiped through still follows.
    /// Deliberately not zero: a row that stops dead reads as broken rather than as refusing.
    static let resistance: CGFloat = 0.25

    /// How far ahead a throw is read, in seconds of travel at the speed the finger left at.
    /// Short: this decides open-or-shut, not where a scroll would land.
    static let projection: CGFloat = 0.2

    /// The snap back to rest. A row settles at chrome pace, not at a spring's own pace.
    static let settleResponse: Double = 0.28
    static let settleDamping: Double = 0.86

    /// What letting go means.
    enum Release: Equatable {
        case closed
        case open
        case performed
    }

    /// Whether a pan moving this way is a row's swipe rather than the list's scroll.
    ///
    /// This is the question the whole gesture turns on, and it has to be answered *before* the
    /// pan begins — which is why the swipe is a `UIPanGestureRecognizer` and not a SwiftUI
    /// `DragGesture`. A `DragGesture` recognises in every direction; inside a `ScrollView` that
    /// is enough to keep the scroll from ever starting, whether it is attached with `gesture`,
    /// `simultaneousGesture` or `highPriorityGesture`. All three were measured on the phone, and
    /// under all three a drag begun on a row scrolled the dashboard nowhere while the same drag
    /// begun on the banner above it scrolled normally. A recogniser can decline the touch
    /// instead, and a declined recogniser is one the scroll view no longer waits for.
    ///
    /// Asked of velocity, in points per second, at the moment UIKit is deciding who gets the
    /// touch — the finger has barely moved by then, so direction is all there is to go on.
    static func isSwipeDirection(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y)
    }

    /// Where a throw would carry the row, so a flick can open it without dragging it open.
    static func projectedTranslation(_ translation: CGFloat, velocity: CGFloat) -> CGFloat {
        translation + velocity * projection
    }

    /// Where the row sits for a finger this far from where it picked the row up.
    ///
    /// Negative is towards the leading edge, which is the direction that reveals a trailing
    /// action. Zero is closed: there is nothing under the leading edge, so a closed row does not
    /// follow a finger to the right.
    static func offset(
        translation: CGFloat,
        resting: CGFloat,
        rowWidth: CGFloat,
        allowsFullSwipe: Bool
    ) -> CGFloat {
        let raw = resting + translation
        guard raw < 0 else { return 0 }
        let revealed = -raw
        guard revealed > actionWidth else { return raw }
        let ceiling = max(actionWidth, rowWidth)
        guard allowsFullSwipe else {
            return -min(actionWidth + (revealed - actionWidth) * resistance, ceiling)
        }
        return -min(revealed, ceiling)
    }

    /// Whether letting go here would perform the action rather than rest the row open.
    ///
    /// A row that has not been measured yet has no full swipe: `rowWidth` is zero until the
    /// first layout, and a threshold of zero would archive a chat for the first points of any
    /// sideways drag.
    static func isArmed(offset: CGFloat, rowWidth: CGFloat, allowsFullSwipe: Bool) -> Bool {
        guard allowsFullSwipe, rowWidth > 0 else { return false }
        return -offset >= rowWidth * fullSwipeFraction
    }

    /// What letting go at this offset means.
    ///
    /// Only travel that actually happened can perform the action; a flick may open the row but
    /// never archives a chat the finger never dragged that far. Opening reads the throw as well,
    /// because a short fast flick is a request to open.
    static func release(
        offset: CGFloat,
        projectedOffset: CGFloat,
        rowWidth: CGFloat,
        allowsFullSwipe: Bool
    ) -> Release {
        if isArmed(offset: offset, rowWidth: rowWidth, allowsFullSwipe: allowsFullSwipe) {
            return .performed
        }
        let thrown = max(-offset, -projectedOffset)
        return thrown >= actionWidth * openFraction ? .open : .closed
    }
}

extension View {
    /// One trailing action, revealed by dragging the row — the swipe a `List` row gets from
    /// `.swipeActions`, for a row that lives on a ``ThemedRowGroup`` plate instead.
    ///
    /// Pass `nil` for a viewer who may not perform the action; the row then carries no gesture
    /// at all rather than a button that refuses. Keep the same action reachable somewhere a
    /// person can see — a swipe is a shortcut for the people who find it, never the only way in,
    /// which is why this also publishes an accessibility action.
    ///
    /// **`activate` is where the row's own tap goes, and the content must not be a `Button`.**
    /// A SwiftUI button fires on touch-up anywhere inside its own bounds, however far the finger
    /// travelled to get there — and a full-width row's bounds contain the whole swipe. So a row
    /// built from a button opens the chat you just swiped to archive. Nothing available to a
    /// SwiftUI gesture prevents it: neither `highPriorityGesture`, nor withdrawing hit testing,
    /// nor a `GestureMask` retracts a press already in flight, and all three were tried on the
    /// phone against this exact row. A `TapGesture` fails the moment the finger travels, and
    /// that is what this modifier installs.
    func mobileRowSwipeAction(
        _ action: MobileRowSwipeAction?,
        allowsFullSwipe: Bool = true,
        activate: (() -> Void)? = nil
    ) -> some View {
        modifier(
            MobileRowSwipeModifier(
                action: action,
                allowsFullSwipe: allowsFullSwipe,
                activate: activate
            )
        )
    }
}

/// The swipe as a view: a plate under the row's trailing edge, revealed exactly as far as the
/// row has moved away from it.
///
/// The strip is clipped to what the row uncovers rather than laid under the whole row, because a
/// row on this plate paints no background of its own — the group paints `panel` once, which is
/// what keeps a translucent panel from doubling. A strip lying under the row would show straight
/// through the words.
private struct MobileRowSwipeModifier: ViewModifier {
    let action: MobileRowSwipeAction?
    let allowsFullSwipe: Bool
    let activate: (() -> Void)?

    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the row rests between gestures: closed, or open at the button's width.
    @State private var resting: CGFloat = 0
    /// How far the finger has carried the row during the pan in progress.
    @State private var travel: CGFloat?
    @State private var rowWidth: CGFloat = 0
    @State private var armFeedback = UIImpactFeedbackGenerator(style: .medium)

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            swipeable(content, action: action)
        } else if let activate {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: activate)
        } else {
            content
        }
    }

    private func swipeable(_ content: Content, action: MobileRowSwipeAction) -> some View {
        let currentOffset = offset
        let armed = MobileRowSwipe.isArmed(
            offset: currentOffset,
            rowWidth: rowWidth,
            allowsFullSwipe: allowsFullSwipe
        )
        return content
            .contentShape(Rectangle())
            .onTapGesture(perform: handleTap)
            .offset(x: currentOffset)
            .background(alignment: .trailing) {
                strip(action, revealed: -currentOffset, armed: armed)
            }
            .background {
                MobileRowSwipePan(
                    // The Taptic Engine takes a moment to wake, and the arming threshold can be
                    // crossed within one of a swipe's first frames. Ask for it at the start of
                    // the pan so the feedback lands with the colour change rather than after it.
                    onBegin: { armFeedback.prepare() },
                    onChange: { travel = $0 },
                    onEnd: { translation, velocity in
                        settle(translation: translation, velocity: velocity, action: action)
                    },
                    onCancel: {
                        land()
                        close()
                    }
                )
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                rowWidth = width
            }
            .onChange(of: armed) { _, isArmed in
                guard isArmed else { return }
                armFeedback.impactOccurred()
            }
            .accessibilityAction(named: Text(action.title)) {
                action.perform()
            }
    }

    // MARK: - Geometry

    private var offset: CGFloat {
        guard let travel else { return resting }
        return MobileRowSwipe.offset(
            translation: travel,
            resting: resting,
            rowWidth: rowWidth,
            allowsFullSwipe: allowsFullSwipe
        )
    }

    private var isOpen: Bool { resting != 0 }

    // MARK: - The revealed button

    private func strip(
        _ action: MobileRowSwipeAction,
        revealed: CGFloat,
        armed: Bool
    ) -> some View {
        Button {
            perform(action)
        } label: {
            VStack(spacing: MobileDesign.Spacing.tight) {
                Image(systemName: action.systemImage)
                    .font(.body)
                Text(action.title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: MobileRowSwipe.actionWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink(for: action))
        .frame(width: max(0, revealed))
        .frame(maxHeight: .infinity)
        .background(armed ? theme.selection : theme.controlResting)
        .clipped()
        .accessibilityHidden(revealed <= 0)
    }

    private func ink(for action: MobileRowSwipeAction) -> Color {
        switch action.role {
        case .standard: return theme.accent
        case .destructive: return theme.negative
        }
    }

    /// An open row answers a tap by closing, the way a `List` row does, and a closed one opens
    /// whatever it stands for. The handler rides with the row, so it never reaches across the
    /// part of the plate the button is standing on.
    private func handleTap() {
        guard !isOpen else {
            close()
            return
        }
        activate?()
    }

    // MARK: - Settling

    private func settle(
        translation: CGFloat,
        velocity: CGFloat,
        action: MobileRowSwipeAction
    ) {
        let landed = MobileRowSwipe.offset(
            translation: translation,
            resting: resting,
            rowWidth: rowWidth,
            allowsFullSwipe: allowsFullSwipe
        )
        let projected = MobileRowSwipe.offset(
            translation: MobileRowSwipe.projectedTranslation(translation, velocity: velocity),
            resting: resting,
            rowWidth: rowWidth,
            allowsFullSwipe: allowsFullSwipe
        )
        let release = MobileRowSwipe.release(
            offset: landed,
            projectedOffset: projected,
            rowWidth: rowWidth,
            allowsFullSwipe: allowsFullSwipe
        )
        land()
        switch release {
        case .closed:
            close()
        case .open:
            move(to: -MobileRowSwipe.actionWidth)
        case .performed:
            perform(action)
        }
    }

    private func perform(_ action: MobileRowSwipeAction) {
        close()
        action.perform()
    }

    /// Hands the finger's last position over to `resting` before the pan is forgotten.
    ///
    /// Clearing the pan on its own would drop the row back to where it rested *before* the
    /// gesture for the frame between letting go and the spring starting — a snap home, and then
    /// a slide to the place it was already at. The two are one state, so they change together.
    private func land() {
        let landed = offset
        travel = nil
        resting = landed
    }

    private func close() {
        move(to: 0)
    }

    private func move(to value: CGFloat) {
        guard !reduceMotion else {
            resting = value
            return
        }
        withAnimation(
            .spring(
                response: MobileRowSwipe.settleResponse,
                dampingFraction: MobileRowSwipe.settleDamping
            )
        ) {
            resting = value
        }
    }
}

/// The row's pan, owned by UIKit so that it can decline a touch.
///
/// Two things have to be true at once, and only a recogniser can arrange both: a sideways drag
/// on a row swipes the row, and a vertical drag on the same row still scrolls the list with its
/// momentum intact. See ``MobileRowSwipe/isSwipeDirection(velocity:)`` for why a SwiftUI
/// `DragGesture` cannot do this.
///
/// The recogniser goes on the enclosing scroll view rather than on this representable's own
/// view, for the reason ``ScreenEdgeSwipe`` gives: a recogniser sees only touches in its own
/// view or a descendant, and a SwiftUI background is a sibling of the content in front of it.
/// This view is still what says *where* the row is — it is laid out at the row's exact frame, so
/// the delegate can ask whether a touch is this row's before claiming it. It takes no touches of
/// its own.
///
/// One recogniser per visible row, added and removed as the `LazyVStack` builds and discards
/// them. The scroll view waits for each of them, and each declines a vertical drag on the spot,
/// so the cost per touch is one direction comparison per row on screen.
///
/// That waiting is arranged through the delegate rather than with `require(toFail:)`, and the
/// difference is the whole lifetime of the scroll view: UIKit offers no way to withdraw a
/// failure requirement, so one registered on the list's own pan outlives the row that asked for
/// it, keeps the dead recogniser alive, and is joined by another every time a row scrolls back
/// into view. `shouldBeRequiredToFailBy` states the same dependency per touch and leaves nothing
/// behind when the row goes.
private struct MobileRowSwipePan: UIViewRepresentable {
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onBegin: onBegin,
            onChange: onChange,
            onEnd: onEnd,
            onCancel: onCancel
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.onEnterWindow = { [coordinator = context.coordinator] anchor in
            coordinator.attach(to: anchor)
        }
        view.onLeaveWindow = { [coordinator = context.coordinator] in
            coordinator.detach()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegin = onBegin
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
        context.coordinator.onCancel = onCancel
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AnchorView: UIView {
        var onEnterWindow: ((UIView) -> Void)?
        var onLeaveWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                onLeaveWindow?()
                return
            }
            onEnterWindow?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegin: () -> Void
        var onChange: (CGFloat) -> Void
        var onEnd: (CGFloat, CGFloat) -> Void
        var onCancel: () -> Void
        private weak var anchor: UIView?
        private weak var host: UIView?
        private weak var listPan: UIPanGestureRecognizer?
        private var pan: UIPanGestureRecognizer?

        init(
            onBegin: @escaping () -> Void,
            onChange: @escaping (CGFloat) -> Void,
            onEnd: @escaping (CGFloat, CGFloat) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onBegin = onBegin
            self.onChange = onChange
            self.onEnd = onEnd
            self.onCancel = onCancel
        }

        func attach(to anchor: UIView) {
            detach()
            guard let target = anchor.enclosingScrollView ?? anchor.superview else { return }
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.delegate = self
            target.addGestureRecognizer(recognizer)
            self.anchor = anchor
            self.host = target
            self.listPan = (target as? UIScrollView)?.panGestureRecognizer
            self.pan = recognizer
        }

        func detach() {
            if let pan {
                host?.removeGestureRecognizer(pan)
            }
            pan = nil
            host = nil
            listPan = nil
            anchor = nil
        }

        @objc
        private func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let anchor else { return }
            let translation = recognizer.translation(in: anchor).x
            switch recognizer.state {
            case .began:
                onBegin()
                onChange(translation)
            case .changed:
                onChange(translation)
            case .ended:
                onEnd(translation, recognizer.velocity(in: anchor).x)
            case .cancelled:
                onCancel()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard
                let pan = recognizer as? UIPanGestureRecognizer,
                let anchor,
                anchor.window != nil
            else { return false }
            guard MobileRowSwipe.isSwipeDirection(velocity: pan.velocity(in: anchor)) else {
                return false
            }
            return anchor.bounds.contains(pan.location(in: anchor))
        }

        /// The list's pan waits for this row's, which declines on the spot for anything that is
        /// not sideways — so a vertical drag reaches the scroll view with its momentum intact
        /// and a sideways one never gets there.
        ///
        /// Stated here, per touch, rather than once with `require(toFail:)`. There is no API to
        /// undo that registration: it lives on the scroll view's own recogniser, so it outlasts
        /// the row that added it, holds the dead recogniser alive, and gains a sibling every
        /// time a row is rebuilt — which for a `LazyVStack` is every time one scrolls past.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            recognizer === pan && other === listPan
        }
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var view: UIView? = superview
        while let current = view {
            if let scrollView = current as? UIScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }
}
