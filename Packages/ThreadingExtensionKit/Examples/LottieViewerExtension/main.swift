#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import ThreadingExtensionKit

// The reference extension for media documents, project-file handles and attachment previews.
//
// Everything it does is done through the public seams: it enumerates the project's animations as
// opaque handles, points a *host-owned* player at one, and offers a preview body for a Lottie the
// session exchanged. It holds no decoder, no filesystem access and no pixels — which is the point.
// Hello Status keeps the component contracts exercised by an ordinary extension; this one keeps
// these three.

let viewerSettings = ExtensionSettingsContribution(
    pages: [
        ExtensionSettingsPage(
            id: "playback",
            title: "Playback",
            symbol: "play.circle",
            sections: [
                ExtensionSettingsSection(
                    id: "defaults",
                    title: "Defaults",
                    fields: [
                        ExtensionSettingField(
                            id: "loop-mode",
                            title: "Loop",
                            description: "How a document plays when it is first opened.",
                            control: .choice(
                                defaultValue: "loop",
                                options: [
                                    .init(id: "once", title: "Once"),
                                    .init(id: "loop", title: "Loop"),
                                    .init(id: "ping-pong", title: "Back and forth")
                                ]
                            )
                        ),
                        ExtensionSettingField(
                            id: "speed",
                            title: "Speed",
                            description: "Playback rate, as a percentage of the document's own.",
                            control: .integer(
                                defaultValue: 100,
                                minimum: 10,
                                maximum: 400,
                                step: 10
                            )
                        ),
                        ExtensionSettingField(
                            id: "background",
                            title: "Canvas",
                            control: .choice(
                                defaultValue: "checkerboard",
                                options: [
                                    .init(id: "surface", title: "Pane surface"),
                                    .init(id: "checkerboard", title: "Checkerboard"),
                                    .init(id: "transparent", title: "Transparent")
                                ]
                            )
                        )
                    ]
                )
            ]
        )
    ]
)

let manifest = ExtensionManifest(
    identifier: "codes.threading.lottie-viewer",
    name: "Lottie Viewer",
    version: "0.1.0",
    runtime: .webAssembly,
    executable: "bin/lottie-viewer.wasm",
    capabilities: [
        .commands,
        .panels,
        .settings,
        .mediaDocuments,
        .attachmentsPreview,
        .attachmentFileTypes,
        .hostProjectsRead,
        .hostProjectFilesRead
    ],
    settings: viewerSettings
)

// MARK: - State

/// Everything the extension knows, which is deliberately little: handles and metadata the host
/// published, never bytes and never a path it could open.
struct ViewerState {
    var projectID: String?
    var handles: [ExtensionFileHandle] = []
    var filter = ""
    var selectedHandleID: String?
    var isPlaying = true
    var loop = "loop"
    var speedPercent = 100
    var background = "checkerboard"
    /// The last `ready` report, which is where every number the panel shows comes from — the
    /// extension parses no document to learn its duration.
    var metadata: ExtensionMediaMetadata?
    var failure: String?

    var matching: [ExtensionFileHandle] {
        guard !filter.isEmpty else { return handles }
        return handles.filter {
            $0.relativePath.range(of: filter, options: .caseInsensitive) != nil
        }
    }

    var selected: ExtensionFileHandle? {
        matching.first { $0.id == selectedHandleID } ?? matching.first
    }
}

var state = ViewerState()

// MARK: - Panel

func animationsPanel() -> ExtensionPanel {
    var children: [ExtensionNode] = [
        .textInput(
            id: "filter",
            value: state.filter,
            placeholder: "Filter animations",
            accessibilityLabel: "Filter animations",
            role: .search,
            isEnabled: true
        )
    ]

    if let failure = state.failure {
        children.append(.status(failure, role: .negative))
    }

    let matching = state.matching
    if matching.isEmpty {
        children.append(.text(
            state.handles.isEmpty
                ? "No Lottie animations in this project yet."
                : "No animation matches that filter.",
            role: .detail
        ))
    } else {
        // One row per document. The list is a plain vertical stack: the host virtualizes it, so
        // the extension neither pages nor measures anything.
        children.append(.stack(
            axis: .vertical,
            spacing: .tight,
            children: matching.prefix(200).map { handle in
                .button(
                    id: "open-\(handle.id.prefix(24))",
                    title: handle.relativePath,
                    role: handle.id == state.selected?.id ? .primary : .standard,
                    isEnabled: true
                )
            }
        ))
    }

    if let handle = state.selected {
        children.append(.media(ExtensionMediaDocument(
            // Stable across a panel replacement, so changing the filter or the speed picker does
            // not restart the animation. A *different* document is a different id.
            id: "animation-\(handle.id.prefix(24))",
            source: .fileHandle(handle.id),
            format: handle.relativePath.hasSuffix(".lottie") ? .dotLottie : .lottie,
            playback: ExtensionMediaPlayback(
                isPlaying: state.isPlaying,
                loop: ExtensionMediaLoopMode(rawValue: state.loop) ?? .loop,
                speed: Double(state.speedPercent) / 100,
                background: ExtensionMediaBackground(rawValue: state.background) ?? .surface
            ),
            allowsFrameCopy: true,
            accessibilityLabel: "Animation \(handle.name)",
            stateActionID: "playback-state"
        )))
        children.append(.stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .picker(
                    id: "loop-mode",
                    selection: state.loop,
                    options: [
                        .init(value: "once", title: "Once"),
                        .init(value: "loop", title: "Loop"),
                        .init(value: "ping-pong", title: "Back and forth")
                    ],
                    accessibilityLabel: "Loop mode",
                    isEnabled: true
                ),
                .picker(
                    id: "speed",
                    selection: String(state.speedPercent),
                    options: [50, 100, 200].map {
                        .init(value: String($0), title: "\($0)%")
                    },
                    accessibilityLabel: "Speed",
                    isEnabled: true
                ),
                .picker(
                    id: "background",
                    selection: state.background,
                    options: [
                        .init(value: "surface", title: "Pane surface"),
                        .init(value: "checkerboard", title: "Checkerboard"),
                        .init(value: "transparent", title: "Transparent")
                    ],
                    accessibilityLabel: "Canvas",
                    isEnabled: true
                )
            ]
        ))
        children.append(.text(describe(handle), role: .detail))
    }

    return ExtensionPanel(
        id: "animations",
        title: "Animations",
        root: .stack(axis: .vertical, spacing: .medium, children: children),
        loadActionID: "load"
    )
}

/// The reading under the canvas. Every number in it came from the host's own `ready` report or
/// from the handle's bounded metadata; the extension has parsed nothing.
func describe(_ handle: ExtensionFileHandle) -> String {
    var parts = ["\(handle.byteSize) bytes"]
    if let metadata = state.metadata {
        parts.append(String(format: "%.2fs", metadata.duration))
        parts.append("\(Int(metadata.frameRate)) fps")
        parts.append("\(metadata.pixelWidth)×\(metadata.pixelHeight)")
        parts.append("\(metadata.layerCount) layers")
        parts.append(contentsOf: metadata.notes)
    }
    return parts.joined(separator: " · ")
}

func registration() -> ExtensionRegistration {
    ExtensionRegistration(
        commands: [
            ExtensionCommand(
                id: "show-animations",
                title: "Show Animations",
                description: "Open the project's Lottie animations in the display panel.",
                scope: .project,
                menuPlacements: [.extensions, .projectRow]
            )
        ],
        panels: [animationsPanel()],
        previewableFileTypes: [
            ExtensionPreviewableFileType(fileExtension: "lottie", displayName: "Lottie animation")
        ]
    )
}

// MARK: - Host data

func refreshHandles(through host: ExtensionHostClient, projectID: String?) async {
    guard let projectID else {
        state.failure = "Open this panel from a project to list its animations."
        return
    }
    state.projectID = projectID
    do {
        var collected: [ExtensionFileHandle] = []
        var cursor: String?
        // Paged rather than asked for in one go: the query has a maximum and the host answers
        // with a cursor, and a list that ignored it would silently show the first page as if it
        // were the whole project.
        repeat {
            let page = try await host.projectFiles(ExtensionFileQuery(
                projectID: projectID,
                fileExtensions: ["json", "lottie"],
                maximumResults: 200,
                cursor: cursor
            ))
            collected.append(contentsOf: page.handles)
            cursor = page.nextCursor
        } while cursor != nil && collected.count < 1_000

        // The host already told us what it recognized inside each file, so the list needs no
        // parser of its own to tell a Lottie from a `package.json`.
        state.handles = collected.filter {
            $0.contentHint == .lottie || $0.contentHint == .dotLottie
        }
        state.failure = state.handles.isEmpty ? nil : nil
    } catch {
        state.failure = "Could not list this project's animations."
    }
}

// MARK: - Attachment previews

func previewBody(for attachment: ExtensionAttachmentContext) -> ExtensionNode? {
    // An extension **offers**; it does not own a type. Declining a PDF is the ordinary case, and
    // the host simply moves to the next candidate.
    let format: ExtensionMediaFormat
    switch attachment.contentHint {
    case .some(.lottie): format = .lottie
    case .some(.dotLottie): format = .dotLottie
    default: return nil
    }
    return .stack(
        axis: .vertical,
        spacing: .small,
        children: [
            .media(ExtensionMediaDocument(
                id: "attachment",
                // Valid only inside this contract: replayed into a panel it resolves to nothing.
                source: .sessionAttachment(attachment.attachmentID),
                format: format,
                playback: ExtensionMediaPlayback(isPlaying: true, loop: .loop),
                accessibilityLabel: "Animation \(attachment.name)"
            )),
            .text(attachment.name, role: .detail)
        ]
    )
}

// MARK: - Protocol loop

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
    var settingValues = viewerSettings.effectiveValues(
        overriding: try ExtensionSettingsEnvironment.values()
    )
    applySettings(settingValues)

    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8) else {
            FileHandle.standardError.write(Data("Request was not UTF-8.\n".utf8))
            exit(65)
        }

        if let request = try? JSONDecoder().decode(
            ExtensionAttachmentPreviewRequest.self,
            from: data
        ), (try? request.validate()) != nil {
            let response = ExtensionAttachmentPreviewResponse(
                requestID: request.requestID,
                attachmentID: request.attachment.attachmentID,
                content: previewBody(for: request.attachment)
            )
            try response.validate()
            try writeProtocolValue(response)
            continue
        }

        if let settingsRequest = try? JSONDecoder().decode(
            ExtensionSettingsUpdateRequest.self,
            from: data
        ), (try? settingsRequest.validate(against: viewerSettings)) != nil {
            settingValues.merge(settingsRequest.values) { _, newValue in newValue }
            applySettings(settingValues)
            let response = ExtensionSettingsUpdateResponse(
                requestID: settingsRequest.requestID,
                settingIDs: settingsRequest.values.keys.sorted()
            )
            try response.validate()
            try writeProtocolValue(response)
            continue
        }

        if let commandRequest = try? JSONDecoder().decode(
            ExtensionCommandRequest.self,
            from: data
        ), (try? commandRequest.validate()) != nil {
            await refreshHandles(through: host, projectID: commandRequest.context.projectID)
            let response = ExtensionCommandResponse(
                requestID: commandRequest.requestID,
                commandID: commandRequest.commandID,
                message: "Open the Animations panel in the display panel."
            )
            try response.validate()
            try writeProtocolValue(response)
            continue
        }

        guard let request = try? JSONDecoder().decode(ExtensionActionRequest.self, from: data),
              (try? request.validate()) != nil else {
            FileHandle.standardError.write(Data("Unrecognized request.\n".utf8))
            exit(65)
        }

        switch request.actionID {
        case "load":
            await refreshHandles(through: host, projectID: request.context.projectID)

        case "filter":
            if case .string(let value) = request.value { state.filter = value }

        case "loop-mode":
            if case .string(let value) = request.value { state.loop = value }

        case "speed":
            if case .string(let value) = request.value, let percent = Int(value) {
                state.speedPercent = percent
            }

        case "background":
            if case .string(let value) = request.value { state.background = value }

        case "playback-state":
            // The host's own coalesced report: `ready`, `completed`, `failed`, play/pause and
            // scrub end. Never per frame — this is a JSONL round trip.
            if let value = request.value,
               let report = ExtensionMediaStateReport(actionValue: value) {
                if let metadata = report.metadata { state.metadata = metadata }
                state.isPlaying = report.phase == .playing
                state.failure = report.failure?.message
            }

        default:
            if request.actionID.hasPrefix("open-") {
                let prefix = String(request.actionID.dropFirst("open-".count))
                state.selectedHandleID = state.handles.first {
                    $0.id.hasPrefix(prefix)
                }?.id
                state.metadata = nil
                state.failure = nil
            }
        }

        let response = ExtensionActionResponse(
            requestID: request.requestID,
            panel: animationsPanel()
        )
        try response.validate()
        try writeProtocolValue(response)
    }

default:
    FileHandle.standardError.write(
        Data("Expected --threading-register or --threading-serve from the Threading host.\n".utf8)
    )
    exit(64)
}

func applySettings(_ values: [String: ExtensionJSONValue]) {
    if case .string(let loop)? = values["loop-mode"] { state.loop = loop }
    if case .integer(let speed)? = values["speed"] { state.speedPercent = Int(speed) }
    if case .string(let background)? = values["background"] { state.background = background }
}
