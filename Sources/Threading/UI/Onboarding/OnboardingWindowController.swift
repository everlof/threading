import AppKit

/// The first-launch walkthrough's window: shown before the main window exists, closed only
/// after it does.
///
/// Modeled on `ComponentGalleryWindowController`: content controller first, then the size —
/// assigning `contentViewController` replaces the window's content rect with the controller's
/// fitting size, so the intended size must be applied afterwards. Fixed-size and centered; a
/// walkthrough is a fixed composition, not a document.
///
/// During first launch this is the application's only window, and
/// `applicationShouldTerminateAfterLastWindowClosed` answers true — closing it abandons setup
/// and quits, and because nothing was recorded, the walkthrough returns on the next launch.
/// Finishing must therefore show the main window *before* this one closes; that ordering
/// lives in `AppDelegate.onboardingDidFinish`.
final class OnboardingWindowController: ThemedWindowController {

    private enum Defaults {
        static let size = NSSize(width: 760, height: 560)
    }

    convenience init(onFinish: @escaping () -> Void) {
        let flow = OnboardingFlowViewController(
            pages: [
                OnboardingAppearancePageViewController(),
                OnboardingDiscoveryPageViewController(),
                OnboardingImportPageViewController(),
                OnboardingNotificationsPageViewController()
            ],
            onFinish: onFinish
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Defaults.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Welcome to Threading")
        window.isReleasedWhenClosed = false
        window.contentViewController = flow

        self.init(window: window)

        window.setContentSize(Defaults.size)
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
