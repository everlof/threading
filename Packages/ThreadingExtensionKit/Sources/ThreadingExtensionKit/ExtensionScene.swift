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

/// Host-owned navigation through marks that form one rooted hierarchy.
///
/// Geometry remains normalized scene geometry supplied by the producer. The hierarchy adds
/// meaning to that geometry: Threading can zoom a branch, expose native breadcrumbs, and mirror
/// the same navigation on another device without learning anything about files or artifacts.
public struct ExtensionSceneHierarchy: Codable, Equatable, Sendable {
    public let rootID: String

    public init(rootID: String) {
        self.rootID = rootID
    }
}

/// One interactive or informative region in a host-rendered scene.
///
/// Array order is paint order. When `actionID` is present, activating the mark raises that action
/// and sends the mark's `id` as the correlated action value.
public struct ExtensionSceneItem: Codable, Equatable, Sendable {
    public let id: String
    /// The enclosing mark when the scene declares a hierarchy. Nil for that hierarchy's root.
    public let parentID: String?
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
        parentID: String? = nil,
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
        self.parentID = parentID
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
    /// Optional semantic navigation over the marks. Pixels and navigation remain host-owned.
    public let hierarchy: ExtensionSceneHierarchy?
    public let items: [ExtensionSceneItem]

    public init(
        accessibilityLabel: String,
        preferredAspectRatio: Double = 1.6,
        hierarchy: ExtensionSceneHierarchy? = nil,
        items: [ExtensionSceneItem]
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.preferredAspectRatio = preferredAspectRatio
        self.hierarchy = hierarchy
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

        issues.append(contentsOf: hierarchyValidationIssues(
            path: path,
            itemIDs: seenIDs
        ))
        return issues
    }

    private func hierarchyValidationIssues(
        path: String,
        itemIDs: Set<String>
    ) -> [ExtensionValidationIssue] {
        guard let hierarchy else {
            return items.enumerated().compactMap { index, item in
                guard item.parentID != nil else { return nil }
                return ExtensionValidationIssue(
                    path: "\(path).items[\(index)].parentID",
                    message: "requires scene.hierarchy"
                )
            }
        }

        var issues: [ExtensionValidationIssue] = []
        guard itemIDs.contains(hierarchy.rootID) else {
            return [ExtensionValidationIssue(
                path: "\(path).hierarchy.rootID",
                message: "must match an item id"
            )]
        }

        var parentByID: [String: String] = [:]
        var itemByID: [String: ExtensionSceneItem] = [:]
        for item in items where parentByID[item.id] == nil {
            if itemByID[item.id] == nil { itemByID[item.id] = item }
            if let parentID = item.parentID {
                parentByID[item.id] = parentID
            }
        }
        if parentByID[hierarchy.rootID] != nil {
            issues.append(.init(
                path: "\(path).hierarchy.rootID",
                message: "must name the one item without a parent"
            ))
        }

        for (index, item) in items.enumerated() where item.id != hierarchy.rootID {
            let itemPath = "\(path).items[\(index)].parentID"
            guard let parentID = item.parentID else {
                issues.append(.init(
                    path: itemPath,
                    message: "is required for every item except the hierarchy root"
                ))
                continue
            }
            if parentID == item.id {
                issues.append(.init(path: itemPath, message: "must not name the item itself"))
            } else if !itemIDs.contains(parentID) {
                issues.append(.init(path: itemPath, message: "must match an item id"))
            } else if let parent = itemByID[parentID],
                      !parent.frame.contains(item.frame) {
                issues.append(.init(
                    path: "\(path).items[\(index)].frame",
                    message: "must be contained by parent '\(parentID)'"
                ))
            }
        }

        // Every chain must reach the declared root. This catches cycles, disconnected roots and
        // branches which only point at one another without recursively walking untrusted depth.
        for (index, item) in items.enumerated() {
            var cursor = item.id
            var visited = Set<String>()
            var reachedRoot = false
            for _ in 0...items.count {
                if cursor == hierarchy.rootID {
                    reachedRoot = true
                    break
                }
                guard visited.insert(cursor).inserted,
                      let parent = parentByID[cursor] else { break }
                cursor = parent
            }
            if !reachedRoot {
                issues.append(.init(
                    path: "\(path).items[\(index)].parentID",
                    message: "must form a branch rooted at '\(hierarchy.rootID)'"
                ))
            }
        }
        return issues
    }
}

private extension ExtensionSceneRect {
    func contains(_ other: ExtensionSceneRect) -> Bool {
        let epsilon = 0.000_000_1
        return other.x + epsilon >= x
            && other.y + epsilon >= y
            && other.x + other.width <= x + width + epsilon
            && other.y + other.height <= y + height + epsilon
    }
}
