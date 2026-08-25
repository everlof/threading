import Foundation

/// Keeps an enabled Remote Access listener schedulable while the app has no visible windows.
///
/// Remote Access still allows the Mac to enter ordinary idle sleep. This activity only prevents
/// App Nap, automatic termination, and sudden termination from starving the process that owns the
/// listener while the machine is awake.
@MainActor
protocol RemoteAccessProcessActivityManaging: AnyObject {
    func begin()
    func end()
}

@MainActor
final class RemoteAccessProcessActivity: RemoteAccessProcessActivityManaging {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    static let reason = "Serving enabled Remote Access connections"

    private let beginActivity: () -> any NSObjectProtocol
    private let endActivity: (any NSObjectProtocol) -> Void
    private var token: (any NSObjectProtocol)?

    convenience init(processInfo: ProcessInfo = .processInfo) {
        self.init(
            beginActivity: {
                processInfo.beginActivity(options: Self.options, reason: Self.reason)
            },
            endActivity: { processInfo.endActivity($0) }
        )
    }

    init(
        beginActivity: @escaping () -> any NSObjectProtocol,
        endActivity: @escaping (any NSObjectProtocol) -> Void
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func begin() {
        guard token == nil else { return }
        token = beginActivity()
    }

    func end() {
        guard let token else { return }
        endActivity(token)
        self.token = nil
    }

    deinit {
        if let token { endActivity(token) }
    }
}
