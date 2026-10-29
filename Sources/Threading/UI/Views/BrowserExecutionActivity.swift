import WebKit

/// An operation needs runnable host/WebKit processes while native keyboard focus stays user-owned.
/// Restore idle scheduling when the final overlapping operation finishes, including failures
/// and native deadlines.
@MainActor
final class BrowserExecutionActivity {
    private struct Entry {
        var count: Int
        let restore: () -> Void
    }

    private struct RenderingEntry {
        var count: Int
        let host: BackgroundRenderingHost
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var renderingEntries: [ObjectIdentifier: RenderingEntry] = [:]
    private var processActivity: (any NSObjectProtocol)?
    private var presentationUpdateScheduled = false

    func begin(for page: WKWebView) -> () -> Void {
        let finishKeyboardFocus = BrowserKeyboardFocus.beginAgentOperation(on: page)
        let preferences = page.configuration.preferences
        let key = ObjectIdentifier(preferences)
        if entries.isEmpty {
            processActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Completing an agent browser operation"
            )
        }
        if var entry = entries[key] {
            entry.count += 1
            entries[key] = entry
        } else {
            let restore: () -> Void
            if #available(macOS 14.0, *) {
                let previous = preferences.inactiveSchedulingPolicy
                preferences.inactiveSchedulingPolicy = .none
                restore = { preferences.inactiveSchedulingPolicy = previous }
            } else {
                restore = {}
            }
            entries[key] = Entry(count: 1, restore: restore)
        }
        let pageKey = ObjectIdentifier(page)
        if var entry = renderingEntries[pageKey] {
            entry.count += 1
            renderingEntries[pageKey] = entry
        } else if page.superview != nil {
            renderingEntries[pageKey] = RenderingEntry(
                count: 1, host: BackgroundRenderingHost(content: page)
            )
        }
        var finished = false
        return {
            guard !finished else { return }
            finished = true
            self.endRendering(pageKey)
            self.end(key)
            finishKeyboardFocus()
        }
    }

    func updatePresentation() {
        // Only operations currently in flight, never all retained tabs or sessions.
        for entry in renderingEntries.values { entry.host.update() }
    }

    func presentationDidChange() {
        updatePresentation()
        guard !renderingEntries.isEmpty, !presentationUpdateScheduled else { return }
        presentationUpdateScheduled = true
        // AppKit reports a child's window attachment before DisplayPane finishes unhiding its
        // ancestor. Recheck once after that hierarchy transaction, coalescing its callbacks.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationUpdateScheduled = false
            self.updatePresentation()
        }
    }

    func setFrame(_ frame: CGRect, for page: WKWebView) {
        if let entry = renderingEntries[ObjectIdentifier(page)] {
            entry.host.setFrame(frame)
        } else {
            page.frame = frame
        }
    }

    func isRenderingInBackground(_ page: WKWebView) -> Bool {
        renderingEntries[ObjectIdentifier(page)]?.host.isRenderingInBackground == true
    }

    private func endRendering(_ key: ObjectIdentifier) {
        guard var entry = renderingEntries[key] else { return }
        entry.count -= 1
        if entry.count > 0 {
            renderingEntries[key] = entry
        } else {
            renderingEntries.removeValue(forKey: key)
            entry.host.restore()
        }
    }

    private func end(_ key: ObjectIdentifier) {
        guard var entry = entries[key] else { return }
        entry.count -= 1
        if entry.count > 0 {
            entries[key] = entry
        } else {
            entries.removeValue(forKey: key)
            entry.restore()
            if entries.isEmpty, let processActivity {
                ProcessInfo.processInfo.endActivity(processActivity)
                self.processActivity = nil
            }
        }
    }

    isolated deinit {
        for entry in entries.values { entry.restore() }
        if let processActivity { ProcessInfo.processInfo.endActivity(processActivity) }
    }
}
