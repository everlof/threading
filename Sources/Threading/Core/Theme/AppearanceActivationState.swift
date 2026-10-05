import Foundation
import ThreadingExtensionKit

/// The only persisted owner of the app-theme choice and extension enablement after migration.
/// Runtime status, decoded assets and personal motion/audio choices are deliberately absent.
///
/// The file keeps the key names it had while appearance packs existed, so a record written
/// before they were retired reads unchanged; its `packs` and `activePackID` are ignored. See
/// `docs/decisions/appearance-packs.md`.
struct AppearanceActivationState: Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var revision: UInt64 = 0
    var themeID: String
    var enabledExtensionIDs: Set<String>

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              !themeID.isEmpty, themeID.utf8.count <= 512,
              enabledExtensionIDs.count <= ExtensionPackageStore.maximumInstalledPackages,
              enabledExtensionIDs.allSatisfy(ExtensionIdentifierRules.isReverseDNSIdentifier)
        else { throw AppearanceActivationError.invalidState }
    }

    func changing(_ action: AppearanceActivationAction) throws -> Self {
        var next = self
        switch action {
        case .selectTheme(let id):
            next.themeID = id
        case .setExtensionEnabled(let id, let enabled):
            if enabled {
                next.enabledExtensionIDs.insert(id)
            } else {
                next.enabledExtensionIDs.remove(id)
            }
        case .reconcileInventory(let themeIDs, let extensionIDs, let fallbackThemeID):
            next.enabledExtensionIDs.formIntersection(extensionIDs)
            if !themeIDs.contains(themeID) { next.themeID = fallbackThemeID }
        }
        guard next != self else { return self }
        guard revision < UInt64.max else { throw AppearanceActivationError.invalidState }
        next.revision += 1
        try next.validate()
        return next
    }
}

extension AppearanceActivationState: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case revision
        case themeID = "standaloneThemeID"
        case enabledExtensionIDs = "manuallyEnabledExtensionIDs"
        case retiredPacks = "packs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        revision = try container.decode(UInt64.self, forKey: .revision)
        themeID = try container.decode(String.self, forKey: .themeID)
        enabledExtensionIDs = try container.decode(Set<String>.self, forKey: .enabledExtensionIDs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(themeID, forKey: .themeID)
        try container.encode(enabledExtensionIDs.sorted(), forKey: .enabledExtensionIDs)
        // A build from before packs were retired decodes this key unconditionally and would
        // quarantine the whole record without it. An empty list keeps a downgrade working.
        try container.encode([String](), forKey: .retiredPacks)
    }
}

enum AppearanceActivationAction: Equatable, Sendable {
    case selectTheme(String)
    case setExtensionEnabled(String, Bool)
    case reconcileInventory(themeIDs: Set<String>, extensionIDs: Set<String>, fallbackThemeID: String)
}

enum AppearanceActivationError: LocalizedError {
    case invalidState
    case themeUnavailable
    case extensionUnavailable(String)
    case changeInProgress
    case persistenceFailed
    case recoveryRequired
    case suppressed

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return L10n.string("The saved appearance choices could not be read.")
        case .themeUnavailable:
            return L10n.string("This theme is no longer available.")
        case .extensionUnavailable(let name):
            return L10n.format("The extension %@ is unavailable.", name)
        case .changeInProgress:
            return L10n.string("Another appearance change is in progress. Try again when it finishes.")
        case .persistenceFailed:
            return L10n.string("The appearance change could not be saved. Your previous choices are still in use.")
        case .recoveryRequired:
            return L10n.string("Saved appearance choices need recovery. The unreadable file has been preserved.")
        case .suppressed:
            return L10n.string("Extensions are held back for this launch. You can enable them again after the next launch.")
        }
    }
}
