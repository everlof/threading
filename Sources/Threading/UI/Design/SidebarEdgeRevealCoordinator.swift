import Foundation

/// Coordinates the pointer ownership around a temporarily revealed leading sidebar.
///
/// The edge is the anchor and the real sidebar is the interactive surface it reveals. Menus and
/// popovers opened from that surface live elsewhere in the view hierarchy, so their presentation
/// is counted as another hold rather than mistaken for the pointer leaving. The coordinator owns
/// timing and state only; the window keeps ownership of split-pane geometry.
@MainActor
final class SidebarEdgeRevealCoordinator {

    struct Policy: Equatable {
        let openDelay: TimeInterval
        let closeGrace: TimeInterval

        /// A narrow window edge is already an intentional target, so its dwell can be shorter
        /// than a broad hover menu's. The longer exit grace covers the trip into a row menu or
        /// popover without making an abandoned sidebar linger.
        static let standard = Policy(openDelay: 0.25, closeGrace: 0.35)
    }

    /// Six points is discoverable at the physical edge without becoming a strip that steals
    /// ordinary pointer travel through the content beside it.
    static let triggerWidth = Design.Spacing.small

    var policy: Policy {
        didSet {
            scheduler.policy = .init(
                openDelay: policy.openDelay,
                closeGrace: policy.closeGrace,
                holdsWhilePointerOnPopover: true
            )
        }
    }

    var onReveal: (() -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var isTemporarilyRevealed = false
    var isHoldingPresentedInteraction: Bool { presentedInteractionDepth > 0 }

    private let scheduler: HoverPopoverScheduler
    private var isPointerInsideSidebar = false
    private var presentedInteractionDepth = 0

    init(policy: Policy = .standard) {
        self.policy = policy
        scheduler = HoverPopoverScheduler(policy: .init(
            openDelay: policy.openDelay,
            closeGrace: policy.closeGrace,
            holdsWhilePointerOnPopover: true
        ))
        scheduler.onPresent = { [weak self] in self?.reveal() }
        scheduler.onDismiss = { [weak self] in self?.dismiss() }
    }

    func edgeHoverChanged(_ hovering: Bool) {
        if hovering {
            scheduler.pointerEntered()
        } else {
            // Hiding the edge tracker as the pane opens may deliver this exit after the pointer
            // has already entered the sidebar. Preserve the aggregate hold so event ordering
            // cannot start a close timer underneath a live interaction.
            if isTemporarilyRevealed && presentedSurfaceIsHeld {
                scheduler.cancelPendingWork()
            } else {
                scheduler.pointerExited()
            }
        }
    }

    func sidebarHoverChanged(_ hovering: Bool) {
        guard isTemporarilyRevealed else { return }
        isPointerInsideSidebar = hovering
        updatePresentedSurfaceHold()
    }

    /// Menus and popovers notify independently and can nest, so a depth is the honest state.
    func sidebarPresentationDidChange(isPresented: Bool) {
        guard isTemporarilyRevealed else { return }
        if isPresented {
            presentedInteractionDepth += 1
        } else {
            presentedInteractionDepth = max(0, presentedInteractionDepth - 1)
        }
        updatePresentedSurfaceHold()
    }

    /// A tracking area does not synthesize an entry when the sidebar moves underneath a still
    /// pointer. Sample once after the pane reaches its final frame to close that gap.
    func revealDidComplete(pointerIsInsideSidebar: Bool) {
        sidebarHoverChanged(pointerIsInsideSidebar)
    }

    /// Hands visibility back to an explicit command without also asking that command to hide.
    @discardableResult
    func cancelTemporaryReveal() -> Bool {
        let wasRevealed = isTemporarilyRevealed
        scheduler.cancelPendingWork()
        isTemporarilyRevealed = false
        isPointerInsideSidebar = false
        presentedInteractionDepth = 0
        return wasRevealed
    }

    /// Used when the owning window leaves the screen; no grace is useful after that point.
    func dismissImmediately() {
        guard cancelTemporaryReveal() else { return }
        onDismiss?()
    }

    private func reveal() {
        guard !isTemporarilyRevealed else { return }
        isTemporarilyRevealed = true
        onReveal?()
    }

    private func dismiss() {
        guard cancelTemporaryReveal() else { return }
        onDismiss?()
    }

    private func updatePresentedSurfaceHold() {
        scheduler.popoverHoverChanged(presentedSurfaceIsHeld)
    }

    private var presentedSurfaceIsHeld: Bool {
        isPointerInsideSidebar || presentedInteractionDepth > 0
    }
}
