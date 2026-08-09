#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import ThreadingExtensionKit

let manifest = ExtensionManifest(
    identifier: "codes.threading.session-info",
    name: "Session Info",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/session-info.wasm",
    capabilities: [
        .panels,
        .hostProjectsRead,
        .hostSessionsRead,
        .hostSessionRuntimeRead,
        .hostRepositoriesRead
    ]
)

let panelID = "session-info"
let loadActionID = "load-session"
let refreshActionID = "refresh"

func loadingPanel() -> ExtensionPanel {
    ExtensionPanel(
        id: panelID,
        title: "Session Info",
        root: .stack(
            axis: .vertical,
            spacing: .medium,
            children: [
                .text("Session Info", role: .heading),
                .status("Loading current session…", role: .neutral)
            ]
        ),
        loadActionID: loadActionID
    )
}

func row(_ label: String, _ value: String) -> ExtensionNode {
    .stack(
        axis: .horizontal,
        spacing: .medium,
        children: [
            .text(label, role: .compactDetail),
            .flexibleSpacer,
            .text(value, role: .compactBody)
        ]
    )
}

func activityRole(_ activity: ExtensionSessionActivity) -> ExtensionStatusRole {
    switch activity {
    case .working:
        return .positive
    case .needsAttention:
        return .warning
    case .dormant, .idle:
        return .neutral
    default:
        return .neutral
    }
}

func displayActivity(_ activity: ExtensionSessionActivity) -> String {
    switch activity {
    case .needsAttention:
        return "Needs attention"
    default:
        return activity.rawValue.capitalized
    }
}

func loadedPanel(
    session: ExtensionSessionSnapshot,
    project: ExtensionProjectSnapshot,
    runtime: ExtensionSessionRuntimeSnapshot
) -> ExtensionPanel {
    var details: [ExtensionNode] = [
        .text(session.displayTitle, role: .heading),
        .status(displayActivity(session.activity), role: activityRole(session.activity)),
        .divider,
        row("Project", project.displayName),
        row("Provider", session.providerID),
        row("Surface", session.usesNativeUI ? "Conversation" : "Terminal")
    ]

    if let accountID = session.accountID {
        details.append(row("Account", accountID))
    }
    if let branch = session.branch {
        details.append(row("Branch", branch))
    }
    if let repository = project.repository {
        if let host = repository.remoteHost, let path = repository.repositoryPath {
            details.append(row("Repository", "\(host)/\(path)"))
        }
        if let revision = repository.headRevision {
            details.append(row("Revision", String(revision.prefix(12))))
        }
    }
    if session.isSideChat {
        details.append(row("Kind", "Side chat"))
    }
    if session.isArchived {
        details.append(.status("Archived", role: .warning))
    }

    details.append(.divider)
    if runtime.processGroups.isEmpty {
        details.append(.status("No running session processes", role: .neutral))
    } else {
        details.append(.text("Processes", role: .heading))
        for group in runtime.processGroups {
            for process in group.processes {
                let cpu = process.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—"
                details.append(row(
                    "\(displayOrigin(group.origin)) · \(process.command) · \(process.processIdentifier)",
                    "\(cpu) · \(displayBytes(process.memoryBytes))"
                ))
            }
        }
    }

    if !runtime.portGroups.isEmpty {
        details.append(.divider)
        details.append(.text("Listening ports", role: .heading))
        for group in runtime.portGroups {
            for port in group.ports {
                details.append(row(
                    "\(displayOrigin(group.origin)) · \(port.command)",
                    "\(port.port) · \(displayInterface(port.interface, address: port.address))"
                ))
            }
        }
    }

    details.append(.divider)
    details.append(.button(
        id: refreshActionID,
        title: "Refresh",
        role: .standard,
        isEnabled: true
    ))

    return ExtensionPanel(
        id: panelID,
        title: "Session Info",
        root: .stack(axis: .vertical, spacing: .medium, children: details),
        loadActionID: loadActionID
    )
}

func displayOrigin(_ origin: ExtensionSessionRuntimeOrigin) -> String {
    switch origin {
    case .agent: return "Agent"
    case .shell: return "Shell"
    default: return origin.rawValue.capitalized
    }
}

func displayInterface(
    _ interface: ExtensionSessionRuntimePortInterface,
    address: String
) -> String {
    switch interface {
    case .allInterfaces: return "all interfaces"
    case .localhost: return "localhost"
    case .specificAddress: return address
    default: return address
    }
}

func displayBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1_024, index < units.count - 1 {
        value /= 1_024
        index += 1
    }
    return index == 0
        ? "\(bytes) \(units[index])"
        : String(format: "%.1f %@", value, units[index])
}

func failurePanel(_ message: String) -> ExtensionPanel {
    ExtensionPanel(
        id: panelID,
        title: "Session Info",
        root: .stack(
            axis: .vertical,
            spacing: .medium,
            children: [
                .text("Session Info", role: .heading),
                .status(message, role: .negative),
                .button(
                    id: refreshActionID,
                    title: "Try Again",
                    role: .standard,
                    isEnabled: true
                )
            ]
        ),
        loadActionID: loadActionID
    )
}

func registration() -> ExtensionRegistration {
    ExtensionRegistration(panels: [loadingPanel()])
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
    let host = try ExtensionHostClient()

    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8) else {
            FileHandle.standardError.write(Data("Request was not UTF-8.\n".utf8))
            exit(65)
        }

        let request: ExtensionActionRequest
        do {
            request = try JSONDecoder().decode(ExtensionActionRequest.self, from: data)
            try request.validate()
        } catch {
            FileHandle.standardError.write(Data("Invalid action request: \(error)\n".utf8))
            exit(65)
        }

        let response: ExtensionActionResponse
        if request.panelID == panelID,
           request.actionID == loadActionID || request.actionID == refreshActionID {
            guard let sessionID = request.context.sessionID else {
                response = ExtensionActionResponse(
                    requestID: request.requestID,
                    panel: failurePanel("Open this panel from a session.")
                )
                try response.validate()
                try writeProtocolValue(response)
                continue
            }

            do {
                async let sessionResult = host.session(id: sessionID)
                async let runtime = host.sessionRuntime(id: sessionID)
                let session = try await sessionResult.session
                let project = try await host.project(id: session.projectID).project
                response = ExtensionActionResponse(
                    requestID: request.requestID,
                    panel: loadedPanel(
                        session: session,
                        project: project,
                        runtime: try await runtime
                    )
                )
            } catch {
                response = ExtensionActionResponse(
                    requestID: request.requestID,
                    panel: failurePanel(error.localizedDescription)
                )
            }
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
