import Foundation
import ThreadingExtensionKit

/// Identifies one running generation of an extension.
///
/// A restarted process receives a new generation. Removing the old generation then drops every
/// patch it published in one operation, without relying on individual cleanup messages.
struct ComponentCustomizationSource: Hashable, Sendable {
    let extensionIdentifier: String
    let processGeneration: String
    let order: Int

    init(
        extensionIdentifier: String,
        processGeneration: String,
        order: Int
    ) {
        self.extensionIdentifier = extensionIdentifier
        self.processGeneration = processGeneration
        self.order = order
    }
}

enum ComponentCustomizationRegistryError: Error, Equatable, LocalizedError {
    case unknownContract(ExtensionComponentID, version: Int)
    case invalidPatch(id: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unknownContract(let id, let version):
            return L10n.format(
                "Unknown component contract “%@” version %lld.",
                id.rawValue,
                Int64(version)
            )
        case .invalidPatch(let id, let reason):
            return L10n.format("Invalid component patch “%@”: %@", id, reason)
        }
    }
}

/// Validates extension publications and serves synchronous, precomputed-value lookups to AppKit.
///
/// Storage stays deliberately in-memory even though publication is now process-backed. The
/// tokenized host service calls `replacePatches`; views continue to know nothing about IPC.
@MainActor
final class ComponentCustomizationRegistry: ComponentCustomizationProvider {
    private struct ContractKey: Hashable {
        let id: ExtensionComponentID
        let version: Int
    }

    private struct Publication {
        let source: ComponentCustomizationSource
        let patches: [ExtensionComponentPatch]
    }

    private var contracts: [ContractKey: ExtensionComponentContract] = [:]
    private var publications: [SourceGeneration: Publication] = [:]
    private var activeReplacementExtension: [ExtensionComponentID: String] = [:]
    private let selectionDefaults: UserDefaults?

    /// Production supplies `.standard`; focused registries stay ephemeral by default so tests
    /// and gallery fixtures never change the user's selected renderer.
    init(selectionDefaults: UserDefaults? = nil) {
        self.selectionDefaults = selectionDefaults
        let stored = selectionDefaults?.dictionary(
            forKey: ComponentReplacementSelectionKeys.selections
        ) as? [String: String] ?? [:]
        activeReplacementExtension = Dictionary(
            uniqueKeysWithValues: stored.map {
                (ExtensionComponentID(rawValue: $0.key), $0.value)
            }
        )
    }

    func register(_ contract: ExtensionComponentContract) throws {
        try contract.validate()
        contracts[ContractKey(id: contract.id, version: contract.version)] = contract
    }

    func contract(
        id: ExtensionComponentID,
        version: Int
    ) -> ExtensionComponentContract? {
        contracts[ContractKey(id: id, version: version)]
    }

    /// Replaces every patch from one process generation atomically.
    func replacePatches(
        _ patches: [ExtensionComponentPatch],
        from source: ComponentCustomizationSource
    ) throws {
        for patch in patches {
            try validate(patch)
        }

        let key = SourceGeneration(source)
        let oldTargets = Set(publications[key]?.patches.map(\.target) ?? [])
        publications[key] = Publication(source: source, patches: patches)
        postChange(for: oldTargets.union(patches.map(\.target)))
    }

    func removePatches(
        extensionIdentifier: String,
        processGeneration: String
    ) {
        let key = SourceGeneration(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration
        )
        guard let removed = publications.removeValue(forKey: key) else { return }
        postChange(for: Set(removed.patches.map(\.target)))
    }

    /// Selects the only extension allowed to replace this component family's full content.
    ///
    /// Additive slots still compose. Passing nil deliberately leaves a conflict unresolved.
    func selectReplacementExtension(
        _ extensionIdentifier: String?,
        for component: ExtensionComponentID
    ) {
        if let extensionIdentifier {
            activeReplacementExtension[component] = extensionIdentifier
        } else {
            activeReplacementExtension.removeValue(forKey: component)
        }
        persistReplacementSelections()

        let targets = Set(
            publications.values
                .flatMap(\.patches)
                .map(\.target)
                .filter { $0.component == component }
        )
        postChange(for: targets)
    }

    func selectedReplacementExtensionIdentifier(
        for component: ExtensionComponentID
    ) -> String? {
        activeReplacementExtension[component]
    }

    func replacementCandidates(
        for component: ExtensionComponentID
    ) -> [String] {
        Array(Set(
            publications.values.flatMap { publication in
                publication.patches.compactMap { patch in
                    guard patch.target.component == component,
                          patch.replacement != nil else { return nil }
                    return publication.source.extensionIdentifier
                }
            }
        )).sorted()
    }

    func customization(
        for target: ExtensionComponentTarget
    ) -> ComponentCustomizationResolution {
        guard let contract = contract(
            id: target.component,
            version: target.contractVersion
        ) else {
            return .empty
        }

        let matches = matchingPatches(for: target)
        guard !matches.isEmpty else { return .empty }

        var properties: [
            ExtensionComponentPropertyID: ExtensionComponentPropertyValue
        ] = [:]
        var slots: [ExtensionComponentSlotID: [ExtensionNode]] = [:]
        var replacements: [(source: ComponentCustomizationSource, patch: ExtensionComponentPatch)]
            = []
        var hooks: [ComponentCustomizationHook] = []

        for match in matches {
            for property in match.patch.properties {
                properties[property.property] = property.value
            }
            for slot in match.patch.slots {
                slots[slot.slot, default: []].append(contentsOf: slot.children)
            }
            if match.patch.replacement != nil {
                replacements.append(match)
            }
            if let hook = match.patch.hook {
                hooks.append(ComponentCustomizationHook(
                    node: hook,
                    extensionIdentifier: match.source.extensionIdentifier
                ))
            }
        }

        for slot in contract.slots {
            if let children = slots[slot.id],
               children.count > slot.maximumInlineItems {
                slots[slot.id] = Array(children.prefix(slot.maximumInlineItems))
            }
        }

        let candidates = Array(Set(
            replacements.map(\.source.extensionIdentifier)
        )).sorted()
        let selected = selectedReplacement(
            from: replacements,
            candidates: candidates,
            component: target.component
        )

        return ComponentCustomizationResolution(
            properties: properties,
            slots: slots,
            replacement: selected?.patch.replacement,
            replacementExtensionIdentifier: selected?.source.extensionIdentifier,
            replacementCandidates: candidates,
            hooks: hooks
        )
    }

    private func validate(_ patch: ExtensionComponentPatch) throws {
        let key = ContractKey(
            id: patch.target.component,
            version: patch.target.contractVersion
        )
        guard let contract = contracts[key] else {
            throw ComponentCustomizationRegistryError.unknownContract(
                patch.target.component,
                version: patch.target.contractVersion
            )
        }

        do {
            try contract.validate(patch)
        } catch let error as ExtensionValidationError {
            throw ComponentCustomizationRegistryError.invalidPatch(
                id: patch.id,
                reason: error.issues.map(\.description).joined(separator: "; ")
            )
        }
    }

    private func matchingPatches(
        for target: ExtensionComponentTarget
    ) -> [(source: ComponentCustomizationSource, patch: ExtensionComponentPatch)] {
        publications.values
            .flatMap { publication in
                publication.patches.compactMap { patch in
                    guard patch.target.component == target.component,
                          patch.target.contractVersion == target.contractVersion,
                          patch.target.entityID == nil
                            || patch.target.entityID == target.entityID else {
                        return nil
                    }
                    return (publication.source, patch)
                }
            }
            .sorted { lhs, rhs in
                let lhsScope = lhs.patch.target.entityID == nil ? 0 : 1
                let rhsScope = rhs.patch.target.entityID == nil ? 0 : 1
                if lhsScope != rhsScope {
                    return lhsScope < rhsScope
                }
                if lhs.source.order != rhs.source.order {
                    return lhs.source.order < rhs.source.order
                }
                if lhs.source.extensionIdentifier != rhs.source.extensionIdentifier {
                    return lhs.source.extensionIdentifier < rhs.source.extensionIdentifier
                }
                return lhs.patch.id < rhs.patch.id
            }
    }

    private func selectedReplacement(
        from replacements: [
            (source: ComponentCustomizationSource, patch: ExtensionComponentPatch)
        ],
        candidates: [String],
        component: ExtensionComponentID
    ) -> (source: ComponentCustomizationSource, patch: ExtensionComponentPatch)? {
        let selectedIdentifier: String?
        if candidates.count == 1 {
            selectedIdentifier = candidates[0]
        } else {
            selectedIdentifier = activeReplacementExtension[component]
        }

        guard let selectedIdentifier else { return nil }
        return replacements.last {
            $0.source.extensionIdentifier == selectedIdentifier
        }
    }

    private func postChange(for targets: Set<ExtensionComponentTarget>) {
        guard !targets.isEmpty else { return }
        NotificationCenter.default.post(
            ComponentCustomizationDidChange(targets: targets)
        )
    }

    private func persistReplacementSelections() {
        selectionDefaults?.set(
            Dictionary(
                uniqueKeysWithValues: activeReplacementExtension.map {
                    ($0.key.rawValue, $0.value)
                }
            ),
            forKey: ComponentReplacementSelectionKeys.selections
        )
    }
}

private enum ComponentReplacementSelectionKeys {
    static let selections = "extensionComponents.selectedReplacementExtensions"
}

struct SourceGeneration: Hashable {
    let extensionIdentifier: String
    let processGeneration: String

    init(_ source: ComponentCustomizationSource) {
        extensionIdentifier = source.extensionIdentifier
        processGeneration = source.processGeneration
    }

    init(extensionIdentifier: String, processGeneration: String) {
        self.extensionIdentifier = extensionIdentifier
        self.processGeneration = processGeneration
    }
}
