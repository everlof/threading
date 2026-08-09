import Foundation

/// How a project turns a pushed branch into a change request.
///
/// There is deliberately no "publish in the background" value. Even the two direct modes are
/// reached only by an explicit press of Git Review's Create button; the policy decides whether
/// that press opens the editor or sends the already visible proposal immediately.
enum ChangeRequestPublishPolicy: String, Codable, CaseIterable, Sendable {
    case reviewBeforePublishing
    case createDraft
    case createReady
    case pushOnly

    var title: String {
        switch self {
        case .reviewBeforePublishing: return L10n.string("Review before publishing")
        case .createDraft: return L10n.string("Create draft pull request")
        case .createReady: return L10n.string("Create ready pull request")
        case .pushOnly: return L10n.string("Never create pull requests")
        }
    }

    var explanation: String {
        switch self {
        case .reviewBeforePublishing:
            return L10n.string("Git Review lets you edit the pull request title and description first.")
        case .createDraft:
            return L10n.string("Git Review creates a draft pull request when you press Create.")
        case .createReady:
            return L10n.string("Git Review creates a ready pull request when you press Create.")
        case .pushOnly:
            return L10n.string("Git Review may push the branch, then stops there.")
        }
    }
}

struct ChangeRequestConfiguration: Codable, Equatable, Sendable {
    var publishPolicy: ChangeRequestPublishPolicy

    static let `default` = ChangeRequestConfiguration(
        publishPolicy: .reviewBeforePublishing
    )
}

struct ChangeRequestConfigurationDidChange: AppEvent {
    static let name = Notification.Name("ChangeRequestConfigurationDidChange")

    let repositoryIdentity: String
}

/// App-owned, repository-scoped change-request policy.
///
/// The UI hangs this setting from a project because that is where a person has the context to
/// choose it. Its durable key is git's common directory, however, so linked worktrees and two
/// project rows pointing into the same repository cannot acquire contradictory publishing
/// behavior. Nothing is written into the checkout and switching branches cannot change it.
@MainActor
final class ChangeRequestConfigurationStore {
    static let shared = ChangeRequestConfigurationStore()

    private struct State: Codable {
        var configurations: [String: ChangeRequestConfiguration] = [:]
    }

    private enum Defaults {
        static let key = "changeRequest.repositoryConfigurations.v1"
    }

    private let userDefaults: UserDefaults
    private var state: State

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Defaults.key),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    func configuration(forProjectPath path: String) -> ChangeRequestConfiguration {
        guard let identity = GitInfo.repositoryIdentity(for: path) else { return .default }
        return state.configurations[identity] ?? .default
    }

    func set(_ configuration: ChangeRequestConfiguration, forProjectPath path: String) {
        guard let identity = GitInfo.repositoryIdentity(for: path) else { return }

        if configuration == .default {
            state.configurations.removeValue(forKey: identity)
        } else {
            state.configurations[identity] = configuration
        }
        persist()
        NotificationCenter.default.post(ChangeRequestConfigurationDidChange(
            repositoryIdentity: identity
        ))
    }

    func setPublishPolicy(_ policy: ChangeRequestPublishPolicy, forProjectPath path: String) {
        set(ChangeRequestConfiguration(publishPolicy: policy), forProjectPath: path)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: Defaults.key)
    }
}
