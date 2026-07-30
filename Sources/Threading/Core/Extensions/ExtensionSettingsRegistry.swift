import Foundation
import ThreadingExtensionKit

struct ExtensionSettingsRegistryDidChange: AppEvent {
    static let name = Notification.Name("extensionSettingsRegistryDidChange")
}

struct ExtensionSettingsValuesDidChange: AppEvent {
    static let name = Notification.Name("extensionSettingsValuesDidChange")
}

struct RegisteredExtensionSettingsPage {
    let id: String
    let extensionIdentifier: String
    let extensionName: String
    let page: ExtensionSettingsPage
}

struct RegisteredExtensionSettingsSection {
    let extensionIdentifier: String
    let extensionName: String
    let section: ExtensionHostSettingsSection
}

/// The active, host-renderable settings catalogue.
///
/// Declarations come from inspected manifests, not child-process output. The manager replaces
/// this registry from the enabled package inventory, so a process cannot broaden its Settings UI
/// after the user enables it and disabling one extension removes all of its surfaces atomically.
@MainActor
final class ExtensionSettingsRegistry {
    static let shared = ExtensionSettingsRegistry()

    private struct Owner {
        let identifier: String
        let name: String
        let settings: ExtensionSettingsContribution
    }

    private var owners: [String: Owner] = [:]

    var pages: [RegisteredExtensionSettingsPage] {
        owners.values
            .flatMap { owner in
                owner.settings.pages.map { page in
                    RegisteredExtensionSettingsPage(
                        id: Self.qualifiedPageID(
                            extensionIdentifier: owner.identifier,
                            localPageID: page.id
                        ),
                        extensionIdentifier: owner.identifier,
                        extensionName: owner.name,
                        page: page
                    )
                }
            }
            .sorted {
                let ownerOrder = $0.extensionName.localizedCaseInsensitiveCompare($1.extensionName)
                if ownerOrder != .orderedSame { return ownerOrder == .orderedAscending }
                return $0.page.title.localizedCaseInsensitiveCompare($1.page.title) == .orderedAscending
            }
    }

    func sections(
        for page: ExtensionHostSettingsPage
    ) -> [RegisteredExtensionSettingsSection] {
        owners.values
            .flatMap { owner in
                owner.settings.sections
                    .filter { $0.page == page }
                    .map {
                        RegisteredExtensionSettingsSection(
                            extensionIdentifier: owner.identifier,
                            extensionName: owner.name,
                            section: $0
                        )
                    }
            }
            .sorted {
                let ownerOrder = $0.extensionName.localizedCaseInsensitiveCompare($1.extensionName)
                if ownerOrder != .orderedSame { return ownerOrder == .orderedAscending }
                return $0.section.id < $1.section.id
            }
    }

    func field(
        extensionIdentifier: String,
        settingID: String
    ) -> ExtensionSettingField? {
        owners[extensionIdentifier]?.settings.field(id: settingID)
    }

    func settings(for extensionIdentifier: String) -> ExtensionSettingsContribution? {
        owners[extensionIdentifier]?.settings
    }

    func replace(
        enabledManifests: [ExtensionManifest],
        postChange: Bool = true
    ) {
        replace(
            owners: enabledManifests
                .filter { !$0.settings.isEmpty }
                .map {
                    Owner(
                        identifier: $0.identifier,
                        name: $0.name,
                        settings: $0.settings
                    )
                },
            postChange: postChange
        )
    }

    func replace(
        enabledBundles: [ThreadingExtensionBundle],
        postChange: Bool = true
    ) {
        replace(
            owners: enabledBundles.compactMap { bundle in
                guard !bundle.manifest.settings.isEmpty else { return nil }
                let localization = ExtensionLocalizationResolver(
                    catalogs: bundle.localizations
                )
                return Owner(
                    identifier: bundle.manifest.identifier,
                    name: localization.string(bundle.manifest.name),
                    settings: localization.settings(bundle.manifest.settings)
                )
            },
            postChange: postChange
        )
    }

    static func searchTerms(for page: RegisteredExtensionSettingsPage) -> [String] {
        page.page.sections.flatMap(searchTerms)
    }

    func searchTerms(for page: ExtensionHostSettingsPage) -> [String] {
        sections(for: page).flatMap { registered in
            [registered.extensionName] + Self.searchTerms(registered.section)
        }
    }

    private func replace(owners newOwners: [Owner], postChange: Bool) {
        let replacement = Dictionary(
            uniqueKeysWithValues: newOwners.map { ($0.identifier, $0) }
        )
        guard !sameOwners(replacement) else { return }
        owners = replacement
        if postChange {
            NotificationCenter.default.post(ExtensionSettingsRegistryDidChange())
        }
    }

    private static func searchTerms(_ section: ExtensionSettingsSection) -> [String] {
        (section.title.map { [$0] } ?? []) + section.fields.flatMap(searchTerms)
    }

    private static func searchTerms(_ section: ExtensionHostSettingsSection) -> [String] {
        (section.title.map { [$0] } ?? []) + section.fields.flatMap(searchTerms)
    }

    private static func searchTerms(_ field: ExtensionSettingField) -> [String] {
        var terms = [field.title]
        if let description = field.description { terms.append(description) }
        switch field.control {
        case .toggle, .integer:
            break
        case .text(_, let placeholder, _):
            if let placeholder { terms.append(placeholder) }
        case .choice(_, let options):
            terms.append(contentsOf: options.map(\.title))
        }
        return terms
    }

    static func qualifiedPageID(
        extensionIdentifier: String,
        localPageID: String
    ) -> String {
        "extension.\(extensionIdentifier).settings.\(localPageID)"
    }

    private func sameOwners(_ other: [String: Owner]) -> Bool {
        guard owners.keys == other.keys else { return false }
        return owners.allSatisfy { id, owner in
            guard let candidate = other[id] else { return false }
            return owner.name == candidate.name && owner.settings == candidate.settings
        }
    }
}
