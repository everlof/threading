import Foundation

enum Pymobiledevice3SettingsState: Equatable, Sendable {
    case checking
    case absent
    case installed(version: String, executable: URL)
    case installing(previous: Pymobiledevice3InstalledTool?)
    case failed(message: String, previous: Pymobiledevice3InstalledTool?)

    var installedTool: Pymobiledevice3InstalledTool? {
        switch self {
        case .installed(let version, let executable):
            return Pymobiledevice3InstalledTool(version: version, executable: executable)
        case .installing(let previous), .failed(_, let previous):
            return previous
        case .checking, .absent:
            return nil
        }
    }

    var isWorking: Bool {
        switch self {
        case .checking, .installing:
            return true
        case .absent, .installed, .failed:
            return false
        }
    }
}

private enum Pymobiledevice3InstallOutcome: Sendable {
    case installed(Pymobiledevice3InstalledTool)
    case failed(String)
}

/// The Advanced page's asynchronous view of the managed iPhone tool.
///
/// Process and filesystem work stay behind the injected closures so the Settings controller only
/// observes a small value state. Hosted tests never inspect or write the developer's real support
/// directory; rendered states are supplied explicitly.
@MainActor
final class Pymobiledevice3SettingsSurface {
    var onChange: (() -> Void)?

    private(set) var state: Pymobiledevice3SettingsState
    private let automaticallyRefreshes: Bool
    private let readStatus: @Sendable () -> Pymobiledevice3ManagedStatus
    private let install: @Sendable () throws -> Pymobiledevice3InstalledTool
    private let notificationCenter: NotificationCenter
    private var task: Task<Void, Never>?

    init(
        installation: Pymobiledevice3Installation = Pymobiledevice3Installation(),
        initialState: Pymobiledevice3SettingsState = .checking,
        automaticallyRefreshes: Bool = !StateManager.isHostedTest,
        notificationCenter: NotificationCenter = .default
    ) {
        self.state = initialState
        self.automaticallyRefreshes = automaticallyRefreshes
        self.notificationCenter = notificationCenter
        self.readStatus = { installation.status() }
        self.install = { try installation.installLatest() }
    }

    init(
        initialState: Pymobiledevice3SettingsState,
        readStatus: @escaping @Sendable () -> Pymobiledevice3ManagedStatus,
        install: @escaping @Sendable () throws -> Pymobiledevice3InstalledTool,
        notificationCenter: NotificationCenter = .default
    ) {
        state = initialState
        automaticallyRefreshes = false
        self.readStatus = readStatus
        self.install = install
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard automaticallyRefreshes else { return }
        refresh()
    }

    func refresh() {
        guard task == nil else { return }
        state = .checking
        onChange?()
        task = Task.detached(priority: .utility) { [readStatus] in
            let status = readStatus()
            await MainActor.run { [weak self] in
                guard let self else { return }
                task = nil
                switch status {
                case .absent:
                    state = .absent
                case .installed(let version, let executable):
                    state = .installed(version: version, executable: executable)
                case .damaged:
                    state = .failed(
                        message: AdvancedStrings.iphoneToolingDamaged,
                        previous: nil
                    )
                }
                onChange?()
            }
        }
    }

    func installLatest() {
        guard task == nil else { return }
        let previous = state.installedTool
        state = .installing(previous: previous)
        onChange?()

        task = Task.detached(priority: .userInitiated) { [install] in
            let outcome: Pymobiledevice3InstallOutcome
            do {
                outcome = .installed(try install())
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.task = nil
                switch outcome {
                case .installed(let tool):
                    self.state = .installed(version: tool.version, executable: tool.executable)
                    self.notificationCenter.post(Pymobiledevice3ToolDidInstall())
                case .failed(let message):
                    self.state = .failed(message: message, previous: previous)
                }
                self.onChange?()
            }
        }
    }
}
