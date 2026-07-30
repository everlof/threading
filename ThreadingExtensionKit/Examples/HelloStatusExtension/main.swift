#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import ThreadingExtensionKit

let statusTool = ExtensionMCPTool(
    id: "read-status",
    title: "Read extension status",
    description: "Return the current refresh count held by the Hello Status extension."
)

let secretBrokerProbeTool = ExtensionMCPTool(
    id: "probe-secret-broker",
    title: "Probe secret broker",
    description: "Verify the host-brokered secret store with a temporary write/read/list/delete round trip."
)

let statusService = ExtensionServiceDefinition(
    id: "status",
    title: "Hello status",
    description: "Returns the current Hello Status refresh count to another extension.",
    outputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "refreshCount": .object(["type": .string("integer")])
        ])
    ])
)

let helloSettings = ExtensionSettingsContribution(
    pages: [
        ExtensionSettingsPage(
            id: "presentation",
            title: "Presentation",
            symbol: "lightbulb",
            sections: [
                ExtensionSettingsSection(
                    id: "row-status",
                    title: "Sidebar status",
                    fields: [
                        ExtensionSettingField(
                            id: "show-row-status",
                            title: "Show row status",
                            description: "Add example status to sidebar rows, hover cards, composers, and conversation rows.",
                            control: .toggle(defaultValue: true)
                        ),
                        ExtensionSettingField(
                            id: "status-label",
                            title: "Status label",
                            control: .text(
                                defaultValue: "Hello",
                                placeholder: "Hello",
                                maximumLength: 24
                            )
                        ),
                        ExtensionSettingField(
                            id: "status-tone",
                            title: "Status tone",
                            control: .choice(
                                defaultValue: "positive",
                                options: [
                                    .init(id: "neutral", title: "Neutral"),
                                    .init(id: "positive", title: "Positive"),
                                    .init(id: "warning", title: "Warning"),
                                    .init(id: "negative", title: "Negative")
                                ]
                            )
                        ),
                        ExtensionSettingField(
                            id: "maximum-rows",
                            title: "Maximum rows",
                            description: "Limit each project and session publication.",
                            control: .integer(
                                defaultValue: 10,
                                minimum: 1,
                                maximum: 50,
                                step: 1
                            )
                        )
                    ]
                )
            ]
        )
    ],
    sections: [
        ExtensionHostSettingsSection(
            id: "startup",
            page: .general,
            title: "Startup",
            fields: [
                ExtensionSettingField(
                    id: "refresh-on-start",
                    title: "Refresh Hello Status on launch",
                    description: "Demonstrates a section contributed to an existing Settings page.",
                    control: .toggle(defaultValue: false)
                )
            ]
        )
    ]
)

let manifest = ExtensionManifest(
    identifier: "codes.threading.hello-status",
    name: "Hello Status",
    version: "0.2.0",
    runtime: .webAssembly,
    executable: "bin/hello-status.wasm",
    capabilities: [
        .commands,
        .panels,
        .mcpTools,
        .settings,
        .servicesProvide,
        .componentCustomization,
        .hostProjectsRead,
        .hostSessionsRead,
        .hostProvidersRead,
        .hostAccountsPresentationRead,
        .providerIconResolver,
        .accountIconResolver,
        .sessionIdentityRenderer,
        .keyValueStorage,
        .cacheStorage,
        .secrets
    ],
    mcpTools: [statusTool, secretBrokerProbeTool],
    settings: helloSettings,
    services: [statusService]
)

struct HelloSettingsState {
    var showRowStatus = true
    var statusLabel = "Hello"
    var statusRole = ExtensionStatusRole.positive
    var maximumRows = 10
    var refreshOnStart = false

    init(values: [String: ExtensionJSONValue]) {
        if case .bool(let value) = values["show-row-status"] {
            showRowStatus = value
        }
        if case .string(let value) = values["status-label"] {
            statusLabel = value
        }
        if case .string(let value) = values["status-tone"] {
            statusRole = ExtensionStatusRole(rawValue: value) ?? .positive
        }
        if case .integer(let value) = values["maximum-rows"] {
            maximumRows = Int(value)
        }
        if case .bool(let value) = values["refresh-on-start"] {
            refreshOnStart = value
        }
    }
}

func statusPanel(refreshCount: Int) -> ExtensionPanel {
    let status = refreshCount == 0
        ? "Ready"
        : "Refreshed \(refreshCount) \(refreshCount == 1 ? "time" : "times")"
    return ExtensionPanel(
        id: "status",
        title: "Status",
        root: .stack(
            axis: .vertical,
            spacing: .medium,
            children: [
                .text("Example extension", role: .heading),
                .status(status, role: .positive),
                .button(
                    id: "refresh",
                    title: "Refresh",
                    role: .standard,
                    isEnabled: true
                )
            ]
        )
    )
}

func registration(refreshCount: Int = 0) -> ExtensionRegistration {
    ExtensionRegistration(
        commands: [
            ExtensionCommand(
                id: "refresh",
                title: "Refresh status",
                description: "Refresh the example extension's project status.",
                scope: .application,
                defaultShortcut: .init(
                    key: "r",
                    modifiers: [.option, .command]
                ),
                menuPlacements: [.extensions, .project]
            ),
            ExtensionCommand(
                id: "reset-status",
                title: "Reset status",
                description: "Reset the example extension's persisted refresh counter.",
                scope: .application,
                risk: .destructive,
                menuPlacements: [.extensions]
            )
        ],
        panels: [statusPanel(refreshCount: refreshCount)],
        mcpTools: [statusTool, secretBrokerProbeTool],
        services: [statusService]
    )
}

enum HelloStatusProbeError: LocalizedError {
    case secretRoundTripFailed(String)

    var errorDescription: String? {
        switch self {
        case .secretRoundTripFailed(let step):
            return "The secret broker failed its \(step) check."
        }
    }
}

/// Exercises only the brokered API. The extension never imports Security.framework and never
/// receives a Keychain access group, service name, or item reference.
func probeSecretBroker(through host: ExtensionHostClient) async throws -> String {
    let key = "broker-round-trip"
    let expected = "hello-status-\(UUID().uuidString)"

    try await host.setSecret(expected, forKey: key)
    do {
        guard try await host.secret(forKey: key) == expected else {
            throw HelloStatusProbeError.secretRoundTripFailed("read-after-write")
        }
        guard try await host.secretKeys().contains(key) else {
            throw HelloStatusProbeError.secretRoundTripFailed("key-list")
        }
        try await host.removeSecret(forKey: key)
        guard try await host.secret(forKey: key) == nil else {
            throw HelloStatusProbeError.secretRoundTripFailed("delete")
        }
    } catch {
        try? await host.removeSecret(forKey: key)
        throw error
    }

    return "Secret broker write/read/list/delete round trip succeeded; the temporary value was removed."
}

func componentPatches(
    refreshCount: Int,
    projects: [ExtensionProjectSnapshot],
    sessions: [ExtensionSessionSnapshot],
    settings: HelloSettingsState
) -> [ExtensionComponentPatch] {
    let status = ExtensionNode.status(
        "\(settings.statusLabel) · \(refreshCount)",
        role: settings.statusRole
    )
    let projectPatches = settings.showRowStatus
        ? projects.prefix(settings.maximumRows).enumerated().map { index, project in
        ExtensionComponentPatch(
            id: "project-status-\(index)",
            target: .init(
                component: "sidebar.project-row",
                contractVersion: 1,
                entityID: project.id
            ),
            slots: [
                .init(slot: "after-title", children: [status])
            ]
        )
    } : []
    let sessionPatches = settings.showRowStatus
        ? sessions.prefix(settings.maximumRows).enumerated().map { index, session in
        ExtensionComponentPatch(
            id: "session-status-\(index)",
            target: .init(
                component: "sidebar.session-row",
                contractVersion: 1,
                entityID: session.id
            ),
            slots: [
                .init(slot: "after-title", children: [status])
            ]
        )
    } : []
    let projectHoverPatches = settings.showRowStatus
        ? projects.prefix(settings.maximumRows).enumerated().map { index, project in
        ExtensionComponentPatch(
            id: "project-hover-\(index)",
            target: .projectHoverCard(projectID: project.id),
            hook: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .proceed,
                    .divider,
                    .status(
                        "\(settings.statusLabel) project details · \(refreshCount)",
                        role: settings.statusRole
                    )
                ]
            )
        )
    } : []
    let sessionHoverPatches = settings.showRowStatus
        ? sessions.prefix(settings.maximumRows).enumerated().map { index, session in
        ExtensionComponentPatch(
            id: "session-hover-\(index)",
            target: .sessionHoverCard(sessionID: session.id),
            hook: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .proceed,
                    .divider,
                    .status(
                        "\(settings.statusLabel) session details · \(refreshCount)",
                        role: settings.statusRole
                    )
                ]
            )
        )
    } : []
    let accountUsagePatches = settings.showRowStatus
        ? [
            ExtensionComponentPatch(
                id: "account-usage-details",
                target: .accountUsagePopover(),
                hook: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .proceed,
                        .divider,
                        .status(
                            "\(settings.statusLabel) account details · \(refreshCount)",
                            role: settings.statusRole
                        )
                    ]
                )
            )
        ]
        : []
    let sessionStartComposerPatches = settings.showRowStatus
        ? projects.prefix(settings.maximumRows).enumerated().map { index, project in
        ExtensionComponentPatch(
            id: "session-start-composer-\(index)",
            target: .sessionStartComposer(projectID: project.id),
            hook: .stack(
                axis: .horizontal,
                spacing: .small,
                children: [
                    .status(settings.statusLabel, role: settings.statusRole),
                    .proceed
                ]
            )
        )
    } : []
    let conversationReplyComposerPatches = settings.showRowStatus
        ? sessions.prefix(settings.maximumRows).enumerated().map { index, session in
        ExtensionComponentPatch(
            id: "conversation-reply-composer-\(index)",
            target: .conversationReplyComposer(sessionID: session.id),
            hook: .stack(
                axis: .horizontal,
                spacing: .small,
                children: [
                    .proceed,
                    .status(settings.statusLabel, role: settings.statusRole)
                ]
            )
        )
    } : []
    let userMessagePatches = settings.showRowStatus
        ? sessions.prefix(settings.maximumRows).enumerated().map { index, session in
        ExtensionComponentPatch(
            id: "conversation-user-message-\(index)",
            target: .conversationUserMessage(sessionID: session.id),
            hook: .stack(
                axis: .vertical,
                spacing: .small,
                children: [
                    .proceed,
                    .status(
                        "\(settings.statusLabel) user turn",
                        role: settings.statusRole
                    )
                ]
            )
        )
    } : []
    let toolCallPatches = settings.showRowStatus
        ? sessions.prefix(settings.maximumRows).enumerated().map { index, session in
        ExtensionComponentPatch(
            id: "conversation-tool-call-\(index)",
            target: .conversationToolCall(sessionID: session.id),
            hook: .stack(
                axis: .vertical,
                spacing: .small,
                children: [
                    .status(
                        "\(settings.statusLabel) tool activity",
                        role: settings.statusRole
                    ),
                    .proceed
                ]
            )
        )
    } : []
    let displayPaneHeaderPatches = settings.showRowStatus
        ? sessions.prefix(settings.maximumRows).enumerated().map { index, session in
        ExtensionComponentPatch(
            id: "display-pane-header-\(index)",
            target: .displayPaneHeader(sessionID: session.id),
            hook: .stack(
                axis: .horizontal,
                spacing: .small,
                children: [
                    .status(settings.statusLabel, role: settings.statusRole),
                    .button(
                        id: "refresh-display-status",
                        title: "Refresh",
                        role: .standard,
                        isEnabled: true
                    ),
                    .proceed
                ]
            )
        )
    } : []
    let displayTabHeaderPatches = settings.showRowStatus
        ? sessions.prefix(settings.maximumRows).enumerated().map { index, session in
        ExtensionComponentPatch(
            id: "display-tab-header-\(index)",
            target: .displayTabHeader(sessionID: session.id),
            slots: [
                .init(
                    slot: "after-title",
                    children: [
                        .status(settings.statusLabel, role: settings.statusRole)
                    ]
                )
            ]
        )
    } : []
    let identityPatches = sessions.enumerated().map { index, session in
        var images: [ExtensionNode] = [
            .image(
                ExtensionSessionIdentityAsset.providerImage,
                role: .identity,
                accessibilityLabel: session.isSideChat
                    ? "Side chat"
                    : "\(session.providerID) provider"
            )
        ]
        if session.accountID != nil {
            images.append(.image(
                ExtensionSessionIdentityAsset.accountImage,
                role: .icon,
                accessibilityLabel: "Account"
            ))
        }
        return ExtensionComponentPatch(
            id: "session-identity-\(index)",
            target: .sessionIdentity(sessionID: session.id),
            replacement: .stack(
                axis: .horizontal,
                spacing: .tight,
                children: images
            )
        )
    }
    return projectPatches
        + sessionPatches
        + projectHoverPatches
        + sessionHoverPatches
        + accountUsagePatches
        + sessionStartComposerPatches
        + conversationReplyComposerPatches
        + userMessagePatches
        + toolCallPatches
        + displayPaneHeaderPatches
        + displayTabHeaderPatches
        + identityPatches
}

func publishComponentPatches(
    through host: ExtensionHostClient,
    refreshCount: Int,
    settings: HelloSettingsState
) async throws {
    async let projects = host.projects()
    async let sessions = host.sessions()
    let snapshots = try await (projects, sessions)
    try await host.publishComponentPatches(
        componentPatches(
            refreshCount: refreshCount,
            projects: snapshots.0.projects,
            sessions: snapshots.1.sessions,
            settings: settings
        )
    )
}

func publishIdentityResolutions(through host: ExtensionHostClient) async throws {
    async let providers = host.providers()
    async let accounts = host.accounts()
    let snapshots = try await (providers, accounts)

    try await host.publishIdentityResolutions(
        providerIcons: snapshots.0.providers.map { provider in
            ExtensionProviderIconResolution(
                providerID: provider.id,
                image: provider.id == "codex"
                    ? .systemSymbol("terminal.fill")
                    : provider.image
            )
        },
        accountIcons: snapshots.1.accounts.compactMap { account in
            guard !account.hasUserSelectedImage else { return nil }
            return ExtensionAccountIconResolution(
                accountID: account.id,
                image: account.image ?? .systemSymbol("person.crop.circle.fill")
            )
        }
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func writeProtocolValue<Value: Encodable>(_ value: Value) throws {
    var data = try encoder.encode(value)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

try manifest.validate()
try registration().validate(for: manifest)

switch Array(CommandLine.arguments.dropFirst()) {
case ["--threading-register"]:
    try writeProtocolValue(registration())

case ["--threading-serve"]:
    try writeProtocolValue(registration())
    var settingValues = helloSettings.effectiveValues(
        overriding: try ExtensionSettingsEnvironment.values()
    )
    var currentSettings = HelloSettingsState(values: settingValues)
    let keyValueStore = try ExtensionKeyValueStore()
    var refreshCount = try keyValueStore.value(forKey: "refresh-count", as: Int.self) ?? 0
    if currentSettings.refreshOnStart {
        refreshCount += 1
        try keyValueStore.set(refreshCount, forKey: "refresh-count")
    }
    // `ExtensionCacheStore`, not `ExtensionCache.directoryURL()`: the raw directory exists only
    // under the experimental launcher, while this works under both.
    let cache = try ExtensionCacheStore()
    try cache.setData(Data(String(refreshCount).utf8), forName: "last-refresh-count")
    let host = try ExtensionHostClient()
    try await publishComponentPatches(
        through: host,
        refreshCount: refreshCount,
        settings: currentSettings
    )
    try await publishIdentityResolutions(through: host)

    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8) else {
            FileHandle.standardError.write(Data("Request was not UTF-8.\n".utf8))
            exit(65)
        }

        if let settingsRequest = try? JSONDecoder().decode(
            ExtensionSettingsUpdateRequest.self,
            from: data
        ) {
            do {
                try settingsRequest.validate(against: helloSettings)
                settingValues.merge(settingsRequest.values) { _, newValue in newValue }
                currentSettings = HelloSettingsState(values: settingValues)
                try await publishComponentPatches(
                    through: host,
                    refreshCount: refreshCount,
                    settings: currentSettings
                )
                let response = ExtensionSettingsUpdateResponse(
                    requestID: settingsRequest.requestID,
                    settingIDs: settingsRequest.values.keys.sorted()
                )
                try response.validate()
                try writeProtocolValue(response)
                continue
            } catch {
                FileHandle.standardError.write(
                    Data("Invalid settings update: \(error)\n".utf8)
                )
                exit(65)
            }
        }

        if let serviceRequest = try? JSONDecoder().decode(
            ExtensionServiceRequest.self,
            from: data
        ) {
            do {
                try serviceRequest.validate()
                let response: ExtensionServiceResponse
                if serviceRequest.serviceID == statusService.id,
                   serviceRequest.serviceVersion == statusService.version {
                    response = ExtensionServiceResponse(
                        requestID: serviceRequest.requestID,
                        serviceID: statusService.id,
                        serviceVersion: statusService.version,
                        value: .object([
                            "refreshCount": .integer(Int64(refreshCount))
                        ])
                    )
                } else {
                    response = ExtensionServiceResponse(
                        requestID: serviceRequest.requestID,
                        serviceID: serviceRequest.serviceID,
                        serviceVersion: serviceRequest.serviceVersion,
                        error: "Unknown service contract."
                    )
                }
                try response.validate()
                try writeProtocolValue(response)
                continue
            } catch {
                FileHandle.standardError.write(
                    Data("Invalid service request: \(error)\n".utf8)
                )
                exit(65)
            }
        }

        if let toolRequest = try? JSONDecoder().decode(
            ExtensionMCPToolRequest.self,
            from: data
        ) {
            do {
                try toolRequest.validate()
                let response: ExtensionMCPToolResponse
                if toolRequest.toolID == statusTool.id {
                    response = ExtensionMCPToolResponse(
                        requestID: toolRequest.requestID,
                        text: "Hello Status has been refreshed \(refreshCount) time(s)."
                    )
                } else if toolRequest.toolID == secretBrokerProbeTool.id {
                    do {
                        response = ExtensionMCPToolResponse(
                            requestID: toolRequest.requestID,
                            text: try await probeSecretBroker(through: host)
                        )
                    } catch {
                        response = ExtensionMCPToolResponse(
                            requestID: toolRequest.requestID,
                            text: "Secret broker probe failed: \(error.localizedDescription)",
                            isError: true
                        )
                    }
                } else {
                    response = ExtensionMCPToolResponse(
                        requestID: toolRequest.requestID,
                        text: "Unknown MCP tool “\(toolRequest.toolID)”.",
                        isError: true
                    )
                }
                try response.validate()
                try writeProtocolValue(response)
                continue
            } catch {
                FileHandle.standardError.write(
                    Data("Invalid MCP tool request: \(error)\n".utf8)
                )
                exit(65)
            }
        }

        if let commandRequest = try? JSONDecoder().decode(
            ExtensionCommandRequest.self,
            from: data
        ) {
            do {
                try commandRequest.validate()
                let response: ExtensionCommandResponse
                if commandRequest.commandID == "refresh" {
                    refreshCount += 1
                    try keyValueStore.set(refreshCount, forKey: "refresh-count")
                    try await publishComponentPatches(
                        through: host,
                        refreshCount: refreshCount,
                        settings: currentSettings
                    )
                    response = ExtensionCommandResponse(
                        requestID: commandRequest.requestID,
                        commandID: commandRequest.commandID,
                        message: "Status refreshed."
                    )
                } else if commandRequest.commandID == "reset-status" {
                    refreshCount = 0
                    try keyValueStore.set(refreshCount, forKey: "refresh-count")
                    try await publishComponentPatches(
                        through: host,
                        refreshCount: refreshCount,
                        settings: currentSettings
                    )
                    response = ExtensionCommandResponse(
                        requestID: commandRequest.requestID,
                        commandID: commandRequest.commandID,
                        message: "Status reset."
                    )
                } else {
                    response = ExtensionCommandResponse(
                        requestID: commandRequest.requestID,
                        commandID: commandRequest.commandID,
                        error: "Unknown command “\(commandRequest.commandID)”."
                    )
                }
                try response.validate()
                try writeProtocolValue(response)
                continue
            } catch {
                FileHandle.standardError.write(
                    Data("Invalid command request: \(error)\n".utf8)
                )
                exit(65)
            }
        }

        if let componentRequest = try? JSONDecoder().decode(
            ExtensionComponentActionRequest.self,
            from: data
        ) {
            do {
                try componentRequest.validate()
                let response: ExtensionActionResponse
                if componentRequest.actionID == "refresh-display-status" {
                    refreshCount += 1
                    try keyValueStore.set(refreshCount, forKey: "refresh-count")
                    try await publishComponentPatches(
                        through: host,
                        refreshCount: refreshCount,
                        settings: currentSettings
                    )
                    response = ExtensionActionResponse(
                        requestID: componentRequest.requestID,
                        message: "Display status refreshed."
                    )
                } else {
                    response = ExtensionActionResponse(
                        requestID: componentRequest.requestID,
                        error: "Unknown component action “\(componentRequest.actionID)”."
                    )
                }
                try response.validate()
                try writeProtocolValue(response)
                continue
            } catch {
                FileHandle.standardError.write(
                    Data("Invalid component action: \(error)\n".utf8)
                )
                exit(65)
            }
        }

        let request: ExtensionActionRequest
        do {
            request = try JSONDecoder().decode(ExtensionActionRequest.self, from: data)
            try request.validate()
        } catch {
            FileHandle.standardError.write(
                Data("Invalid action request: \(error)\n".utf8)
            )
            exit(65)
        }

        let response: ExtensionActionResponse
        if request.panelID == "status", request.actionID == "refresh" {
            refreshCount += 1
            try keyValueStore.set(refreshCount, forKey: "refresh-count")
            try await publishComponentPatches(
                through: host,
                refreshCount: refreshCount,
                settings: currentSettings
            )
            response = ExtensionActionResponse(
                requestID: request.requestID,
                panel: statusPanel(refreshCount: refreshCount),
                message: "Status refreshed."
            )
        } else {
            response = ExtensionActionResponse(
                requestID: request.requestID,
                error: "Unknown action “\(request.actionID)” for panel “\(request.panelID)”."
            )
        }

        try response.validate()
        try writeProtocolValue(response)
    }

default:
    FileHandle.standardError.write(
        Data("Expected --threading-register or --threading-serve from the Threading host.\n".utf8)
    )
    exit(64)
}
