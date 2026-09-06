import SwiftUI

#if os(iOS)
import UIKit

// MARK: - Mobile Scrub Tracker

/// One finger's progress across a surface divided into items: the item it is over, and the
/// item a lift would take.
///
/// This is the rule under every scrub surface, kept pure so it can be pinned without a gesture:
/// `touch(_:)` is every sample of the finger, `lift(_:)` its release. A sample reports the item
/// the finger has just arrived on and nothing while it rests there, which is what makes the
/// selection tick once per crossing. A lift takes the item beneath it, else the last item the
/// finger crossed — a drag that wanders off the surface holds what it had rather than snapping
/// to the edge it left — and nothing at all for a touch that never found an item.
struct MobileScrubTracker<Item: Equatable> {
    /// The item under the finger, while one is down.
    private(set) var scrubbed: Item?

    /// The finger is here. The item, when it is a new one.
    mutating func touch(_ item: Item?) -> Item? {
        guard let item, item != scrubbed else { return nil }
        scrubbed = item
        return item
    }

    /// The finger lifted here. The item to commit, if any; the tracker rests afterwards.
    mutating func lift(_ item: Item?) -> Item? {
        defer { scrubbed = nil }
        return item ?? scrubbed
    }
}

// MARK: - Mobile Scrub Surface

/// The touch contract of a surface divided into items: tap takes the item beneath the finger,
/// a drag makes the choice follow the finger with a selection tick at every crossing, and the
/// lift commits. `MobileIdentityPicker`'s runtime strip and login rows and
/// `MobileModelEffortPicker`'s matrix are each one of these, and so is the next picker on the
/// phone: choosing from a few things laid out on one plate feels like this here, by default.
///
/// It is **one `DragGesture` with no minimum distance**, not a tap composed with a drag. With
/// no distance to wait for, the drag begins on touch-down — so the item under the finger is
/// lit and ticked before the finger moves — reports every sample, and ends on the lift; a tap
/// is the same gesture with no travel between the two. A `SpatialTapGesture` given first
/// refusal over the drag looked like the cleaner split and shipped with both halves broken:
/// the tap held the drag back across the runtime strip on the phone, and the login rows still
/// carried a tap recognizer of their own for their scrolling shape, which as the child gesture
/// took every stationary touch and dropped it. Two recognizers on one surface are two
/// arbitrations, and the surface has one question to answer — *which item is under the
/// finger* — so it uses the one recognizer that reports the finger's position from the first
/// sample to the last. The modifier owns the whole surface: nothing inside it may carry a
/// gesture of its own.
///
/// Every point of the surface belongs to the item `item` says; a point on none of them (a
/// wrapped strip's blank padding) is nil, and the tracker holds the last item across it.
/// `scrubbed` is the item the caller draws as chosen while a finger is down. The commit's own
/// haptic stays with the caller, because each surface has its own — the matrix climbs its
/// ramp. What must not be scrubbed — a login list past the height it can show, which scrolls —
/// stays off this modifier entirely, because a `DragGesture` inside a scroll view keeps the
/// scroll from starting; see `MobileRowSwipe`.
struct MobileScrubSurfaceModifier<Item: Equatable>: ViewModifier {
    let item: (CGPoint) -> Item?
    @Binding var scrubbed: Item?
    let onCommit: (Item) -> Void
    @State private var tracker = MobileScrubTracker<Item>()
    @State private var crossingFeedback = UISelectionFeedbackGenerator()

    func body(content: Content) -> some View {
        content
            // The whole surface answers, including the margin around what is drawn.
            .contentShape(.interaction, Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard tracker.touch(item(value.location)) != nil else { return }
                        scrubbed = tracker.scrubbed
                        crossingFeedback.selectionChanged()
                        crossingFeedback.prepare()
                    }
                    .onEnded { value in
                        let released = tracker.lift(item(value.location))
                        scrubbed = nil
                        guard let released else { return }
                        onCommit(released)
                    }
            )
            .onAppear { crossingFeedback.prepare() }
    }
}

extension View {
    /// Makes this view one scrub surface: tap, or drag and lift, to choose the item under the
    /// finger. See `MobileScrubSurfaceModifier`.
    func mobileScrubSurface<Item: Equatable>(
        item: @escaping (CGPoint) -> Item?,
        scrubbed: Binding<Item?>,
        onCommit: @escaping (Item) -> Void
    ) -> some View {
        modifier(MobileScrubSurfaceModifier(item: item, scrubbed: scrubbed, onCommit: onCommit))
    }
}
#endif
