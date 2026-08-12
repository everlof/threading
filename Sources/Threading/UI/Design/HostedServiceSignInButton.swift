import AppKit
import AuthenticationServices

/// The system-authored Sign in with Apple face, kept inside the design boundary so feature
/// controllers never construct platform controls. Apple owns its typography, mark, and padding.
@MainActor
final class HostedServiceSignInButton: NSView, ThemedComponent, SystemChromeBoundary {
    private let button = ASAuthorizationAppleIDButton(type: .signIn, style: .black)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(target: AnyObject?, action: Selector) {
        button.target = target
        button.action = action
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }

    override func setAccessibilityIdentifier(_ accessibilityIdentifier: String?) {
        button.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    /// Apple owns this one control's face and interaction contract. Keep the exception scoped
    /// to the exact contained button so adding any sibling AppKit chrome still fails the runtime
    /// theme-boundary audit.
    func permitsSystemChrome(_ view: NSView) -> Bool {
        view === button
    }
}
