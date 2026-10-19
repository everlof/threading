import WebKit

/// An operation needs a host clock and runnable host/WebKit processes. Restore idle scheduling
/// when the final overlapping operation finishes, including failures and native deadlines.
@MainActor
final class BrowserExecutionActivity {
    private static let readinessProbe = "0"

    private struct Entry {
        var count: Int
        let restore: () -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var processActivity: (any NSObjectProtocol)?

    /// A cold detached page can stall async replies despite the temporary scheduling policy.
    /// The synchronous evaluation API acknowledges that WebKit is runnable before dispatching
    /// the operation. Its caller retains the activity and owns one deadline for both phases.
    func prepare(
        for page: WKWebView,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        guard page.window == nil else {
            completion(.success(()))
            return
        }
        page.evaluateJavaScript(Self.readinessProbe, in: nil, in: .defaultClient) { result in
            completion(result.map { _ in () })
        }
    }

    func begin(for page: WKWebView) -> () -> Void {
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
        return { self.end(key) }
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
        if let processActivity { ProcessInfo.processInfo.endActivity(processActivity) }
    }
}
