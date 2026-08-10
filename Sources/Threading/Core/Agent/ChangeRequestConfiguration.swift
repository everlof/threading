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
        static let maximumConfigurations = 1_024
        static let maximumRepositoryIdentityBytes = 4 * 1_024
    }

    private enum ValidationError: Error {
        case invalidRepositorySet
    }

    private let persistence: RecoverableDefaultsStore<State>
    private var state: State

    init(userDefaults: UserDefaults = .standard) {
        let persistence = RecoverableDefaultsStore<State>(
            defaults: userDefaults,
            key: Defaults.key,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.state = persistence.load(
            defaultValue: State(),
            validate: Self.validate
        ).value
    }

    func configuration(forProjectPath path: String) -> ChangeRequestConfiguration {
        guard let identity = GitInfo.repositoryIdentity(for: path) else { return .default }
        return state.configurations[identity] ?? .default
    }

    @discardableResult
    func set(
        _ configuration: ChangeRequestConfiguration,
        forProjectPath path: String
    ) -> Bool {
        guard let identity = GitInfo.repositoryIdentity(for: path),
              !identity.isEmpty,
              identity.utf8.count <= Defaults.maximumRepositoryIdentityBytes else {
            return false
        }

        var candidate = state
        if configuration == .default {
            candidate.configurations.removeValue(forKey: identity)
        } else {
            candidate.configurations[identity] = configuration
        }
        guard candidate.configurations != state.configurations else { return true }
        do {
            try Self.validate(candidate)
        } catch {
            ThreadingLogger.session.error(
                "Refusing oversized change-request configuration state"
            )
            return false
        }
        guard persistence.save(candidate) else { return false }
        state = candidate
        NotificationCenter.default.post(ChangeRequestConfigurationDidChange(
            repositoryIdentity: identity
        ))
        return true
    }

    @discardableResult
    func setPublishPolicy(
        _ policy: ChangeRequestPublishPolicy,
        forProjectPath path: String
    ) -> Bool {
        set(ChangeRequestConfiguration(publishPolicy: policy), forProjectPath: path)
    }

    private static func validate(_ state: State) throws {
        guard state.configurations.count <= Defaults.maximumConfigurations,
              state.configurations.keys.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= Defaults.maximumRepositoryIdentityBytes
              }) else {
            throw ValidationError.invalidRepositorySet
        }
    }
}
