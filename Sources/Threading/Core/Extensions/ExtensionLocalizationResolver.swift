import Foundation
import ThreadingExtensionKit

/// Negotiates and applies one extension's package-owned localization catalogue.
///
/// Localization changes presentation strings only. Stable IDs, setting values, schemas,
/// capabilities, action routing, and resource paths are never passed through the catalogue.
struct ExtensionLocalizationResolver: Sendable {
    let language: String?
    let strings: [String: String]

    init(
        catalogs: [ThreadingExtensionLocalizationCatalog],
        preferredLanguages: [String] = L10n.preferredLanguages
    ) {
        language = ExtensionLocalizer.bestLanguage(
            preferredLanguages: preferredLanguages,
            availableLanguages: catalogs.map(\.language)
        )
        strings = language.flatMap { selected in
            catalogs.first { $0.language.caseInsensitiveCompare(selected) == .orderedSame }?.strings
        } ?? [:]
    }

    init(strings: [String: String], language: String? = nil) {
        self.language = language
        self.strings = strings
    }

    func string(_ value: String) -> String {
        strings[value] ?? value
    }

    func optional(_ value: String?) -> String? {
        value.map(string)
    }

    func environment(
        preferredLanguages: [String] = L10n.preferredLanguages,
        localeIdentifier: String = L10n.localeIdentifier
    ) -> [String: String] {
        var result = [
            ExtensionLocalizationEnvironment.localeIdentifier: localeIdentifier
        ]
        if let data = try? JSONEncoder().encode(preferredLanguages) {
            result[ExtensionLocalizationEnvironment.preferredLanguagesJSON] =
                String(decoding: data, as: UTF8.self)
        }
        if let language {
            result[ExtensionLocalizationEnvironment.selectedLanguage] = language
        }
        if !strings.isEmpty, let data = try? JSONEncoder().encode(strings) {
            result[ExtensionLocalizationEnvironment.stringsJSON] =
                String(decoding: data, as: UTF8.self)
        }
        return result
    }

    func settings(_ contribution: ExtensionSettingsContribution)
        -> ExtensionSettingsContribution {
        ExtensionSettingsContribution(
            pages: contribution.pages.map { page in
                ExtensionSettingsPage(
                    id: page.id,
                    title: string(page.title),
                    symbol: page.symbol,
                    sections: page.sections.map(settingsSection)
                )
            },
            sections: contribution.sections.map { section in
                ExtensionHostSettingsSection(
                    id: section.id,
                    page: section.page,
                    title: optional(section.title),
                    fields: section.fields.map(settingField)
                )
            }
        )
    }

    func registration(_ registration: ExtensionRegistration) -> ExtensionRegistration {
        ExtensionRegistration(
            commands: registration.commands.map(command),
            panels: registration.panels.map(panel),
            workspaceNavigators: registration.workspaceNavigators.map(workspaceNavigator),
            mcpTools: registration.mcpTools.map(mcpTool),
            services: registration.services.map(service),
            factDefinitions: registration.factDefinitions.map(factDefinition),
            previewableFileTypes: registration.previewableFileTypes
        )
    }

    func factDefinition(_ definition: ExtensionFactDefinition) -> ExtensionFactDefinition {
        ExtensionFactDefinition(
            key: definition.key,
            displayName: string(definition.displayName),
            valueType: definition.valueType,
            subjectKinds: definition.subjectKinds,
            usages: definition.usages
        )
    }

    func fact(_ fact: ExtensionFact) -> ExtensionFact {
        ExtensionFact(
            key: fact.key,
            subject: fact.subject,
            value: fact.value,
            label: optional(fact.label),
            status: fact.status,
            icon: fact.icon,
            observedAt: fact.observedAt
        )
    }

    func workspaceNavigator(
        _ navigator: ExtensionWorkspaceNavigator
    ) -> ExtensionWorkspaceNavigator {
        ExtensionWorkspaceNavigator(
            id: navigator.id,
            title: string(navigator.title),
            root: workspaceNavigatorNode(navigator.root),
            options: navigator.options.map { option in
                ExtensionWorkspaceNavigatorOption(
                    id: option.id,
                    title: string(option.title),
                    control: settingControl(option.control)
                )
            },
            loadActionID: navigator.loadActionID,
            eventActionID: navigator.eventActionID,
            preferredWidth: navigator.preferredWidth
        )
    }

    private func workspaceNavigatorNode(
        _ sourceNode: ExtensionWorkspaceNavigatorNode
    ) -> ExtensionWorkspaceNavigatorNode {
        switch sourceNode {
        case .content(let content):
            return .content(node(content))
        case .collection(let collection):
            return .collection(
                ExtensionWorkspaceNavigatorCollection(
                    id: collection.id,
                    layout: collection.layout,
                    selectionMode: collection.selectionMode,
                    sections: collection.sections.map {
                        ExtensionWorkspaceNavigatorSection(
                            id: $0.id,
                            header: $0.header.map(node)
                        )
                    },
                    items: collection.items.map {
                        ExtensionWorkspaceNavigatorItem(
                            id: $0.id,
                            sectionID: $0.sectionID,
                            parentID: $0.parentID,
                            content: node($0.content),
                            accessibilityLabel: optional($0.accessibilityLabel),
                            activation: $0.activation,
                            isEnabled: $0.isEnabled,
                            isSelected: $0.isSelected,
                            isExpanded: $0.isExpanded
                        )
                    }
                )
            )
        case .divider:
            return .divider
        case .spacer(let spacing):
            return .spacer(spacing)
        case .flexibleSpacer:
            return .flexibleSpacer
        case .stack(let axis, let spacing, let children):
            return .stack(
                axis: axis,
                spacing: spacing,
                children: children.map(workspaceNavigatorNode)
            )
        case .overlay(let base, let overlay):
            return .overlay(
                base: workspaceNavigatorNode(base),
                overlay: workspaceNavigatorNode(overlay)
            )
        }
    }

    func panel(_ panel: ExtensionPanel) -> ExtensionPanel {
        ExtensionPanel(
            id: panel.id,
            title: string(panel.title),
            root: node(panel.root),
            loadActionID: panel.loadActionID,
            remoteSurface: panel.remoteSurface
        )
    }

    func actionResponse(_ response: ExtensionActionResponse) -> ExtensionActionResponse {
        ExtensionActionResponse(
            protocolVersion: response.protocolVersion,
            requestID: response.requestID,
            panel: response.panel.map(panel),
            message: optional(response.message),
            error: optional(response.error)
        )
    }

    func workspaceNavigatorActionResponse(
        _ response: ExtensionWorkspaceNavigatorActionResponse
    ) -> ExtensionWorkspaceNavigatorActionResponse {
        ExtensionWorkspaceNavigatorActionResponse(
            protocolVersion: response.protocolVersion,
            requestID: response.requestID,
            navigatorID: response.navigatorID,
            navigator: response.navigator.map(workspaceNavigator),
            itemPatches: response.itemPatches?.map {
                ExtensionWorkspaceNavigatorItemPatch(
                    collectionID: $0.collectionID,
                    itemID: $0.itemID,
                    content: node($0.content)
                )
            },
            message: optional(response.message),
            error: optional(response.error)
        )
    }

    func commandResponse(_ response: ExtensionCommandResponse) -> ExtensionCommandResponse {
        ExtensionCommandResponse(
            protocolVersion: response.protocolVersion,
            requestID: response.requestID,
            commandID: response.commandID,
            message: optional(response.message),
            error: optional(response.error)
        )
    }

    func componentPatch(_ patch: ExtensionComponentPatch) -> ExtensionComponentPatch {
        ExtensionComponentPatch(
            id: patch.id,
            target: patch.target,
            properties: patch.properties.map { property in
                let value: ExtensionComponentPropertyValue
                switch property.value {
                case .text(let text):
                    value = .text(string(text))
                case .flag, .image, .identity:
                    value = property.value
                }
                return ExtensionComponentPropertyPatch(
                    property: property.property,
                    value: value
                )
            },
            slots: patch.slots.map {
                ExtensionComponentSlotPatch(
                    slot: $0.slot,
                    children: $0.children.map { self.node($0) }
                )
            },
            replacement: patch.replacement.map(node),
            hook: patch.hook.map(node)
        )
    }

    func node(_ sourceNode: ExtensionNode) -> ExtensionNode {
        switch sourceNode {
        case .text(let text, let role):
            return .text(string(text), role: role)
        case .image(let reference, let role, let accessibilityLabel):
            return .image(
                reference,
                role: role,
                accessibilityLabel: optional(accessibilityLabel)
            )
        case .button(let id, let title, let role, let isEnabled):
            return .button(
                id: id,
                title: string(title),
                role: role,
                isEnabled: isEnabled
            )
        case .textInput(
            let id,
            let value,
            let placeholder,
            let accessibilityLabel,
            let role,
            let isEnabled
        ):
            return .textInput(
                id: id,
                value: value,
                placeholder: optional(placeholder),
                accessibilityLabel: string(accessibilityLabel),
                role: role,
                isEnabled: isEnabled
            )
        case .picker(let id, let selection, let options, let accessibilityLabel, let isEnabled):
            return .picker(
                id: id,
                selection: selection,
                options: options.map {
                    ExtensionPickerOption(
                        value: $0.value,
                        title: string($0.title),
                        isEnabled: $0.isEnabled
                    )
                },
                accessibilityLabel: string(accessibilityLabel),
                isEnabled: isEnabled
            )
        case .media(let document):
            // Everything else in a media document is a handle, an id or a number; the label is
            // the one string it carries, and it is the one a screen reader will say.
            return .media(ExtensionMediaDocument(
                id: document.id,
                source: document.source,
                format: document.format,
                playback: document.playback,
                transport: document.transport,
                allowsFrameCopy: document.allowsFrameCopy,
                accessibilityLabel: string(document.accessibilityLabel),
                preferredAspectRatio: document.preferredAspectRatio,
                stateActionID: document.stateActionID
            ))
        case .scene(let scene):
            return .scene(
                ExtensionScene(
                    accessibilityLabel: string(scene.accessibilityLabel),
                    preferredAspectRatio: scene.preferredAspectRatio,
                    hierarchy: scene.hierarchy,
                    items: scene.items.map {
                        ExtensionSceneItem(
                            id: $0.id,
                            parentID: $0.parentID,
                            frame: $0.frame,
                            shape: $0.shape,
                            color: $0.color,
                            label: optional($0.label),
                            detail: optional($0.detail),
                            accessibilityLabel: optional($0.accessibilityLabel),
                            accessibilityValue: optional($0.accessibilityValue),
                            actionID: $0.actionID,
                            isEnabled: $0.isEnabled,
                            isSelected: $0.isSelected
                        )
                    }
                )
            )
        case .status(let text, let role):
            return .status(string(text), role: role)
        case .disclosure(let id, let summary, let detail):
            return .disclosure(
                id: id,
                summary: node(summary),
                detail: detail.map { self.node($0) }
            )
        case .proceed:
            return .proceed
        case .overlay(let base, let overlay):
            return .overlay(base: node(base), overlay: node(overlay))
        case .customSurface(let surface, let accessibilityLabel):
            return .customSurface(
                surface,
                accessibilityLabel: optional(accessibilityLabel)
            )
        case .divider:
            return .divider
        case .spacer(let spacing):
            return .spacer(spacing)
        case .flexibleSpacer:
            return .flexibleSpacer
        case .stack(let axis, let spacing, let children):
            return .stack(
                axis: axis,
                spacing: spacing,
                children: children.map { self.node($0) }
            )
        }
    }

    private func settingsSection(
        _ section: ExtensionSettingsSection
    ) -> ExtensionSettingsSection {
        ExtensionSettingsSection(
            id: section.id,
            title: optional(section.title),
            fields: section.fields.map(settingField)
        )
    }

    private func settingField(_ field: ExtensionSettingField) -> ExtensionSettingField {
        ExtensionSettingField(
            id: field.id,
            title: string(field.title),
            description: optional(field.description),
            control: settingControl(field.control)
        )
    }

    private func settingControl(_ control: ExtensionSettingControl) -> ExtensionSettingControl {
        switch control {
        case .toggle(let defaultValue):
            return .toggle(defaultValue: defaultValue)
        case .text(let defaultValue, let placeholder, let maximumLength):
            return .text(
                defaultValue: defaultValue,
                placeholder: optional(placeholder),
                maximumLength: maximumLength
            )
        case .choice(let defaultValue, let options):
            return .choice(
                defaultValue: defaultValue,
                options: options.map {
                    ExtensionSettingOption(id: $0.id, title: string($0.title))
                }
            )
        case .integer(let defaultValue, let minimum, let maximum, let step):
            return .integer(
                defaultValue: defaultValue,
                minimum: minimum,
                maximum: maximum,
                step: step
            )
        }
    }

    private func command(_ command: ExtensionCommand) -> ExtensionCommand {
        ExtensionCommand(
            id: command.id,
            title: string(command.title),
            description: optional(command.description),
            scope: command.scope,
            risk: command.risk,
            defaultShortcut: command.defaultShortcut,
            menuPlacements: command.menuPlacements
        )
    }

    func mcpTool(_ tool: ExtensionMCPTool) -> ExtensionMCPTool {
        ExtensionMCPTool(
            id: tool.id,
            title: string(tool.title),
            description: string(tool.description),
            inputSchema: tool.inputSchema
        )
    }

    func service(_ definition: ExtensionServiceDefinition)
        -> ExtensionServiceDefinition {
        ExtensionServiceDefinition(
            id: definition.id,
            version: definition.version,
            title: string(definition.title),
            description: string(definition.description),
            inputSchema: definition.inputSchema,
            outputSchema: definition.outputSchema
        )
    }

    func companion(_ companion: ExtensionCompanion) -> ExtensionCompanion {
        ExtensionCompanion(
            id: companion.id,
            platform: companion.platform,
            bundlePath: companion.bundlePath,
            activation: companion.activation,
            capabilities: companion.capabilities,
            operations: companion.operations.map(companionOperation),
            surfaces: companion.surfaces.map(remoteSurface)
        )
    }

    private func companionOperation(
        _ operation: ExtensionCompanionOperation
    ) -> ExtensionCompanionOperation {
        ExtensionCompanionOperation(
            id: operation.id,
            title: string(operation.title),
            description: string(operation.description),
            inputSchema: operation.inputSchema,
            outputSchema: operation.outputSchema
        )
    }

    private func remoteSurface(_ surface: ExtensionRemoteSurface) -> ExtensionRemoteSurface {
        ExtensionRemoteSurface(
            id: surface.id,
            title: string(surface.title),
            accessibilityLabel: string(surface.accessibilityLabel),
            maximumWidth: surface.maximumWidth,
            maximumHeight: surface.maximumHeight,
            acceptsPointer: surface.acceptsPointer,
            acceptsKeyboard: surface.acceptsKeyboard
        )
    }

    func theme(_ theme: AppTheme) -> AppTheme {
        AppTheme(
            id: theme.id,
            name: string(theme.name),
            mode: theme.mode,
            summary: optional(theme.summary),
            variants: theme.variants
        )
    }
}
