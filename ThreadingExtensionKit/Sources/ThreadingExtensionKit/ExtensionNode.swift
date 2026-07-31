import Foundation

/// A host-rendered UI tree supplied by an extension.
///
/// These are semantic values, not view instructions. Threading decides the concrete control,
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
    /// A native editable field which raises `id` with its string value.
    case textInput(
        id: String,
        value: String,
        placeholder: String?,
        accessibilityLabel: String,
        role: ExtensionTextInputRole,
        isEnabled: Bool
    )
    /// A native single-choice control which raises `id` with the selected option value.
    case picker(
        id: String,
        selection: String?,
        options: [ExtensionPickerOption],
        accessibilityLabel: String,
        isEnabled: Bool
    )
    /// A host-rendered, interactive visualization with normalized semantic marks.
    case scene(ExtensionScene)
    case status(String, role: ExtensionStatusRole)
    /// A summary that has a second level behind it.
    ///
    /// `summary` is what the surface shows in place — one compact reading, subject to that
    /// surface's own vocabulary. `detail` is what the second level says, and Threading presents
    /// it on a surface of its own: the host owns the reveal gesture, its timing, the popover's
    /// placement, chrome, sizing and dismissal, so an extension states *what* is behind the
    /// summary and never *how* it opens.
    ///
    /// The revealed level has room the summary does not, so it has a vocabulary of its own —
    /// including actions, where the compact row that carries the summary usually forbids them.
    /// A surface states both budgets; see `ExtensionComponentSlot.detailConstraints`.
    case disclosure(
        id: String,
        summary: ExtensionNode,
        detail: [ExtensionNode]
    )
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
        case value
        case placeholder
        case selection
        case options
        case scene
        case isEnabled
        case reference
        case accessibilityLabel
        case spacing
        case axis
        case children
        case base
        case overlay
        case surface
        case summary
        case detail
    }

    private enum Kind: String, Codable {
        case text
        case image
        case button
        case textInput
        case picker
        case scene
        case status
        case disclosure
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
        case .textInput:
            self = .textInput(
                id: try container.decode(String.self, forKey: .id),
                value: try container.decode(String.self, forKey: .value),
                placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder),
                accessibilityLabel: try container.decode(
                    String.self,
                    forKey: .accessibilityLabel
                ),
                role: try container.decode(ExtensionTextInputRole.self, forKey: .role),
                isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
            )
        case .picker:
            self = .picker(
                id: try container.decode(String.self, forKey: .id),
                selection: try container.decodeIfPresent(String.self, forKey: .selection),
                options: try container.decode([ExtensionPickerOption].self, forKey: .options),
                accessibilityLabel: try container.decode(
                    String.self,
                    forKey: .accessibilityLabel
                ),
                isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
            )
        case .scene:
            self = .scene(try container.decode(ExtensionScene.self, forKey: .scene))
        case .status:
            self = .status(
                try container.decode(String.self, forKey: .text),
                role: try container.decode(ExtensionStatusRole.self, forKey: .role)
            )
        case .disclosure:
            self = .disclosure(
                id: try container.decode(String.self, forKey: .id),
                summary: try container.decode(Self.self, forKey: .summary),
                detail: try container.decode([ExtensionNode].self, forKey: .detail)
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
        case .textInput(
            let id,
            let value,
            let placeholder,
            let accessibilityLabel,
            let role,
            let isEnabled
        ):
            try container.encode(Kind.textInput, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(placeholder, forKey: .placeholder)
            try container.encode(accessibilityLabel, forKey: .accessibilityLabel)
            try container.encode(role, forKey: .role)
            try container.encode(isEnabled, forKey: .isEnabled)
        case .picker(let id, let selection, let options, let accessibilityLabel, let isEnabled):
            try container.encode(Kind.picker, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(selection, forKey: .selection)
            try container.encode(options, forKey: .options)
            try container.encode(accessibilityLabel, forKey: .accessibilityLabel)
            try container.encode(isEnabled, forKey: .isEnabled)
        case .scene(let scene):
            try container.encode(Kind.scene, forKey: .type)
            try container.encode(scene, forKey: .scene)
        case .status(let text, let role):
            try container.encode(Kind.status, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(role, forKey: .role)
        case .disclosure(let id, let summary, let detail):
            try container.encode(Kind.disclosure, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(summary, forKey: .summary)
            try container.encode(detail, forKey: .detail)
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
