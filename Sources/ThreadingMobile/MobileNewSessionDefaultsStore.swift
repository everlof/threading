import Foundation
import ThreadingRemoteKit

/// The model and reasoning effort this phone most recently started successfully.
///
/// This is deliberately separate from `MobileSessionContinuityStore`: losing an optional run
/// preference may change the next draft's defaults, but it must never put an unsent prompt or a
/// saved viewport at risk. The Mac remains the authority for which values are currently valid.
struct MobileNewSessionRunChoice: Codable, Equatable, Sendable {
    let modelID: String?
    let reasoningID: String?

    init(modelID: String?, reasoningID: String?) {
        self.modelID = modelID?.isEmpty == false ? modelID : nil
        self.reasoningID = reasoningID?.isEmpty == false ? reasoningID : nil
    }
}

struct MobileNewSessionChoiceIdentity: Codable, Equatable, Hashable, Sendable {
    let hostID: String
    let agentID: String
    let accountID: String
}

/// Device-local last-successful run choices, scoped to the exact Mac, agent, and account.
///
/// Records are newest first and bounded. As with the other iOS defaults archives, a candidate is
/// validated, persisted, and read back before it becomes visible in memory. Corrupt bytes are
/// quarantined; a newer archive stays untouched and disables writes from this older build.
@MainActor
final class MobileNewSessionDefaultsStore {
    private struct Record: Codable, Equatable {
        let identity: MobileNewSessionChoiceIdentity
        let choice: MobileNewSessionRunChoice
    }

    private struct Archive: Codable, Equatable {
        var version: Int?
        var records: [Record]
    }

    static let archiveKey = "threading.mobile.new-session-defaults.v1"
    static let unreadableKeyPrefix = "threading.mobile.new-session-defaults.unreadable."
    static let archiveVersion = 1
    static let maximumArchiveBytes = 128 * 1024
    static let maximumRecordCount = 128
    static let maximumIdentifierBytes = 1024
    static let maximumAggregateStringBytes = 96 * 1024

    private let defaults: UserDefaults
    private var archive: Archive
    private var writesAllowed = true
    private(set) var recoveryMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let empty = Archive(version: Self.archiveVersion, records: [])
        guard let data = defaults.data(forKey: Self.archiveKey) else {
            archive = empty
            return
        }

        do {
            guard data.count <= Self.maximumArchiveBytes else {
                throw ValidationError.invalidArchive
            }
            var decoded = try JSONDecoder().decode(Archive.self, from: data)
            guard (decoded.version ?? 1) <= Self.archiveVersion else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved new-session defaults were created by a newer version."
                MobileDiagnostics.logDegraded(.newSessionDefaultsStorage, code: .newerFormat)
                return
            }
            decoded.version = Self.archiveVersion
            try Self.validate(decoded)
            archive = decoded
        } catch {
            MobileDiagnostics.logFailure(.newSessionDefaultsStorage, error: error)
            let recoveryKey = Self.unreadableKeyPrefix + UUID().uuidString.lowercased()
            defaults.set(data, forKey: recoveryKey)
            guard defaults.data(forKey: recoveryKey) == data else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved new-session defaults could not be preserved. Changes are paused."
                return
            }
            defaults.removeObject(forKey: Self.archiveKey)
            guard defaults.data(forKey: Self.archiveKey) == nil else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved new-session defaults could not be cleared safely. Changes are paused."
                return
            }
            archive = empty
            recoveryMessage = "Unreadable new-session defaults were preserved for recovery."
        }
    }

    func choice(for identity: MobileNewSessionChoiceIdentity) -> MobileNewSessionRunChoice? {
        archive.records.first { $0.identity == identity }?.choice
    }

    /// Called only after the Mac has accepted and created the session.
    @discardableResult
    func remember(
        _ choice: MobileNewSessionRunChoice,
        for identity: MobileNewSessionChoiceIdentity
    ) -> Bool {
        guard writesAllowed, choice.modelID != nil || choice.reasoningID != nil else {
            return false
        }
        var records = archive.records.filter { $0.identity != identity }
        records.insert(Record(identity: identity, choice: choice), at: 0)
        if records.count > Self.maximumRecordCount {
            records.removeLast(records.count - Self.maximumRecordCount)
        }
        return commit(Archive(version: Self.archiveVersion, records: records))
    }

    private func commit(_ candidate: Archive) -> Bool {
        do {
            try Self.validate(candidate)
        } catch {
            MobileDiagnostics.logFailure(.newSessionDefaultsStorage, code: .validation)
            recoveryMessage = "New-session defaults exceeded their safe storage limits and were not changed."
            return false
        }
        guard let data = try? JSONEncoder().encode(candidate),
              data.count <= Self.maximumArchiveBytes
        else {
            MobileDiagnostics.logFailure(.newSessionDefaultsStorage, code: .encode)
            recoveryMessage = "New-session defaults exceeded their safe storage limit and were not changed."
            return false
        }
        defaults.set(data, forKey: Self.archiveKey)
        guard defaults.data(forKey: Self.archiveKey) == data else {
            MobileDiagnostics.logFailure(.newSessionDefaultsStorage, code: .writeVerification)
            writesAllowed = false
            recoveryMessage = "New-session defaults could not be saved. Changes are paused."
            return false
        }
        archive = candidate
        recoveryMessage = nil
        return true
    }

    private enum ValidationError: Error {
        case invalidArchive
    }

    private static func validate(_ archive: Archive) throws {
        guard archive.records.count <= maximumRecordCount,
              Set(archive.records.map(\.identity)).count == archive.records.count
        else {
            throw ValidationError.invalidArchive
        }

        var aggregateBytes = 0
        func count(_ value: String?, required: Bool = false) throws {
            guard let value else {
                if required { throw ValidationError.invalidArchive }
                return
            }
            let bytes = value.utf8.count
            guard !value.isEmpty, bytes <= maximumIdentifierBytes else {
                throw ValidationError.invalidArchive
            }
            let (total, overflow) = aggregateBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= maximumAggregateStringBytes else {
                throw ValidationError.invalidArchive
            }
            aggregateBytes = total
        }

        for record in archive.records {
            try count(record.identity.hostID, required: true)
            try count(record.identity.agentID, required: true)
            try count(record.identity.accountID, required: true)
            try count(record.choice.modelID)
            try count(record.choice.reasoningID)
            guard record.choice.modelID != nil || record.choice.reasoningID != nil else {
                throw ValidationError.invalidArchive
            }
        }
    }
}

/// Pure resolution of stored, open-draft, and launch-time run choices against one live catalog.
enum SessionDraftRunChoiceResolution {
    static func initial(
        remembered: MobileNewSessionRunChoice?,
        defaultModelID: String?,
        models: [RemoteModelChoiceDTO]
    ) -> MobileNewSessionRunChoice {
        let defaultModel = liveDefaultModel(defaultModelID: defaultModelID, models: models)
        guard let remembered else {
            return concreteDefault(model: defaultModel)
        }

        let rememberedModel = remembered.modelID.flatMap { id in
            models.first { $0.id == id }
        }
        guard let selectedModel = rememberedModel ?? (remembered.modelID == nil ? defaultModel : nil)
        else {
            return concreteDefault(model: defaultModel)
        }
        return MobileNewSessionRunChoice(
            modelID: selectedModel.id,
            reasoningID: validReasoning(remembered.reasoningID, for: selectedModel)
                ?? liveDefaultReasoning(for: selectedModel)
        )
    }

    /// Preserve Auto (`nil`) while a draft is open. Only an explicit value withdrawn by the Mac
    /// is repaired; an invalid model falls back to the current live default.
    static func repair(
        current: MobileNewSessionRunChoice,
        defaultModelID: String?,
        models: [RemoteModelChoiceDTO]
    ) -> MobileNewSessionRunChoice {
        let defaultModel = liveDefaultModel(defaultModelID: defaultModelID, models: models)
        let explicitModel = current.modelID.flatMap { id in models.first { $0.id == id } }
        let selectedModel = explicitModel ?? (current.modelID == nil ? defaultModel : nil)
        guard let selectedModel else { return concreteDefault(model: defaultModel) }

        let repairedModelID = current.modelID != nil && explicitModel == nil
            ? selectedModel.id
            : current.modelID
        let repairedReasoningID: String?
        if current.reasoningID == nil {
            repairedReasoningID = nil
        } else {
            repairedReasoningID = validReasoning(current.reasoningID, for: selectedModel)
                ?? liveDefaultReasoning(for: selectedModel)
        }
        return MobileNewSessionRunChoice(
            modelID: repairedModelID,
            reasoningID: repairedReasoningID
        )
    }

    /// Turn Auto/default semantics into the concrete values the Mac currently advertises. The
    /// returned tuple is both the create request and, after success, the remembered choice.
    static func launch(
        current: MobileNewSessionRunChoice,
        defaultModelID: String?,
        models: [RemoteModelChoiceDTO]
    ) -> MobileNewSessionRunChoice {
        let repaired = repair(current: current, defaultModelID: defaultModelID, models: models)
        let selectedModel = repaired.modelID.flatMap { id in models.first { $0.id == id } }
            ?? liveDefaultModel(defaultModelID: defaultModelID, models: models)
        guard let selectedModel else { return MobileNewSessionRunChoice(modelID: nil, reasoningID: nil) }
        return MobileNewSessionRunChoice(
            modelID: selectedModel.id,
            reasoningID: validReasoning(repaired.reasoningID, for: selectedModel)
                ?? liveDefaultReasoning(for: selectedModel)
        )
    }

    private static func liveDefaultModel(
        defaultModelID: String?,
        models: [RemoteModelChoiceDTO]
    ) -> RemoteModelChoiceDTO? {
        defaultModelID.flatMap { id in models.first { $0.id == id } } ?? models.first
    }

    private static func concreteDefault(
        model: RemoteModelChoiceDTO?
    ) -> MobileNewSessionRunChoice {
        MobileNewSessionRunChoice(
            modelID: model?.id,
            reasoningID: model.flatMap { liveDefaultReasoning(for: $0) }
        )
    }

    private static func validReasoning(
        _ reasoningID: String?,
        for model: RemoteModelChoiceDTO
    ) -> String? {
        reasoningID.flatMap { id in model.reasoning.contains { $0.id == id } ? id : nil }
    }

    private static func liveDefaultReasoning(for model: RemoteModelChoiceDTO) -> String? {
        validReasoning(model.defaultReasoningID, for: model)
    }
}
