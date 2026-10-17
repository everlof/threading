#if os(Linux)
import AppKit
import Foundation
@testable import CoreSlice

/// An admitted account snapshot. File bytes and provider-sized decoding never reach the UI.
struct ComposerModelCatalog: Sendable {
    static let maximumModels = 512
    static let maximumEfforts = 32
    let options: [AgentModelOption]
    let defaultModel: String?
    let defaultEffort: String?

    static let empty = ComposerModelCatalog(options: [], defaultModel: nil, defaultEffort: nil)

    var defaultOption: AgentModelOption? { options.first { $0.identifier == defaultModel } }

    func admits(model: String?, effort: String?) -> Bool {
        if model == nil, effort == nil { return true }
        guard let effective = model ?? defaultModel,
              let option = options.first(where: { $0.identifier == effective }) else { return false }
        return option.supports(reasoningEffort: effort)
    }

    static func read(for account: AccountID) -> Self {
        guard let path = try? GraphicalTerminal.accountPath(for: account.provider, handle: account.handle)
        else { return .empty }
        return read(provider: account.provider, directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    static func read(provider: AgentKind, directory: URL) -> Self {
        let options: [AgentModelOption]
        let configuredModel: String?
        let configuredEffort: String?
        switch provider {
        case .codex:
            let config = readData(directory.appendingPathComponent(AgentDefaults.codexConfigFile), limit: 1_048_576)
                .flatMap { String(data: $0, encoding: .utf8) }
                .map(ProviderModelCatalog.codexAssignments) ?? [:]
            configuredModel = config[AgentDefaults.codexModelKey]
            configuredEffort = config[AgentDefaults.codexReasoningEffortKey]
            options = readData(directory.appendingPathComponent(AgentDefaults.codexModelsCacheFile), limit: 16_777_216)
                .flatMap(ProviderModelCatalog.decodeCodex)?.options ?? []
        case .claude:
            let settings = readObject(directory.appendingPathComponent(AgentDefaults.claudeSettingsFile))
            let state = readObject(directory.appendingPathComponent(AgentDefaults.claudeStateFile))
            configuredModel = settings[AgentDefaults.claudeModelKey] as? String
                ?? ProviderModelCatalog.organisationModel(inClaudeState: state)
            configuredEffort = settings[AgentDefaults.claudeEffortKey] as? String
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
        return Self(options: models, defaultModel: identifier(configuredModel, maximumBytes: 512),
                    defaultEffort: identifier(configuredEffort, maximumBytes: 64))
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
        let completion: @MainActor @Sendable (ComposerModelCatalog) -> Void
    }
    private let worker = DispatchQueue(label: "threading.linux.composer-models", qos: .userInitiated)
    private var latest = UUID()
    private var pending: Request?
    private var busy = false

    func load(_ account: AccountID, completion: @escaping @MainActor @Sendable (ComposerModelCatalog) -> Void) {
        latest = UUID()
        pending = Request(id: latest, account: account, completion: completion)
        startPending()
    }

    func cancel() {
        latest = UUID()
        pending = nil
    }

    private func startPending() {
        guard !busy, let request = pending else { return }
        pending = nil
        busy = true
        worker.async { [weak self] in
            let catalogue = ComposerModelCatalog.read(for: request.account)
            NSWindowWorkerDelivery.shared.deliver { [weak self] in
                guard let self else { return }
                self.busy = false
                if request.id == self.latest { request.completion(catalogue) }
                self.startPending()
            }
        }
    }
}
#endif
