import AppKit

/// Base class for every application-owned top-level window.
///
/// Source linting requires window controllers to enter through this type. In debug builds it
/// audits the fully expanded content tree after the window is shown, resized, or repainted for a
/// theme change. Release builds pay nothing; build-time lint and render tests remain the shipped
/// enforcement layers.
class ThemedWindowController: NSWindowController {

#if DEBUG
    private var auditIsScheduled = false
#endif

    override init(window: NSWindow?) {
        super.init(window: window)
        installThemeBoundaryAudit(for: window)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installThemeBoundaryAudit(for: window)
    }

    deinit {
#if DEBUG
        NotificationCenter.default.removeObserver(self)
#endif
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        scheduleThemeBoundaryAudit()
    }

#if DEBUG
    private func installThemeBoundaryAudit(for window: NSWindow?) {
        guard let window else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowNeedsThemeBoundaryAudit),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowNeedsThemeBoundaryAudit),
            name: AppThemeDidChange.name,
            object: nil
        )
    }

    @objc private func windowNeedsThemeBoundaryAudit(_ notification: Notification) {
        scheduleThemeBoundaryAudit()
    }

    /// Coalesces the notifications AppKit emits while constructing or resizing a window, then
    /// audits on the next run-loop turn after it has installed private wrapper views.
    private func scheduleThemeBoundaryAudit() {
        guard !auditIsScheduled else { return }
        auditIsScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.auditIsScheduled = false
            guard let window = self.window, window.isVisible else { return }

            let violations = ThemeBoundaryAudit.violations(in: window)
            guard !violations.isEmpty else { return }

            assertionFailure(
                ThemeBoundaryAudit.failureDescription(
                    for: violations,
                    windowTitle: window.title.isEmpty
                        ? String(describing: type(of: self))
                        : window.title
                )
            )
        }
    }
#else
    private func installThemeBoundaryAudit(for window: NSWindow?) {}
    private func scheduleThemeBoundaryAudit() {}
#endif
}
