import Foundation

/// A host-rendered UI tree supplied by an extension.
///
/// These are semantic values, not view instructions. Skalman decides the concrete control,
/// typography, colour, geometry, focus treatment, accessibility and live-theme behaviour for
/// every node.
public indirect enum ExtensionNode: Equatable, Sendable {
    case text(String, role: ExtensionTextRole)
    case image(
        ExtensionImageReference,
        role: ExtensionImageRole,
        accessibilityLabel: String?
    )
    case button(
        id: String,
        title: String,
        role: ExtensionButtonRole,
        isEnabled: Bool
    )
    case status(String, role: ExtensionStatusRole)
    /// Invokes the next visual hook, eventually reaching the component's native content.
    case proceed
    /// Places extension content above existing or extension-rendered content.
    case overlay(base: ExtensionNode, overlay: ExtensionNode)
    /// A custom visual surface whose native renderer and lifecycle remain host-owned.
    case customSurface(ExtensionCustomSurface, accessibilityLabel: String?)
    case divider
    case spacer(ExtensionSpacing)
    case flexibleSpacer
    case stack(
        axis: ExtensionAxis,
        spacing: ExtensionSpacing,
        children: [ExtensionNode]
    )
}

public enum ExtensionTextRole: String, Codable, CaseIterable, Equatable, Sendable {
    case heading
    case body
    case detail
    case code
    case compactBody
    case compactDetail
}

public enum ExtensionImageRole: String, Codable, CaseIterable, Equatable, Sendable {
    case identity
    case icon
    case decoration
}

public enum ExtensionButtonRole: String, Codable, CaseIterable, Equatable, Sendable {
    case standard
    case primary
    case destructive
}

public enum ExtensionStatusRole: String, Codable, CaseIterable, Equatable, Sendable {
    case neutral
    case positive
    case warning
    case negative
}

public enum ExtensionAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum ExtensionSpacing: String, Codable, Equatable, Sendable {
    case none
    case tight
    case small
    case medium
    case large
}

extension ExtensionNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case role
        case id
        case title
        case isEnabled
        case reference
        case accessibilityLabel
        case spacing
        case axis
        case children
        case base
        case overlay
        case surface
    }

    private enum Kind: String, Codable {
        case text
        case image
        case button
        case status
        case proceed
        case overlay
        case customSurface
        case divider
        case spacer
        case flexibleSpacer
        case stack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)

        switch kind {
        case .text:
            self = .text(
                try container.decode(String.self, forKey: .text),
                role: try container.decode(ExtensionTextRole.self, forKey: .role)
            )
        case .image:
            self = .image(
                try container.decode(ExtensionImageReference.self, forKey: .reference),
                role: try container.decode(ExtensionImageRole.self, forKey: .role),
                accessibilityLabel: try container.decodeIfPresent(
                    String.self,
                    forKey: .accessibilityLabel
                )
            )
        case .button:
            self = .button(
                id: try container.decode(String.self, forKey: .id),
                title: try container.decode(String.self, forKey: .title),
                role: try container.decode(ExtensionButtonRole.self, forKey: .role),
                isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
            )
        case .status:
            self = .status(
                try container.decode(String.self, forKey: .text),
                role: try container.decode(ExtensionStatusRole.self, forKey: .role)
            )
        case .proceed:
            self = .proceed
        case .overlay:
            self = .overlay(
                base: try container.decode(Self.self, forKey: .base),
                overlay: try container.decode(Self.self, forKey: .overlay)
            )
        case .customSurface:
            self = .customSurface(
                try container.decode(ExtensionCustomSurface.self, forKey: .surface),
                accessibilityLabel: try container.decodeIfPresent(
                    String.self,
                    forKey: .accessibilityLabel
                )
            )
        case .divider:
            self = .divider
        case .spacer:
            self = .spacer(
                try container.decode(ExtensionSpacing.self, forKey: .spacing)
            )
        case .flexibleSpacer:
            self = .flexibleSpacer
        case .stack:
            self = .stack(
                axis: try container.decode(ExtensionAxis.self, forKey: .axis),
                spacing: try container.decode(ExtensionSpacing.self, forKey: .spacing),
                children: try container.decode([ExtensionNode].self, forKey: .children)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text, let role):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(role, forKey: .role)
        case .image(let reference, let role, let accessibilityLabel):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(reference, forKey: .reference)
            try container.encode(role, forKey: .role)
            try container.encodeIfPresent(accessibilityLabel, forKey: .accessibilityLabel)
        case .button(let id, let title, let role, let isEnabled):
            try container.encode(Kind.button, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(role, forKey: .role)
            try container.encode(isEnabled, forKey: .isEnabled)
        case .status(let text, let role):
            try container.encode(Kind.status, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(role, forKey: .role)
        case .proceed:
            try container.encode(Kind.proceed, forKey: .type)
        case .overlay(let base, let overlay):
            try container.encode(Kind.overlay, forKey: .type)
            try container.encode(base, forKey: .base)
            try container.encode(overlay, forKey: .overlay)
        case .customSurface(let surface, let accessibilityLabel):
            try container.encode(Kind.customSurface, forKey: .type)
            try container.encode(surface, forKey: .surface)
            try container.encodeIfPresent(accessibilityLabel, forKey: .accessibilityLabel)
        case .divider:
            try container.encode(Kind.divider, forKey: .type)
        case .spacer(let spacing):
            try container.encode(Kind.spacer, forKey: .type)
            try container.encode(spacing, forKey: .spacing)
        case .flexibleSpacer:
            try container.encode(Kind.flexibleSpacer, forKey: .type)
        case .stack(let axis, let spacing, let children):
            try container.encode(Kind.stack, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(spacing, forKey: .spacing)
            try container.encode(children, forKey: .children)
        }
    }
}
