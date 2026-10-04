import Foundation

struct AppearanceActivationInventory: Sendable {
    struct Runtime: Sendable {
        enum Status: Equatable, Sendable {
            case stopped
            case starting
            case running
            case failed(String)
        }

        let name: String
        let contentDigest: String?
        let unavailableReason: String?
        let requiredExtensionIDs: Set<String>
        let status: Status
        var capabilitySummary: String? = nil
    }

    let themeIDs: Set<String>
    let extensions: [String: Runtime]
    var extensionsSuppressed = false

    func validate(_ pack: AppearancePack, manualExtensionIDs: Set<String>) throws {
        guard !extensionsSuppressed else { throw AppearanceActivationError.suppressed }
        guard themeIDs.contains(pack.themeID) else { throw AppearanceActivationError.themeUnavailable }
        let desired = manualExtensionIDs.union(pack.extensionIDs)
        for member in pack.extensions {
            guard let runtime = extensions[member.identifier], runtime.unavailableReason == nil else {
                throw AppearanceActivationError.extensionUnavailable(
                    extensions[member.identifier]?.name ?? member.identifier
                )
            }
            guard runtime.contentDigest == member.contentDigest else {
                throw AppearanceActivationError.reviewRequired(runtime.name)
            }
            for prerequisite in runtime.requiredExtensionIDs.sorted() {
                guard desired.contains(prerequisite),
                      extensions[prerequisite]?.unavailableReason == nil,
                      extensions[prerequisite] != nil else {
                    throw AppearanceActivationError.prerequisiteUnavailable(
                        extensions[prerequisite]?.name ?? prerequisite
                    )
                }
            }
        }
    }
}

protocol AppearanceActivationPersisting: Sendable {
    func save(_ state: AppearanceActivationState) async throws
}

/// Serializes host-owned choices; adapters own disk, AppKit and supervised processes. Commit
/// completes before the published state or its runtime projection changes.
@MainActor
final class AppearanceActivationService {
    private(set) var state: AppearanceActivationState
    private(set) var isChanging = false
    private let persistence: any AppearanceActivationPersisting
    private let inventory: () -> AppearanceActivationInventory
    private let beginMutation: () throws -> Void
    private let endMutation: () -> Void
    private let reconcile: (AppearanceActivationState, AppearanceActivationState) -> Void
    var didChange: () -> Void = {}

    init(
        state: AppearanceActivationState,
        persistence: any AppearanceActivationPersisting,
        inventory: @escaping () -> AppearanceActivationInventory,
        beginMutation: @escaping () throws -> Void = {},
        endMutation: @escaping () -> Void = {},
        reconcile: @escaping (AppearanceActivationState, AppearanceActivationState) -> Void
    ) {
        self.state = state
        self.persistence = persistence
        self.inventory = inventory
        self.beginMutation = beginMutation
        self.endMutation = endMutation
        self.reconcile = reconcile
    }

    func unavailableReason(for action: AppearanceActivationAction) -> String? {
        do {
            try validate(action)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func perform(_ action: AppearanceActivationAction) async throws {
        let next = try admittedState(for: action)
        guard next != state else { return }
        try beginMutation()
        isChanging = true
        didChange()
        defer {
            endMutation()
            isChanging = false
            didChange()
        }
        try await persistence.save(next)
        let previous = state
        state = next
        reconcile(previous, next)
    }

    private func admittedState(for action: AppearanceActivationAction) throws -> AppearanceActivationState {
        try validate(action)
        return try state.changing(action)
    }

    /// Catalogue availability must stay proportional to the requested action. Reducing and
    /// validating the whole durable record for every palette row made catalogue reads quadratic.
    private func validate(_ action: AppearanceActivationAction) throws {
        guard !isChanging else { throw AppearanceActivationError.changeInProgress }
        let snapshot = inventory()
        switch action {
        case .selectTheme(let id):
            guard snapshot.themeIDs.contains(id) else { throw AppearanceActivationError.themeUnavailable }
        case .activatePack(let id):
            guard let pack = state.packs.first(where: { $0.id == id }) else { throw AppearanceActivationError.packUnavailable }
            try snapshot.validate(pack, manualExtensionIDs: state.manuallyEnabledExtensionIDs)
        case .savePack(let pack):
            try pack.validate()
            guard state.packs.count < AppearancePack.maximumCount || state.packs.contains(where: { $0.id == pack.id }) else {
                throw AppearanceActivationError.invalidState
            }
            try snapshot.validate(pack, manualExtensionIDs: state.manuallyEnabledExtensionIDs)
        case .setExtensionEnabled(let id, true):
            guard !snapshot.extensionsSuppressed else { throw AppearanceActivationError.suppressed }
            guard let runtime = snapshot.extensions[id], runtime.unavailableReason == nil else {
                throw AppearanceActivationError.extensionUnavailable(snapshot.extensions[id]?.name ?? id)
            }
        case .deactivatePack, .removePack, .setExtensionEnabled(_, false), .reconcileInventory:
            break
        }
    }
}
