import Foundation

/// The semantic purpose of an editable extension field.
///
/// Threading chooses the concrete native field and its chrome. The role only distinguishes a
/// general value from a filter, whose magnifier is meaningful to sighted users.
public enum ExtensionTextInputRole: String, Codable, Equatable, Sendable {
    case text
    case search
}

/// One stable value and its user-facing title in an extension picker.
public struct ExtensionPickerOption: Codable, Equatable, Sendable {
    public let value: String
    public let title: String
    public let isEnabled: Bool

    public init(value: String, title: String, isEnabled: Bool = true) {
        self.value = value
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// A rectangle in a scene's normalized, top-leading coordinate space.
///
/// Normalized geometry keeps an extension out of host layout. Threading remains free to size a
/// panel, apply its own scale and spacing, and adapt the same scene to another presentation.
public struct ExtensionSceneRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Host-owned shapes which cover treemaps, heatmaps, bars, timelines, scatter plots and bubbles
/// without accepting drawing code or raw paths from an extension.
public enum ExtensionSceneShape: String, Codable, Equatable, Sendable {
    case rectangle
    case roundedRectangle
    case ellipse
}

/// A semantic colour, resolved through the active Threading theme.
///
/// Categories distinguish peers; status roles carry meaning. Extensions do not send RGB values.
public enum ExtensionSceneColorRole: String, Codable, Equatable, Sendable {
    case neutral
    case accent
    case positive
    case warning
    case negative
    case category1
    case category2
    case category3
    case category4
    case category5
    case category6
}

/// One interactive or informative region in a host-rendered scene.
///
/// Array order is paint order. When `actionID` is present, activating the mark raises that action
/// and sends the mark's `id` as the correlated action value.
public struct ExtensionSceneItem: Codable, Equatable, Sendable {
    public let id: String
    public let frame: ExtensionSceneRect
    public let shape: ExtensionSceneShape
    public let color: ExtensionSceneColorRole
    public let label: String?
    public let detail: String?
    public let accessibilityLabel: String?
    public let accessibilityValue: String?
    public let actionID: String?
    public let isEnabled: Bool
    public let isSelected: Bool

    public init(
        id: String,
        frame: ExtensionSceneRect,
        shape: ExtensionSceneShape = .roundedRectangle,
        color: ExtensionSceneColorRole = .neutral,
        label: String? = nil,
        detail: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        actionID: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false
    ) {
        self.id = id
        self.frame = frame
        self.shape = shape
        self.color = color
        self.label = label
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.actionID = actionID
        self.isEnabled = isEnabled
        self.isSelected = isSelected
    }
}

/// A bounded semantic visualization laid out by an extension and rendered by Threading.
///
/// This is deliberately a scene rather than a named chart or file-tree widget. The same safe,
/// native primitive can express a package treemap, release comparison, heatmap, bar chart,
/// timeline or scatter plot while Threading continues to own pixels and interaction.
public struct ExtensionScene: Codable, Equatable, Sendable {
    public let accessibilityLabel: String
    /// Width divided by height.
    public let preferredAspectRatio: Double
    public let items: [ExtensionSceneItem]

    public init(
        accessibilityLabel: String,
        preferredAspectRatio: Double = 1.6,
        items: [ExtensionSceneItem]
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.preferredAspectRatio = preferredAspectRatio
        self.items = items
    }

    func validationIssues(
        path: String,
        maximumItems: Int,
        maximumTextLength: Int
    ) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        let trimmedLabel = accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty {
            issues.append(.init(
                path: "\(path).accessibilityLabel",
                message: "must not be empty"
            ))
        } else if accessibilityLabel.count > maximumTextLength {
            issues.append(.init(
                path: "\(path).accessibilityLabel",
                message: "exceeds maximum length \(maximumTextLength)"
            ))
        }
        if !preferredAspectRatio.isFinite
            || preferredAspectRatio < 0.5
            || preferredAspectRatio > 4 {
            issues.append(.init(
                path: "\(path).preferredAspectRatio",
                message: "must be finite and between 0.5 and 4"
            ))
        }
        if items.isEmpty {
            issues.append(.init(path: "\(path).items", message: "must not be empty"))
        } else if items.count > maximumItems {
            issues.append(.init(
                path: "\(path).items",
                message: "exceeds maximum item count \(maximumItems)"
            ))
        }

        var seenIDs = Set<String>()
        for (index, item) in items.enumerated() {
            let itemPath = "\(path).items[\(index)]"
            let trimmedID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedID.isEmpty {
                issues.append(.init(path: "\(itemPath).id", message: "must not be empty"))
            } else if item.id.count > 256 {
                issues.append(.init(
                    path: "\(itemPath).id",
                    message: "must contain at most 256 characters"
                ))
            } else if !seenIDs.insert(item.id).inserted {
                issues.append(.init(path: "\(itemPath).id", message: "must be unique"))
            }

            let frame = item.frame
            let values = [frame.x, frame.y, frame.width, frame.height]
            if values.contains(where: { !$0.isFinite })
                || frame.x < 0
                || frame.y < 0
                || frame.width <= 0
                || frame.height <= 0
                || frame.x + frame.width > 1
                || frame.y + frame.height > 1 {
                issues.append(.init(
                    path: "\(itemPath).frame",
                    message: "must be a positive finite rectangle inside normalized bounds"
                ))
            }

            if let actionID = item.actionID,
               !ExtensionIdentifierRules.isContributionIdentifier(actionID) {
                issues.append(.init(
                    path: "\(itemPath).actionID",
                    message: ExtensionIdentifierRules.contributionMessage
                ))
            }
            for (key, value) in [
                ("label", item.label),
                ("detail", item.detail),
                ("accessibilityLabel", item.accessibilityLabel),
                ("accessibilityValue", item.accessibilityValue)
            ] {
                guard let value else { continue }
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(
                        path: "\(itemPath).\(key)",
                        message: "must not be empty when present"
                    ))
                } else if value.count > maximumTextLength {
                    issues.append(.init(
                        path: "\(itemPath).\(key)",
                        message: "exceeds maximum length \(maximumTextLength)"
                    ))
                }
            }
            if item.label == nil, item.accessibilityLabel == nil {
                issues.append(.init(
                    path: itemPath,
                    message: "requires a label or accessibilityLabel"
                ))
            }
        }
        return issues
    }
}
