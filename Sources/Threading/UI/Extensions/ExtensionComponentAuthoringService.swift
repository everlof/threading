import AppKit
import ThreadingExtensionKit

/// AppKit preview adapter for patches validated by `ExtensionComponentAuthoringCatalog`.
///
/// Catalog identity and schema rules stay in Application; this type owns pixels and temporary
/// preview artifacts only.
@MainActor
enum ExtensionComponentAuthoringService {
    struct Preview {
        let image: NSImage
        let url: URL
        let componentID: String
    }

    static func preview(_ patchJSON: String) throws -> Preview {
        let (patch, contract) = try ExtensionComponentAuthoringCatalog.decodeAndValidate(
            patchJSON
        )
        let image = try ExtensionComponentPatchPreviewRenderer.render(
            patch,
            contract: contract
        )

        guard let representation = image.representations.first as? NSBitmapImageRep,
              let data = representation.representation(using: .png, properties: [:]) else {
            throw ExtensionComponentAuthoringError.couldNotWritePreview
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingComponentPreviews",
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
        ExtensionComponentAuthoringCatalog.validationMessage(for: error)
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
                    labelWithString: L10n.format(
                        "%@ custom surface",
                        surface.kind.rawValue.capitalized
                    )
                )
                label.alignment = .center
                label.applyFont(.detail())
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
        heading.applyFont(.caption)
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
        footer.applyFont(.detail())
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
