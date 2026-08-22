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
/// So the gesture is ours. The part worth testing is arithmetic rather than SwiftUI: how far the
/// row follows a finger, and what letting go of it means.
enum MobileRowSwipe {
    /// How far a finger travels before the row follows it at all. Below this a sideways drag is
    /// the wobble in a scroll, and a row that moved for it would fight the list.
    static let minimumTravel: CGFloat = 12

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

    /// The snap back to rest. A row settles at chrome pace, not at a spring's own pace.
    static let settleResponse: Double = 0.28
    static let settleDamping: Double = 0.86

    /// What a drag turned out to be, decided once and then held for the rest of the gesture.
    ///
    /// Deciding afresh on every event is what makes a diagonal drag flicker: the row follows the
    /// finger while the drag is mostly sideways and snaps home the moment it is mostly vertical.
    /// A gesture is asked what it is once, and answers for good.
    enum Drag: Equatable {
        case undecided
        /// The list's, not ours. The row stays where it is for the whole gesture.
        case scrolling
        case swiping(CGFloat)

        var swipeTranslation: CGFloat? {
            guard case .swiping(let translation) = self else { return nil }
            return translation
        }
    }

    /// What letting go means.
    enum Release: Equatable {
        case closed
        case open
        case performed
    }

    /// The gesture's kind after one more event.
    static func drag(_ current: Drag, translation: CGSize) -> Drag {
        switch current {
        case .scrolling:
            return .scrolling
        case .swiping:
            return .swiping(translation.width)
        case .undecided:
            if abs(translation.width) >= minimumTravel,
               abs(translation.width) > abs(translation.height) {
                return .swiping(translation.width)
            }
            if abs(translation.height) >= minimumTravel {
                return .scrolling
            }
            return .undecided
        }
    }

    /// The travel the row follows, with the dead zone the gesture needed in order to be
    /// recognised taken back out — so the row starts under the finger rather than twelve points
    /// behind it.
    static func travel(forTranslation translation: CGFloat) -> CGFloat {
        translation < 0
            ? min(0, translation + minimumTravel)
            : max(0, translation - minimumTravel)
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
        let raw = resting + travel(forTranslation: translation)
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
    /// first layout, and a threshold of zero would archive a chat for the first twelve points of
    /// any sideways drag.
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
        predictedOffset: CGFloat,
        rowWidth: CGFloat,
        allowsFullSwipe: Bool
    ) -> Release {
        if isArmed(offset: offset, rowWidth: rowWidth, allowsFullSwipe: allowsFullSwipe) {
            return .performed
        }
        let thrown = max(-offset, -predictedOffset)
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
    /// built from a button opens the chat you just swiped to archive, and nothing about the
    /// gesture can prevent it: neither `highPriorityGesture` (which also takes the list's
    /// vertical scroll), nor withdrawing hit testing, nor a `GestureMask`, cancels a press
    /// already in flight. All three were tried on the phone against this exact row. The tap
    /// belongs to a `TapGesture`, which fails the moment the finger travels, and that is what
    /// this modifier installs.
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
    @State private var drag = MobileRowSwipe.Drag.undecided
    @State private var rowWidth: CGFloat = 0
    @State private var armFeedback = UIImpactFeedbackGenerator(style: .medium)
    /// Resets itself when the gesture ends *or is cancelled*, which is the only reliable signal
    /// that a drag the list took over is finished with.
    @GestureState private var isDragging = false

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
        let currentOffset = restingOrDragOffset
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
            .contentShape(Rectangle())
            .simultaneousGesture(gesture(action))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                rowWidth = width
            }
            .onChange(of: armed) { _, isArmed in
                guard isArmed else { return }
                armFeedback.impactOccurred()
            }
            .onChange(of: isDragging) { _, dragging in
                guard !dragging else {
                    armFeedback.prepare()
                    return
                }
                // A drag the list took over never ends, it is cancelled. Only this says so.
                guard drag != .undecided else { return }
                drag = .undecided
                settle(to: .closed, action: action)
            }
            .accessibilityAction(named: Text(action.title)) {
                action.perform()
            }
    }

    // MARK: - Geometry

    private var restingOrDragOffset: CGFloat {
        guard let translation = drag.swipeTranslation else { return resting }
        return MobileRowSwipe.offset(
            translation: translation,
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
            settle(to: .performed, action: action)
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

    // MARK: - The gesture

    /// Added as a `simultaneousGesture`, which is what leaves the list alone.
    ///
    /// The row is inside a vertical `ScrollView`, and the scroll view's pan is an *ancestor*
    /// gesture: a simultaneous drag runs beside it, so a vertical drag still scrolls and keeps
    /// its momentum. `highPriorityGesture` does not — it was tried here, and a drag begun on a
    /// row stopped scrolling the dashboard at all while a drag begun on the banner above it
    /// still worked. A component that quietly eats the list's scroll is a worse bug than the
    /// one being fixed.
    ///
    /// Which leaves the row's own tap, and that is settled by ``handleTap`` rather than here:
    /// see ``SwiftUICore/View/mobileRowSwipeAction(_:allowsFullSwipe:activate:)``.
    private func gesture(_ action: MobileRowSwipeAction) -> some Gesture {
        DragGesture(minimumDistance: MobileRowSwipe.minimumTravel, coordinateSpace: .local)
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onChanged { value in
                drag = MobileRowSwipe.drag(drag, translation: value.translation)
            }
            .onEnded { value in
                guard let translation = drag.swipeTranslation else {
                    drag = .undecided
                    return
                }
                let release = MobileRowSwipe.release(
                    offset: dragOffset(for: translation),
                    predictedOffset: dragOffset(for: value.predictedEndTranslation.width),
                    rowWidth: rowWidth,
                    allowsFullSwipe: allowsFullSwipe
                )
                drag = .undecided
                settle(to: release, action: action)
            }
    }

    private func dragOffset(for translation: CGFloat) -> CGFloat {
        MobileRowSwipe.offset(
            translation: translation,
            resting: resting,
            rowWidth: rowWidth,
            allowsFullSwipe: allowsFullSwipe
        )
    }

    // MARK: - Settling

    private func settle(to release: MobileRowSwipe.Release, action: MobileRowSwipeAction) {
        switch release {
        case .closed:
            close()
        case .open:
            move(to: -MobileRowSwipe.actionWidth)
        case .performed:
            close()
            action.perform()
        }
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
