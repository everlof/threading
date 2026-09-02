import UIKit

@MainActor private var mobileButtonHapticsKey: UInt8 = 0

/// The system impact seam used by the phone's button feedback.
///
/// Keeping the tiny protocol here makes the interaction testable without pretending that a
/// simulator can prove what the Taptic Engine feels like on a phone.
@MainActor
protocol MobileImpactFeedbackProducing: AnyObject {
    func prepare()
    func impactOccurred(intensity: CGFloat)
}

extension UIImpactFeedbackGenerator: MobileImpactFeedbackProducing {}

/// The light, pre-warmed impact shared by terminal keys and native-chat buttons.
@MainActor
final class MobileButtonFeedback {
    static let impactIntensity: CGFloat = 0.85
    static let shared = MobileButtonFeedback()

    private let generator: any MobileImpactFeedbackProducing

    init(
        generator: any MobileImpactFeedbackProducing = UIImpactFeedbackGenerator(style: .light)
    ) {
        self.generator = generator
    }

    func prepare() {
        generator.prepare()
    }

    func perform() {
        generator.impactOccurred(intensity: Self.impactIntensity)
        // A prepared generator gives a run of nearby presses the same immediate response as the
        // first one rather than letting the second press pay the engine's wake-up cost.
        generator.prepare()
    }
}

/// Installs that impact on an ordinary UIKit button contract.
///
/// Preparation follows touch-down, while the impact follows the control's successful activation
/// event. A slip or cancellation therefore produces no false confirmation.
@MainActor
enum MobileButtonHaptics {
    private static let prepareActionID = UIAction.Identifier(
        "threading.mobile-button-haptics.prepare"
    )
    private static let impactActionID = UIAction.Identifier(
        "threading.mobile-button-haptics.impact"
    )

    static func install(
        on control: UIControl,
        activationEvent: UIControl.Event = .touchUpInside,
        feedback: MobileButtonFeedback = MobileButtonFeedback.shared
    ) {
        guard !isInstalled(on: control) else { return }

        objc_setAssociatedObject(
            control,
            &mobileButtonHapticsKey,
            true,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        control.addAction(
            UIAction(identifier: prepareActionID) { _ in feedback.prepare() },
            for: .touchDown
        )
        control.addAction(
            UIAction(identifier: impactActionID) { [weak control] _ in
                guard control?.isEnabled == true else { return }
                feedback.perform()
            },
            for: activationEvent
        )
    }

    static func isInstalled(on control: UIControl) -> Bool {
        objc_getAssociatedObject(control, &mobileButtonHapticsKey) as? Bool == true
    }
}
