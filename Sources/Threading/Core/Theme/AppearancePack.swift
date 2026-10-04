import Foundation
import ThreadingExtensionKit

/// A host-owned receipt for a reviewed combination of already installed content. Identity and
/// recipe revision are independent of the name, so renaming never changes a shortcut binding.
struct AppearancePack: Codable, Equatable, Sendable, Identifiable {
    static let maximumCount = 256
    static let maximumMembers = 16
    static let maximumNameLength = 120

    struct Member: Codable, Equatable, Sendable {
        let identifier: String
        let contentDigest: String
    }

    let id: UUID
    let recipeRevision: UUID
    let name: String
    let themeID: String
    let extensions: [Member]

    var extensionIDs: Set<String> { Set(extensions.map(\.identifier)) }

    var orderedMembers: [Member] { extensions.sorted { $0.identifier < $1.identifier } }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= Self.maximumNameLength,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !themeID.isEmpty, themeID.utf8.count <= 512,
              extensions.count <= Self.maximumMembers,
              extensionIDs.count == extensions.count else {
            throw AppearanceActivationError.invalidPack
        }
        for member in extensions {
            guard ExtensionIdentifierRules.isReverseDNSIdentifier(member.identifier),
                  member.contentDigest.count == 64,
                  member.contentDigest.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  }) else {
                throw AppearanceActivationError.invalidPack
            }
        }
    }
}

/// The only persisted owner of theme selection and runtime enablement after migration.
/// Runtime status, decoded assets and personal motion/audio choices are deliberately absent.
struct AppearanceActivationState: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var revision: UInt64 = 0
    var standaloneThemeID: String
    var manuallyEnabledExtensionIDs: Set<String>
    var packs: [AppearancePack] = []
    var activePackID: UUID?

    var activePack: AppearancePack? {
        guard let activePackID else { return nil }
        return packs.first { $0.id == activePackID }
    }
    var selectedThemeID: String { activePack?.themeID ?? standaloneThemeID }
    var desiredExtensionIDs: Set<String> {
        manuallyEnabledExtensionIDs.union(activePack?.extensionIDs ?? [])
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              !standaloneThemeID.isEmpty, standaloneThemeID.utf8.count <= 512,
              packs.count <= AppearancePack.maximumCount,
              Set(packs.map(\.id)).count == packs.count,
              activePackID == nil || activePack != nil,
              manuallyEnabledExtensionIDs.count <= ExtensionPackageStore.maximumInstalledPackages,
              manuallyEnabledExtensionIDs.allSatisfy(ExtensionIdentifierRules.isReverseDNSIdentifier)
        else { throw AppearanceActivationError.invalidState }
        try packs.forEach { try $0.validate() }
    }

    func changing(_ action: AppearanceActivationAction) throws -> Self {
        var next = self
        switch action {
        case .selectTheme(let id):
            next.standaloneThemeID = id
            next.activePackID = nil
        case .activatePack(let id):
            guard packs.contains(where: { $0.id == id }) else {
                throw AppearanceActivationError.packUnavailable
            }
            next.activePackID = id
        case .deactivatePack(let id):
            if activePackID == id { next.activePackID = nil }
        case .setExtensionEnabled(let id, let enabled):
            if enabled {
                next.manuallyEnabledExtensionIDs.insert(id)
            } else {
                next.manuallyEnabledExtensionIDs.remove(id)
                if activePack?.extensionIDs.contains(id) == true { next.activePackID = nil }
            }
        case .savePack(let pack):
            try pack.validate()
            if let index = next.packs.firstIndex(where: { $0.id == pack.id }) {
                let previous = packs[index]
                if previous.themeID != pack.themeID || previous.orderedMembers != pack.orderedMembers {
                    guard previous.recipeRevision != pack.recipeRevision else { throw AppearanceActivationError.invalidPack }
                }
                if activePackID == pack.id, packs[index].recipeRevision != pack.recipeRevision {
                    next.activePackID = nil
                }
                next.packs[index] = pack
            } else {
                next.packs.append(pack)
            }
        case .removePack(let id):
            next.packs.removeAll { $0.id == id }
            if activePackID == id { next.activePackID = nil }
        case .reconcileInventory(let themeIDs, let extensionIDs, let fallbackThemeID):
            next.manuallyEnabledExtensionIDs.formIntersection(extensionIDs)
            if !themeIDs.contains(standaloneThemeID) { next.standaloneThemeID = fallbackThemeID }
            if let pack = activePack,
               !themeIDs.contains(pack.themeID) || !pack.extensionIDs.isSubset(of: extensionIDs) {
                next.activePackID = nil
            }
        }
        guard next != self else { return self }
        guard revision < UInt64.max else { throw AppearanceActivationError.invalidState }
        next.revision += 1
        try next.validate()
        return next
    }
}

enum AppearanceActivationAction: Equatable, Sendable {
    case selectTheme(String)
    case activatePack(UUID)
    case deactivatePack(UUID)
    case setExtensionEnabled(String, Bool)
    case savePack(AppearancePack)
    case removePack(UUID)
    case reconcileInventory(themeIDs: Set<String>, extensionIDs: Set<String>, fallbackThemeID: String)
}

enum AppearanceActivationError: LocalizedError {
    case invalidPack
    case invalidState
    case packUnavailable
    case themeUnavailable
    case extensionUnavailable(String)
    case reviewRequired(String)
    case prerequisiteUnavailable(String)
    case changeInProgress
    case persistenceFailed
    case recoveryRequired
    case suppressed

    var errorDescription: String? {
        switch self {
        case .invalidPack:
            return L10n.string("The appearance pack has an invalid name, theme or extension list.")
        case .invalidState:
            return L10n.string("The saved appearance choices could not be read.")
        case .packUnavailable:
            return L10n.string("This appearance pack is no longer available.")
        case .themeUnavailable:
            return L10n.string("This theme is no longer available.")
        case .extensionUnavailable(let name):
            return L10n.format("The extension %@ is unavailable.", name)
        case .reviewRequired(let name):
            return L10n.format("%@ has changed. Edit the pack to review its current contents.", name)
        case .prerequisiteUnavailable(let name):
            return L10n.format("Enable or include the required extension %@ first.", name)
        case .changeInProgress:
            return L10n.string("Another appearance change is in progress. Try again when it finishes.")
        case .persistenceFailed:
            return L10n.string("The appearance change could not be saved. Your previous choices are still in use.")
        case .recoveryRequired:
            return L10n.string("Saved appearance choices need recovery. The unreadable file has been preserved.")
        case .suppressed:
            return L10n.string("Appearance packs are unavailable while extensions are held back for this launch.")
        }
    }
}
