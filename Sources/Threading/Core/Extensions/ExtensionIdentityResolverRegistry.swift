import Foundation
import ThreadingExtensionKit

struct ExtensionIdentityImageResolution: Equatable {
    let image: ExtensionImageReference
    let extensionIdentifier: String
}

struct ExtensionIdentityResolversDidChange: AppEvent {
    static let name = Notification.Name("extensionIdentityResolversDidChange")
}

@MainActor
protocol ExtensionIdentityResolving: AnyObject {
    func providerIcon(providerID: String) -> ExtensionIdentityImageResolution?
    func accountIcon(accountID: String) -> ExtensionIdentityImageResolution?
}

@MainActor
final class ExtensionIdentityResolverProviderSlot {
    static let shared = ExtensionIdentityResolverProviderSlot()

    var provider: (any ExtensionIdentityResolving)? {
        didSet {
            NotificationCenter.default.post(ExtensionIdentityResolversDidChange())
        }
    }

    func providerIcon(providerID: String) -> ExtensionIdentityImageResolution? {
        provider?.providerIcon(providerID: providerID)
    }

    func accountIcon(accountID: String) -> ExtensionIdentityImageResolution? {
        provider?.accountIcon(accountID: accountID)
    }
}

/// Validated, in-memory primitive identity publications.
///
/// As with complete component replacement, a single candidate becomes active automatically.
/// When several extensions publish the same primitive family no install-order winner is chosen;
/// `selectProviderExtension` / `selectAccountExtension` are the settings seam for an explicit
/// choice.
@MainActor
final class ExtensionIdentityResolverRegistry: ExtensionIdentityResolving {
    static let shared = ExtensionIdentityResolverRegistry()

    private struct Publication {
        let source: ComponentCustomizationSource
        let providerIcons: [String: ExtensionImageReference]
        let accountIcons: [String: ExtensionImageReference]
    }

    private var publications: [SourceGeneration: Publication] = [:]
    private var selectedProviderExtension: String?
    private var selectedAccountExtension: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedProviderExtension = defaults.string(
            forKey: ExtensionIdentitySelectionKeys.provider
        )
        selectedAccountExtension = defaults.string(
            forKey: ExtensionIdentitySelectionKeys.account
        )
    }

    func replace(
        _ publication: ExtensionIdentityResolutionPublication,
        from source: ComponentCustomizationSource
    ) throws {
        try publication.validate()
        publications[SourceGeneration(source)] = Publication(
            source: source,
            providerIcons: Dictionary(
                uniqueKeysWithValues: publication.providerIcons.map {
                    ($0.providerID, $0.image)
                }
            ),
            accountIcons: Dictionary(
                uniqueKeysWithValues: publication.accountIcons.map {
                    ($0.accountID, $0.image)
                }
            )
        )
        notifyChange()
    }

    func remove(extensionIdentifier: String, processGeneration: String) {
        guard publications.removeValue(forKey: SourceGeneration(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration
        )) != nil else { return }
        notifyChange()
    }

    func selectProviderExtension(_ identifier: String?) {
        selectedProviderExtension = identifier
        defaults.set(identifier, forKey: ExtensionIdentitySelectionKeys.provider)
        notifyChange()
    }

    func selectAccountExtension(_ identifier: String?) {
        selectedAccountExtension = identifier
        defaults.set(identifier, forKey: ExtensionIdentitySelectionKeys.account)
        notifyChange()
    }

    var selectedProviderExtensionIdentifier: String? {
        selectedProviderExtension
    }

    var selectedAccountExtensionIdentifier: String? {
        selectedAccountExtension
    }

    func providerIcon(providerID: String) -> ExtensionIdentityImageResolution? {
        resolve(
            candidates: publications.values.compactMap { publication in
                publication.providerIcons[providerID].map {
                    (publication.source, $0)
                }
            },
            selectedExtension: selectedProviderExtension
        )
    }

    func accountIcon(accountID: String) -> ExtensionIdentityImageResolution? {
        resolve(
            candidates: publications.values.compactMap { publication in
                publication.accountIcons[accountID].map {
                    (publication.source, $0)
                }
            },
            selectedExtension: selectedAccountExtension
        )
    }

    func providerCandidates() -> [String] {
        Array(Set(publications.values.compactMap {
            $0.providerIcons.isEmpty ? nil : $0.source.extensionIdentifier
        })).sorted()
    }

    func accountCandidates() -> [String] {
        Array(Set(publications.values.compactMap {
            $0.accountIcons.isEmpty ? nil : $0.source.extensionIdentifier
        })).sorted()
    }

    private func resolve(
        candidates: [(ComponentCustomizationSource, ExtensionImageReference)],
        selectedExtension: String?
    ) -> ExtensionIdentityImageResolution? {
        let identifiers = Set(candidates.map(\.0.extensionIdentifier))
        let selected = identifiers.count == 1 ? identifiers.first : selectedExtension
        guard let selected else { return nil }

        return candidates
            .filter { $0.0.extensionIdentifier == selected }
            .sorted {
                if $0.0.order != $1.0.order { return $0.0.order < $1.0.order }
                return $0.0.processGeneration < $1.0.processGeneration
            }
            .last
            .map {
                ExtensionIdentityImageResolution(
                    image: $0.1,
                    extensionIdentifier: $0.0.extensionIdentifier
                )
            }
    }

    private func notifyChange() {
        NotificationCenter.default.post(ExtensionIdentityResolversDidChange())
    }
}

private enum ExtensionIdentitySelectionKeys {
    static let provider = "extensionIdentity.selectedProviderExtension"
    static let account = "extensionIdentity.selectedAccountExtension"
}
