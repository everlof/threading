import Foundation

struct AppearanceActivationInventory: Sendable {
    struct InstalledExtension: Sendable {
        let name: String
        /// Why the extension cannot be enabled right now (invalid, mid-update), or nil.
        let unavailableReason: String?
    }

    let themeIDs: Set<String>
    let extensions: [String: InstalledExtension]
    var extensionsSuppressed = false
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
        case .setExtensionEnabled(let id, true):
            guard !snapshot.extensionsSuppressed else { throw AppearanceActivationError.suppressed }
            guard let installed = snapshot.extensions[id], installed.unavailableReason == nil else {
                throw AppearanceActivationError.extensionUnavailable(snapshot.extensions[id]?.name ?? id)
            }
        case .setExtensionEnabled(_, false), .reconcileInventory:
            break
        }
    }
}
