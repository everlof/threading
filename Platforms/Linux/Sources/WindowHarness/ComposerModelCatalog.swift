#if os(Linux)
import AppKit
import Foundation
@testable import CoreSlice

/// An admitted account snapshot. File bytes and provider-sized decoding never reach the UI.
struct ComposerModelCatalog: Sendable {
    static let maximumModels = 512
    static let maximumEfforts = 32
    let options: [AgentModelOption]
    let optionIndices: [String: Int]
    let defaultModel: String?
    let defaultEffort: String?
    let inheritedFastMode: Bool?
    let inheritedPermissionMode: AgentPermissionMode?
    let lastUsedPermissionMode: AgentPermissionMode?

    static let empty = ComposerModelCatalog(options: [], optionIndices: [:], defaultModel: nil, defaultEffort: nil,
                                            inheritedFastMode: nil, inheritedPermissionMode: nil,
                                            lastUsedPermissionMode: nil)

    func option(for id: String?) -> AgentModelOption? {
        guard let id, let index = optionIndices[id] else { return nil }
        return options[index]
    }

    var defaultOption: AgentModelOption? { option(for: defaultModel) }

    func supportsFastMode(kind: AgentKind, model: String?) -> Bool {
        let effective = model ?? defaultModel
        if kind.supports(.liveFastModeControl) {
            return effective?.localizedCaseInsensitiveContains(AgentDefaults.claudeFastModeFamily) == true
        }
        guard kind.supports(.serviceTierFastMode) else { return false }
        return option(for: effective)?.supportsFastMode == true
    }

    func speedTitle(selected: Bool?, kind: AgentKind) -> String {
        switch selected ?? inheritedFastMode {
        case true: "Fast"
        case false: "Standard"
        case nil: "Agent's Setting"
        }
    }

    func admits(model: String?, effort: String?) -> Bool {
        if model == nil, effort == nil { return true }
        guard let option = option(for: model ?? defaultModel) else { return false }
        return option.supports(reasoningEffort: effort)
    }

    static func read(for account: AccountID, projectDirectory: String? = nil) -> Self {
        guard let path = try? GraphicalTerminal.accountPath(for: account.provider, handle: account.handle)
        else { return .empty }
        return read(provider: account.provider,
                    directory: URL(fileURLWithPath: path, isDirectory: true),
                    projectDirectory: projectDirectory)
    }

    static func read(provider: AgentKind, directory: URL, projectDirectory: String? = nil) -> Self {
        let options: [AgentModelOption]
        let configuredModel: String?
        let configuredEffort: String?
        let configuredFastMode: Bool?
        let configuredPermissionMode: AgentPermissionMode?
        let lastUsedPermissionMode: AgentPermissionMode?
        switch provider {
        case .codex:
            lastUsedPermissionMode = nil
            let config = readData(directory.appendingPathComponent(AgentDefaults.codexConfigFile), limit: 1_048_576)
                .flatMap { String(data: $0, encoding: .utf8) }
                .map(ProviderModelCatalog.codexAssignments) ?? [:]
            configuredModel = config[AgentDefaults.codexModelKey]
            configuredEffort = config[AgentDefaults.codexReasoningEffortKey]
            configuredPermissionMode = AgentPermissionMode(
                codexApprovalPolicy: config[AgentDefaults.codexApprovalPolicyKey],
                sandboxMode: config[AgentDefaults.codexSandboxModeKey],
                approvalsReviewer: config[AgentDefaults.codexApprovalsReviewerKey])
            switch config[AgentDefaults.codexServiceTierKey] {
            case AgentDefaults.codexFastServiceTier, AgentDefaults.codexFastServiceTierAlias:
                configuredFastMode = true
            case AgentDefaults.codexStandardServiceTier:
                configuredFastMode = false
            default:
                configuredFastMode = nil
            }
            options = readData(directory.appendingPathComponent(AgentDefaults.codexModelsCacheFile), limit: 16_777_216)
                .flatMap(ProviderModelCatalog.decodeCodex)?.options ?? []
        case .claude:
            let settings = readObject(directory.appendingPathComponent(AgentDefaults.claudeSettingsFile))
            let state = readObject(directory.appendingPathComponent(AgentDefaults.claudeStateFile))
            configuredModel = settings[AgentDefaults.claudeModelKey] as? String
                ?? ProviderModelCatalog.organisationModel(inClaudeState: state)
            configuredEffort = settings[AgentDefaults.claudeEffortKey] as? String
            let projectSettings = projectDirectory.map { path in
                URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent(".claude", isDirectory: true)
            }
            configuredFastMode = projectSettings.flatMap {
                readObject($0.appendingPathComponent("settings.local.json"))[AgentDefaults.claudeFastModeKey] as? Bool
                    ?? readObject($0.appendingPathComponent(AgentDefaults.claudeSettingsFile))[
                        AgentDefaults.claudeFastModeKey] as? Bool
            } ?? settings[AgentDefaults.claudeFastModeKey] as? Bool ?? false
            let permissionLayers: [(mode: String?, mayGrantAuto: Bool)] = [
                (projectSettings.flatMap {
                    readObject($0.appendingPathComponent("settings.local.json"))["permissions"]
                        .flatMap { ($0 as? [String: Any])?["defaultMode"] as? String }
                }, false),
                (projectSettings.flatMap {
                    readObject($0.appendingPathComponent(AgentDefaults.claudeSettingsFile))["permissions"]
                        .flatMap { ($0 as? [String: Any])?["defaultMode"] as? String }
                }, false),
                ((settings["permissions"] as? [String: Any])?["defaultMode"] as? String, true)
            ]
            if let layer = permissionLayers.first(where: { $0.mode != nil }),
               let value = layer.mode,
               let mode = AgentPermissionMode(externalValue: value, for: .claude),
               mode != .auto || layer.mayGrantAuto {
                configuredPermissionMode = mode
            } else {
                configuredPermissionMode = nil
            }
            lastUsedPermissionMode = configuredPermissionMode == nil
                ? ComposerRecentPermissionMode.read(in: directory) : nil
            options = AgentDefaults.claudeModels.map {
                ProviderModelCatalog.claudeOption(identifier: $0, displayName: ModelName.display(for: $0))
            } + ProviderModelCatalog.additionalModels(inClaudeState: state)
        case .grok, .openCode, .cursor:
            return .empty
        }
        var models: [AgentModelOption] = []
        var seenModels: Set<String> = []
        var admittedEfforts: Set<String> = []
        for option in options {
            guard let id = identifier(option.identifier, maximumBytes: 512),
                  seenModels.insert(id).inserted else { continue }
            var levels: [AgentReasoningLevel] = []
            var seenLevels: Set<String> = []
            for level in option.reasoningLevels {
                guard let effort = identifier(level.effort, maximumBytes: 64),
                      seenLevels.insert(effort).inserted,
                      admittedEfforts.contains(effort) || admittedEfforts.count < maximumEfforts else { continue }
                admittedEfforts.insert(effort)
                levels.append(AgentReasoningLevel(effort: effort, description: String(level.description.prefix(256))))
            }
            let name = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            models.append(AgentModelOption(identifier: id,
                displayName: String((name.isEmpty ? id : name).prefix(160)),
                fastServiceTier: option.fastServiceTier, defaultServiceTier: option.defaultServiceTier,
                defaultReasoningLevel: option.defaultReasoningLevel, reasoningLevels: levels))
            if models.count == maximumModels { break }
        }
        let defaultModel = identifier(configuredModel, maximumBytes: 512)
        let fastMode = configuredFastMode ?? models.first(where: { $0.identifier == defaultModel })
            .flatMap { option in
                option.defaultServiceTier.map { $0 == option.fastServiceTier }
            }
        let indices = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($0.element.identifier, $0.offset) })
        return Self(options: models, optionIndices: indices, defaultModel: defaultModel,
                    defaultEffort: identifier(configuredEffort, maximumBytes: 64),
                    inheritedFastMode: fastMode, inheritedPermissionMode: configuredPermissionMode,
                    lastUsedPermissionMode: lastUsedPermissionMode)
    }

    private static func identifier(_ value: String?, maximumBytes: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    private static func readData(_ url: URL, limit: Int) -> Data? {
        try? BoundedFileReader.read(url, maximumBytes: limit)
    }

    private static func readObject(_ url: URL) -> [String: Any] {
        guard let data = readData(url, limit: 1_048_576),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// One active read and one coalesced pending request. An account change invalidates the old
/// receipt before it can replace the new account's choices or retain another catalogue.
@MainActor
final class ComposerModelCatalogLoader {
    private struct Request: Sendable {
        let id: UUID
        let account: AccountID
        let projectDirectory: String?
        let completion: @MainActor @Sendable (
            ComposerModelCatalog, Set<String>, ComposerNewSessionRunChoice?
        ) -> Void
    }
    private let worker = DispatchQueue(label: "threading.linux.composer-models", qos: .userInitiated)
    private var latest = UUID()
    private var pending: Request?
    private var busy = false

    func load(_ account: AccountID, projectDirectory: String?,
              completion: @escaping @MainActor @Sendable (
                  ComposerModelCatalog, Set<String>, ComposerNewSessionRunChoice?
              ) -> Void) {
        latest = UUID()
        pending = Request(id: latest, account: account, projectDirectory: projectDirectory,
                          completion: completion)
        startPending()
    }

    func cancel() {
        latest = UUID()
        pending = nil
    }

    /// UI admission allows only one mutation at a time. This queue serializes it with reads.
    func changeVisibility(_ change: ComposerModelVisibilityStore.Change, for account: AccountID,
                          completion: @escaping @MainActor @Sendable (Set<String>?) -> Void) {
        worker.async {
            let result = ComposerModelVisibilityStore.apply(change, for: account)
            NSWindowWorkerDelivery.shared.deliver { completion(result) }
        }
    }

    func remember(_ choice: ComposerNewSessionRunChoice, for account: AccountID) {
        worker.async {
            if !ComposerNewSessionRunChoiceStore.set(choice, for: account) {
                print("NEW_SESSION_RUN_CHOICE_REFUSED")
            }
        }
    }

    private func startPending() {
        guard !busy, let request = pending else { return }
        pending = nil
        busy = true
        worker.async { [weak self] in
            let catalogue = ComposerModelCatalog.read(for: request.account,
                                                      projectDirectory: request.projectDirectory)
            let hidden = ComposerModelVisibilityStore.hiddenModelIDs(for: request.account)
            let remembered = ComposerNewSessionRunChoiceStore.choice(for: request.account)
            NSWindowWorkerDelivery.shared.deliver { [weak self] in
                guard let self else { return }
                self.busy = false
                if request.id == self.latest { request.completion(catalogue, hidden, remembered) }
                self.startPending()
            }
        }
    }
}
#endif
