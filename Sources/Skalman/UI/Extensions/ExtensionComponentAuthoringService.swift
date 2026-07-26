import AppKit
import SkalmanExtensionKit

enum ExtensionComponentAuthoringError: Error, LocalizedError {
    case missingComponent(String, version: Int?)
    case patchTooLarge(maximumBytes: Int)
    case invalidPatchJSON(String)
    case couldNotRenderPreview
    case couldNotWritePreview

    var errorDescription: String? {
        switch self {
        case .missingComponent(let id, let version):
            let suffix = version.map { " version \($0)" } ?? ""
            return "Unknown extension component '\(id)'\(suffix)."
        case .patchTooLarge(let maximumBytes):
            return "The patch JSON exceeds the \(maximumBytes)-byte authoring limit."
        case .invalidPatchJSON(let message):
            return "Could not decode the component patch JSON: \(message)"
        case .couldNotRenderPreview:
            return "Skalman could not render the component preview."
        case .couldNotWritePreview:
            return "Skalman could not save the component preview image."
        }
    }
}

/// Host-side authoring API behind the MCP tools.
///
/// It owns no MCP values. The same service is therefore directly testable and can later back
/// an in-app extension editor without coupling that editor to the agent protocol.
@MainActor
enum ExtensionComponentAuthoringService {
    private static let maximumPatchBytes = 128 * 1_024

    private struct ComponentSummary: Encodable {
        let id: String
        let version: Int
        let context: String
        let summary: String
    }

    private struct ComponentList: Encodable {
        let formatVersion: Int
        let components: [ComponentSummary]
    }

    private struct ValidationResult: Encodable {
        let valid: Bool
        let patchID: String
        let component: String
        let contractVersion: Int
    }

    struct Preview {
        let image: NSImage
        let url: URL
        let componentID: String
    }

    static func listJSON() throws -> String {
        try encode(
            ComponentList(
                formatVersion: ExtensionComponentCatalogDocument.currentFormatVersion,
                components: SkalmanComponentCatalog.entries.map {
                    ComponentSummary(
                        id: $0.contract.id.rawValue,
                        version: $0.contract.version,
                        context: $0.contract.context.rawValue,
                        summary: $0.summary
                    )
                }
            )
        )
    }

    static func describeJSON(componentID: String, version: Int?) throws -> String {
        guard let entry = SkalmanComponentCatalog.entry(
            id: ExtensionComponentID(rawValue: componentID),
            version: version
        ) else {
            throw ExtensionComponentAuthoringError.missingComponent(
                componentID,
                version: version
            )
        }
        return try encode(
            ExtensionComponentDescription(
                entry: entry,
                patchSchema: SkalmanComponentCatalog.patchSchema(for: entry.contract)
            )
        )
    }

    static func validateJSON(_ patchJSON: String) throws -> String {
        let (patch, contract) = try decodeAndValidate(patchJSON)
        return try encode(
            ValidationResult(
                valid: true,
                patchID: patch.id,
                component: contract.id.rawValue,
                contractVersion: contract.version
            )
        )
    }

    static func preview(_ patchJSON: String) throws -> Preview {
        let (patch, contract) = try decodeAndValidate(patchJSON)
        let image = try ExtensionComponentPatchPreviewRenderer.render(
            patch,
            contract: contract
        )

        guard let representation = image.representations.first as? NSBitmapImageRep,
              let data = representation.representation(using: .png, properties: [:]) else {
            throw ExtensionComponentAuthoringError.couldNotWritePreview
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkalmanComponentPreviews",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "\(contract.id.rawValue)-\(UUID().uuidString).png"
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExtensionComponentAuthoringError.couldNotWritePreview
        }

        return Preview(
            image: image,
            url: url,
            componentID: contract.id.rawValue
        )
    }

    static func validationMessage(for error: Error) -> String {
        if let validation = error as? ExtensionValidationError {
            return validation.issues.map(\.description).joined(separator: "\n")
        }
        return error.localizedDescription
    }

    private static func decodeAndValidate(
        _ patchJSON: String
    ) throws -> (ExtensionComponentPatch, ExtensionComponentContract) {
        let data = Data(patchJSON.utf8)
        guard data.count <= maximumPatchBytes else {
            throw ExtensionComponentAuthoringError.patchTooLarge(
                maximumBytes: maximumPatchBytes
            )
        }

        let patch: ExtensionComponentPatch
        do {
            patch = try JSONDecoder().decode(ExtensionComponentPatch.self, from: data)
        } catch {
            throw ExtensionComponentAuthoringError.invalidPatchJSON(error.localizedDescription)
        }

        guard let entry = SkalmanComponentCatalog.entry(
            id: patch.target.component,
            version: patch.target.contractVersion
        ) else {
            throw ExtensionComponentAuthoringError.missingComponent(
                patch.target.component.rawValue,
                version: patch.target.contractVersion
            )
        }

        try entry.contract.validate(patch)
        return (patch, entry.contract)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

@MainActor
private enum ExtensionComponentPatchPreviewRenderer {
    private static let canvasSize = NSSize(width: 520, height: 156)

    static func render(
        _ patch: ExtensionComponentPatch,
        contract: ExtensionComponentContract
    ) throws -> NSImage {
        let node = previewNode(for: patch, contract: contract)
        let rendered = try ExtensionNodeRenderer.render(
            node,
            imageResolver: resolvePreviewImage,
            customSurfaceRenderer: { surface in
                let label = NSTextField(
                    labelWithString: "\(surface.kind.rawValue.capitalized) custom surface"
                )
                label.alignment = .center
                label.font = Design.Typography.detail()
                label.textColor = Design.Text.secondary
                label.applySurface(
                    fill: Design.Surface.controlResting,
                    radius: .control,
                    border: Design.Surface.border
                )
                return label
            },
            onAction: { _ in }
        )
        if patch.hook != nil {
            let next = try ExtensionNodeRenderer.render(
                previewNativeNode(for: contract),
                imageResolver: resolvePreviewImage,
                onAction: { _ in }
            )
            guard rendered.installProceedContent(next) else {
                throw ExtensionComponentAuthoringError.couldNotRenderPreview
            }
        }

        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0)
        )

        let heading = NSTextField(
            labelWithString: "\(contract.id.rawValue) · v\(contract.version)"
        )
        heading.font = Design.Typography.caption()
        heading.textColor = Design.Text.secondary

        let shell = NSView()
        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.applySurface(
            fill: Design.Surface.panel,
            radius: .control,
            border: Design.Surface.border
        )
        rendered.translatesAutoresizingMaskIntoConstraints = false
        shell.addSubview(rendered)

        let owned = contract.hostOwnedBehavior.map(\.rawValue).joined(separator: " · ")
        let footer = NSTextField(
            labelWithString: owned.isEmpty ? "No host-owned behavior" : "Host keeps \(owned)"
        )
        footer.font = Design.Typography.detail()
        footer.textColor = Design.Text.tertiary
        footer.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [heading, shell, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(
                equalTo: canvas.topAnchor,
                constant: Design.Spacing.large
            ),
            stack.leadingAnchor.constraint(
                equalTo: canvas.leadingAnchor,
                constant: Design.Spacing.large
            ),
            stack.trailingAnchor.constraint(
                equalTo: canvas.trailingAnchor,
                constant: -Design.Spacing.large
            ),
            shell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shell.heightAnchor.constraint(equalToConstant: 42),
            rendered.leadingAnchor.constraint(
                equalTo: shell.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            rendered.trailingAnchor.constraint(
                equalTo: shell.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            rendered.centerYAnchor.constraint(equalTo: shell.centerYAnchor)
        ])

        canvas.layoutSubtreeIfNeeded()
        guard let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)
        else {
            throw ExtensionComponentAuthoringError.couldNotRenderPreview
        }
        canvas.cacheDisplay(in: canvas.bounds, to: representation)

        let image = NSImage(size: canvasSize)
        image.addRepresentation(representation)
        return image
    }

    private static func previewNode(
        for patch: ExtensionComponentPatch,
        contract: ExtensionComponentContract
    ) -> ExtensionNode {
        if let hook = patch.hook {
            return hook
        }
        if let replacement = patch.replacement {
            return replacement
        }

        let title = patch.properties.compactMap { property -> String? in
            guard property.property == .title,
                  case .text(let text) = property.value else { return nil }
            return text
        }.last ?? defaultTitle(for: contract)

        let identity = patch.properties.compactMap { property -> ExtensionImageReference? in
            guard property.property == .identityImage,
                  case .image(let image) = property.value else { return nil }
            return image
        }.last ?? defaultImage(for: contract)

        var children: [ExtensionNode] = [
            .image(identity, role: .identity, accessibilityLabel: "Preview identity"),
            .text(title, role: .compactBody)
        ]
        children.append(contentsOf: patch.slots.flatMap(\.children))
        children.append(.flexibleSpacer)
        children.append(.status("Host state", role: .neutral))
        return .stack(axis: .horizontal, spacing: .small, children: children)
    }

    private static func previewNativeNode(
        for contract: ExtensionComponentContract
    ) -> ExtensionNode {
        .stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .image(
                    defaultImage(for: contract),
                    role: .identity,
                    accessibilityLabel: "Native content"
                ),
                .text(defaultTitle(for: contract), role: .compactBody),
                .flexibleSpacer
            ]
        )
    }

    private static func defaultTitle(
        for contract: ExtensionComponentContract
    ) -> String {
        contract.context == .projectPresentation
            ? "Example project"
            : "Example conversation"
    }

    private static func defaultImage(
        for contract: ExtensionComponentContract
    ) -> ExtensionImageReference {
        contract.context == .projectPresentation
            ? .hostAsset("project.image")
            : .hostAsset("session.provider-image")
    }

    private static func resolvePreviewImage(_ reference: ExtensionImageReference) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .hostAsset(let identifier):
            let symbol: String
            switch identifier {
            case "session.provider-image":
                symbol = "chevron.left.forwardslash.chevron.right"
            case "session.account-image":
                symbol = "person.crop.circle.fill"
            case "project.image":
                symbol = "folder.fill"
            default:
                symbol = "questionmark.square.dashed"
            }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        case .extensionResource:
            return NSImage(
                systemSymbolName: "photo.badge.exclamationmark",
                accessibilityDescription: nil
            )
        }
    }
}
