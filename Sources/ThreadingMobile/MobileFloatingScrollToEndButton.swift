import QuartzCore
import UIKit

/// Ends UIKit's current finger or momentum phase before a semantic scroll reset.
///
/// Assigning a destination offset does not itself invalidate the velocity already owned by
/// `UIScrollView`: deceleration can write a later offset after a host has jumped to its live end.
/// Setting the current offset through UIKit's nonanimated path arrests that coast. If a finger is
/// still down, resetting the pan recognizer also prevents that same gesture from starting a new
/// coast after the jump.
@MainActor
enum MobileScrollMotion {
    static func cancel(in scrollView: UIScrollView) {
        let panGesture = scrollView.panGestureRecognizer
        if scrollView.isTracking, panGesture.isEnabled {
            panGesture.isEnabled = false
            panGesture.isEnabled = true
        }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
    }
}

/// The phone's one floating affordance for returning a scrolling surface to its live end.
///
/// The control owns only presentation: each host remains responsible for deciding whether there
/// is meaningful content below and for performing the jump. Keeping the rise, scale, opaque
/// floating material, accessibility shape, and Reduce Motion behavior here makes a terminal and
/// a native conversation describe the same action in the same visual language.
@MainActor
final class MobileFloatingScrollToEndButton: UIButton {
    private enum Animation {
        static let presence = "threading.mobile-floating-scroll-to-end.presence"
    }

    private(set) var isPresented = false
    private var hidingTask: Task<Void, Never>?

    init(accessibilityLabel: String, accessibilityIdentifier: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "arrow.down",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: MobileDesign.Size.floatingScrollGlyph,
                weight: .semibold
            )
        )
        configuration.contentInsets = .zero
        // UIKit reapplies corner geometry during layout. State the circle in its configuration
        // so the fill, clip and layer border keep one silhouette after every state update.
        configuration.cornerStyle = .capsule
        self.configuration = configuration
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        accessibilityTraits.insert(.button)
        MobileButtonHaptics.install(on: self)
        clipsToBounds = true
        layer.opacity = 0
        layer.setAffineTransform(Self.concealedTransform)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: RemoteThemePalette) {
        backgroundColor = theme.uiFloatingSurface
        tintColor = theme.uiAccent
        layer.borderColor = theme.uiBorder.cgColor
        layer.borderWidth = max(theme.borderWidth, 1)
    }

    /// Moves between a small, lowered absence and the settled button.
    ///
    /// Layer animations begin at the presentation layer, so reversing direction midway never
    /// snaps to either endpoint. The hidden flag is delayed until departure has actually
    /// finished, leaving the button clickable for the few frames in which it is still visible.
    func setPresented(
        _ presented: Bool,
        animated: Bool = true,
        reducesMotion: Bool = UIAccessibility.isReduceMotionEnabled
    ) {
        guard presented != isPresented else { return }
        isPresented = presented
        hidingTask?.cancel()
        hidingTask = nil

        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: Animation.presence)
        isHidden = false

        let destinationOpacity: Float = presented ? 1 : 0
        let destinationTransform = CATransform3DMakeAffineTransform(
            presented ? .identity : Self.concealedTransform
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = destinationOpacity
        layer.transform = destinationTransform
        CATransaction.commit()

        guard animated, !reducesMotion else {
            isHidden = !presented
            return
        }

        let duration = presented
            ? MobileDesign.Motion.floatingScrollArrival
            : MobileDesign.Motion.floatingScrollDeparture
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = currentOpacity
        opacity.toValue = destinationOpacity
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: currentTransform)
        transform.toValue = NSValue(caTransform3D: destinationTransform)

        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(
            name: presented ? .easeOut : .easeInEaseOut
        )
        layer.add(group, forKey: Animation.presence)

        guard !presented else { return }
        hidingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, !self.isPresented else { return }
            self.isHidden = true
            self.hidingTask = nil
        }
    }

    private static var concealedTransform: CGAffineTransform {
        CGAffineTransform(
            translationX: 0,
            y: MobileDesign.Offset.floatingScrollLift
        )
        .scaledBy(
            x: MobileDesign.Motion.floatingScrollStartScale,
            y: MobileDesign.Motion.floatingScrollStartScale
        )
    }
}
