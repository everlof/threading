import Foundation

/// A host navigation destination activated without a round trip through extension code.
///
/// The host validates the referenced entity against its current snapshot before navigating.
/// Extensions never receive an authority to open arbitrary files or construct host routes.
public enum ExtensionWorkspaceNavigatorDestination: Codable, Equatable, Sendable {
    case project(id: String)
    case session(id: String, projectID: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case projectID
    }

    private enum Kind: String, Codable {
        case project
        case session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .project:
            self = .project(id: try container.decode(String.self, forKey: .id))
        case .session:
            self = .session(
                id: try container.decode(String.self, forKey: .id),
                projectID: try container.decodeIfPresent(String.self, forKey: .projectID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project(let id):
            try container.encode(Kind.project, forKey: .type)
            try container.encode(id, forKey: .id)
        case .session(let id, let projectID):
            try container.encode(Kind.session, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(projectID, forKey: .projectID)
        }
    }

    fileprivate func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        let identifiers: [(String, String?)]
        switch self {
        case .project(let id):
            identifiers = [("id", id)]
        case .session(let id, let projectID):
            identifiers = [("id", id), ("projectID", projectID)]
        }
        for (key, value) in identifiers {
            guard let value else { continue }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).\(key)", message: "must not be empty"))
            } else if value.count > 256 {
                issues.append(.init(
                    path: "\(path).\(key)",
                    message: "must contain at most 256 characters"
                ))
            }
        }
        return issues
    }
}

/// What happens when a navigator item is activated.
///
/// Host destinations navigate synchronously. Extension actions are routed to the process and are
/// appropriate for extension-owned state. A single enum prevents an item from ambiguously doing
/// both.
public enum ExtensionWorkspaceNavigatorActivation: Codable, Equatable, Sendable {
    case destination(ExtensionWorkspaceNavigatorDestination)
    case action(id: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case destination
        case id
    }

    private enum Kind: String, Codable {
        case destination
        case action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .destination:
            self = .destination(
                try container.decode(
                    ExtensionWorkspaceNavigatorDestination.self,
                    forKey: .destination
                )
            )
        case .action:
            self = .action(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .destination(let destination):
            try container.encode(Kind.destination, forKey: .type)
            try container.encode(destination, forKey: .destination)
        case .action(let id):
            try container.encode(Kind.action, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }

    fileprivate func validationIssues(path: String) -> [ExtensionValidationIssue] {
        switch self {
        case .destination(let destination):
            return destination.validationIssues(path: "\(path).destination")
        case .action(let id):
            guard ExtensionIdentifierRules.isContributionIdentifier(id) else {
                return [.init(
                    path: "\(path).id",
                    message: ExtensionIdentifierRules.contributionMessage
                )]
            }
            return []
        }
    }
}

/// The host-owned collection behavior used by a workspace navigator.
public enum ExtensionWorkspaceNavigatorCollectionLayout: Codable, Equatable, Sendable {
    case list
    case outline
    case grid(columns: Int)

    private enum CodingKeys: String, CodingKey {
        case type
        case columns
    }

    private enum Kind: String, Codable {
        case list
        case outline
        case grid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .list:
            self = .list
        case .outline:
            self = .outline
        case .grid:
            self = .grid(columns: try container.decode(Int.self, forKey: .columns))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .list:
            try container.encode(Kind.list, forKey: .type)
        case .outline:
            try container.encode(Kind.outline, forKey: .type)
        case .grid(let columns):
            try container.encode(Kind.grid, forKey: .type)
            try container.encode(columns, forKey: .columns)
        }
    }
}

public enum ExtensionWorkspaceNavigatorSelectionMode: String, Codable, Equatable, Sendable {
    case none
    case single
}

/// A section in a navigator collection.
///
/// Its header is ordinary semantic content, allowing a plain label, count, status, or actions
/// without teaching the collection about any project or lifecycle vocabulary.
public struct ExtensionWorkspaceNavigatorSection: Codable, Equatable, Sendable {
    public let id: String
    public let header: ExtensionNode?

    public init(id: String, header: ExtensionNode? = nil) {
        self.id = id
        self.header = header
    }
}

/// One virtualizable navigator row or grid cell.
public struct ExtensionWorkspaceNavigatorItem: Codable, Equatable, Sendable {
    public let id: String
    public let sectionID: String?
    public let parentID: String?
    public let content: ExtensionNode
    /// A concise name for the item-level activation surface.
    ///
    /// Grid items with an activation require this because their host-owned selectable cell is
    /// itself an accessibility element. List and outline rows may derive their semantics from
    /// their rendered content, but may still provide an explicit name.
    public let accessibilityLabel: String?
    public let activation: ExtensionWorkspaceNavigatorActivation?
    public let isEnabled: Bool
    public let isSelected: Bool
    public let isExpanded: Bool

    public init(
        id: String,
        sectionID: String? = nil,
        parentID: String? = nil,
        content: ExtensionNode,
        accessibilityLabel: String? = nil,
        activation: ExtensionWorkspaceNavigatorActivation? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.sectionID = sectionID
        self.parentID = parentID
        self.content = content
        self.accessibilityLabel = accessibilityLabel
        self.activation = activation
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.isExpanded = isExpanded
    }
}

/// One bounded content update for an existing navigator row or grid item.
///
/// Item patches deliberately cannot insert, remove, reorder, reparent, retarget, select, or
/// enable an item. They are the live-reading path for facts such as activity while the complete
/// navigator document remains the authority for structure and interaction.
public struct ExtensionWorkspaceNavigatorItemPatch: Codable, Equatable, Sendable {
    public let collectionID: String
    public let itemID: String
    public let content: ExtensionNode

    public init(collectionID: String, itemID: String, content: ExtensionNode) {
        self.collectionID = collectionID
        self.itemID = itemID
        self.content = content
    }

    func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        for (field, value) in [
            ("collectionID", collectionID),
            ("itemID", itemID)
        ] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).\(field)", message: "must not be empty"))
            } else if value.count > 256 {
                issues.append(.init(
                    path: "\(path).\(field)",
                    message: "must contain at most 256 characters"
                ))
            }
        }
        do {
            try ExtensionWorkspaceNavigator.itemConstraints.validate(
                content,
                path: "\(path).content"
            )
        } catch let error as ExtensionValidationError {
            issues.append(contentsOf: error.issues)
        } catch {
            issues.append(.init(path: "\(path).content", message: error.localizedDescription))
        }
        return issues
    }
}

/// A bounded snapshot which the host can render with row reuse and diff by stable item ID.
public struct ExtensionWorkspaceNavigatorCollection: Codable, Equatable, Sendable {
    public let id: String
    public let layout: ExtensionWorkspaceNavigatorCollectionLayout
    public let selectionMode: ExtensionWorkspaceNavigatorSelectionMode
    public let sections: [ExtensionWorkspaceNavigatorSection]
    public let items: [ExtensionWorkspaceNavigatorItem]

    public init(
        id: String,
        layout: ExtensionWorkspaceNavigatorCollectionLayout,
        selectionMode: ExtensionWorkspaceNavigatorSelectionMode = .single,
        sections: [ExtensionWorkspaceNavigatorSection] = [],
        items: [ExtensionWorkspaceNavigatorItem]
    ) {
        self.id = id
        self.layout = layout
        self.selectionMode = selectionMode
        self.sections = sections
        self.items = items
    }
}

/// The whole extension-owned interior of Threading's host-owned navigator shell.
///
/// `content` embeds the existing semantic UI vocabulary. Collections remain a distinct node so a
/// future renderer can realize only visible items instead of eagerly building every row.
public indirect enum ExtensionWorkspaceNavigatorNode: Codable, Equatable, Sendable {
    case content(ExtensionNode)
    case collection(ExtensionWorkspaceNavigatorCollection)
    case divider
    case spacer(ExtensionSpacing)
    case flexibleSpacer
    case stack(
        axis: ExtensionAxis,
        spacing: ExtensionSpacing,
        children: [ExtensionWorkspaceNavigatorNode]
    )
    case overlay(
        base: ExtensionWorkspaceNavigatorNode,
        overlay: ExtensionWorkspaceNavigatorNode
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case collection
        case spacing
        case axis
        case children
        case base
        case overlay
    }

    private enum Kind: String, Codable {
        case content
        case collection
        case divider
        case spacer
        case flexibleSpacer
        case stack
        case overlay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .content:
            self = .content(try container.decode(ExtensionNode.self, forKey: .content))
        case .collection:
            self = .collection(
                try container.decode(
                    ExtensionWorkspaceNavigatorCollection.self,
                    forKey: .collection
                )
            )
        case .divider:
            self = .divider
        case .spacer:
            self = .spacer(try container.decode(ExtensionSpacing.self, forKey: .spacing))
        case .flexibleSpacer:
            self = .flexibleSpacer
        case .stack:
            self = .stack(
                axis: try container.decode(ExtensionAxis.self, forKey: .axis),
                spacing: try container.decode(ExtensionSpacing.self, forKey: .spacing),
                children: try container.decode([Self].self, forKey: .children)
            )
        case .overlay:
            self = .overlay(
                base: try container.decode(Self.self, forKey: .base),
                overlay: try container.decode(Self.self, forKey: .overlay)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .content(let content):
            try container.encode(Kind.content, forKey: .type)
            try container.encode(content, forKey: .content)
        case .collection(let collection):
            try container.encode(Kind.collection, forKey: .type)
            try container.encode(collection, forKey: .collection)
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
        case .overlay(let base, let overlay):
            try container.encode(Kind.overlay, forKey: .type)
            try container.encode(base, forKey: .base)
            try container.encode(overlay, forKey: .overlay)
        }
    }
}

/// One host-rendered choice which will feed a navigator transform.
///
/// Navigator options intentionally reuse the Settings control vocabulary, while accepting only
/// toggles and enumerated choices. Threading owns persistence and presentation; the extension
/// receives neither a control nor mutable preference storage.
public struct ExtensionWorkspaceNavigatorOption: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let control: ExtensionSettingControl

    public init(id: String, title: String, control: ExtensionSettingControl) {
        self.id = id
        self.title = title
        self.control = control
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues = ExtensionSettingValidator.fieldIssues(
            ExtensionSettingField(id: id, title: title, control: control),
            path: path
        )
        switch control {
        case .toggle, .choice:
            break
        case .text, .integer:
            issues.append(.init(
                path: "\(path).control.type",
                message: "navigator options support only toggle and choice controls"
            ))
        }
        return issues
    }

    fileprivate var menuEntryCost: Int {
        switch control {
        case .toggle:
            return 1
        case .choice(_, let options):
            return 1 + options.count
        case .text, .integer:
            // Invalid controls still spend one conservative parent row in the aggregate check.
            return 1
        }
    }
}

/// A bounded host-owned mutation which a pipeline row may ask Threading to perform.
///
/// The extension declares and places this semantic intent but never receives the gesture, a
/// session identifier, or a mutation result. Threading revalidates the source session at the
/// press edge and owns persistence, provider coordination, receipts, failure presentation, and
/// Undo. Keeping the initial vocabulary deliberately narrow avoids turning navigator layout into
/// a general session-write capability.
public enum ExtensionWorkspaceNavigatorIntent: String, Codable, Equatable, Hashable, Sendable {
    case pin
    case unpin
    case archive
}

/// One user-selectable replacement for the interior of the leading workspace navigator.
///
/// Threading still owns resizing, collapse, focus routing, entity validation, and the always
/// available command which restores the native navigator.
public struct ExtensionWorkspaceNavigator: Codable, Equatable, Sendable {
    public static let minimumPreferredWidth = 180.0
    public static let maximumPreferredWidth = 640.0
    public static let maximumStructureDepth = 24
    public static let maximumStructureNodes = 128
    public static let maximumCollections = 8
    public static let maximumItems = 1_000
    public static let maximumItemPatches = 64
    public static let maximumOptions = 16
    public static let maximumIntents = 8
    /// Includes the host-owned separator and permanent route back to the Native navigator.
    public static let maximumOptionMenuEntries = 32
    public static let reservedHostOptionMenuEntries = 2
    public static let maximumDeclaredOptionMenuEntries =
        maximumOptionMenuEntries - reservedHostOptionMenuEntries

    public static let chromeConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 12,
        maximumNodes: 64,
        maximumRenderedElements: 128,
        maximumTextLength: 2_000,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: ExtensionTextRole.allCases,
        allowedImageRoles: ExtensionImageRole.inline,
        allowedButtonRoles: ExtensionButtonRole.allCases,
        allowedStatusRoles: ExtensionStatusRole.allCases,
        allowsTextInput: true,
        maximumPickerOptions: 100,
        maximumSceneItems: 64,
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true
    )

    public static let itemConstraints = ExtensionComponentNodeConstraints(
        maximumDepth: 8,
        maximumNodes: 32,
        maximumRenderedElements: 48,
        maximumTextLength: 1_000,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: ExtensionTextRole.allCases,
        allowedImageRoles: ExtensionImageRole.inline,
        allowedButtonRoles: [.standard],
        allowedStatusRoles: ExtensionStatusRole.allCases,
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true
    )

    public let id: String
    public let title: String
    public let root: ExtensionWorkspaceNavigatorNode
    /// Static, host-rendered choices scoped to this navigator identity.
    ///
    /// A runtime navigator replacement must repeat this declaration exactly. Only a new process
    /// generation may change the option contract.
    public let options: [ExtensionWorkspaceNavigatorOption]
    /// Host-owned row intents which this navigator's static pipeline is allowed to place.
    ///
    /// The list is part of manifest/runtime parity. A template binding which is not named here,
    /// or a declaration which is not actually placed, is rejected before the navigator appears.
    public let intents: [ExtensionWorkspaceNavigatorIntent]
    /// Optional host-evaluated transform and visible-row template.
    ///
    /// `root` remains the complete v1 document and static fallback. Older hosts ignore this
    /// additive key and render that fallback without executing the pipeline.
    public let pipeline: ExtensionWorkspaceNavigatorPipeline?
    /// Optional action used when the host first presents the navigator or its project model
    /// changes. The response may carry a complete replacement snapshot with the same ID.
    public let loadActionID: String?
    /// Optional action which receives coalesced, host-observed navigator events while selected.
    ///
    /// The extension must also declare `host.events`. A response may carry bounded item-content
    /// patches so one activity edge never requires replacing the complete navigator document.
    public let eventActionID: String?
    /// A 180...640 point hint; the user's persisted split position and live host limits remain
    /// authoritative.
    public let preferredWidth: Double?

    public init(
        id: String,
        title: String,
        root: ExtensionWorkspaceNavigatorNode,
        options: [ExtensionWorkspaceNavigatorOption] = [],
        intents: [ExtensionWorkspaceNavigatorIntent] = [],
        pipeline: ExtensionWorkspaceNavigatorPipeline? = nil,
        loadActionID: String? = nil,
        eventActionID: String? = nil,
        preferredWidth: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.root = root
        self.options = options
        self.intents = intents
        self.pipeline = pipeline
        self.loadActionID = loadActionID
        self.eventActionID = eventActionID
        self.preferredWidth = preferredWidth
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, root, options, intents, pipeline, loadActionID, eventActionID, preferredWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        root = try container.decode(ExtensionWorkspaceNavigatorNode.self, forKey: .root)
        options = if container.contains(.options) {
            try container.decode([ExtensionWorkspaceNavigatorOption].self, forKey: .options)
        } else {
            []
        }
        intents = if container.contains(.intents) {
            try container.decode([ExtensionWorkspaceNavigatorIntent].self, forKey: .intents)
        } else {
            []
        }
        if container.contains(.pipeline) {
            pipeline = try container.decode(
                ExtensionWorkspaceNavigatorPipeline.self,
                forKey: .pipeline
            )
        } else {
            pipeline = nil
        }
        loadActionID = try container.decodeIfPresent(String.self, forKey: .loadActionID)
        eventActionID = try container.decodeIfPresent(String.self, forKey: .eventActionID)
        preferredWidth = try container.decodeIfPresent(Double.self, forKey: .preferredWidth)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(root, forKey: .root)
        try container.encode(options, forKey: .options)
        if !intents.isEmpty {
            try container.encode(intents, forKey: .intents)
        }
        try container.encodeIfPresent(pipeline, forKey: .pipeline)
        try container.encodeIfPresent(loadActionID, forKey: .loadActionID)
        try container.encodeIfPresent(eventActionID, forKey: .eventActionID)
        try container.encodeIfPresent(preferredWidth, forKey: .preferredWidth)
    }

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        if !ExtensionIdentifierRules.isContributionIdentifier(id) {
            issues.append(.init(
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            issues.append(.init(path: "\(path).title", message: "must not be empty"))
        } else if title.count > 120 {
            issues.append(.init(
                path: "\(path).title",
                message: "must contain at most 120 characters"
            ))
        }
        if options.count > Self.maximumOptions {
            issues.append(.init(
                path: "\(path).options",
                message: "must contain at most \(Self.maximumOptions) options"
            ))
        }
        issues.append(contentsOf: ExtensionSettingValidator.duplicateIssues(
            options.map(\.id),
            path: "\(path).options"
        ))
        for (index, option) in options.enumerated() {
            issues.append(contentsOf: option.validationIssues(
                path: "\(path).options[\(index)]"
            ))
        }
        if intents.count > Self.maximumIntents {
            issues.append(.init(
                path: "\(path).intents",
                message: "must contain at most \(Self.maximumIntents) intents"
            ))
        }
        var seenIntents = Set<ExtensionWorkspaceNavigatorIntent>()
        for (index, intent) in intents.enumerated() where !seenIntents.insert(intent).inserted {
            issues.append(.init(
                path: "\(path).intents[\(index)]",
                message: "duplicates a declared navigator intent"
            ))
        }
        // A dynamic fact control owns one bounded parent submenu. Its live catalogue children are
        // capped separately by the host, but the parent still consumes one of this navigator's
        // declared option-menu rows.
        let optionEntryCost = options.reduce(0) { $0 + $1.menuEntryCost }
            + (pipeline?.registeredFactOptions.count ?? 0)
        if optionEntryCost > Self.maximumDeclaredOptionMenuEntries {
            issues.append(.init(
                path: "\(path).options",
                message: """
                static and registered fact controls must require at most \
                \(Self.maximumDeclaredOptionMenuEntries) menu entries; \
                requires \(optionEntryCost)
                """
            ))
        }
        if let loadActionID,
           !ExtensionIdentifierRules.isContributionIdentifier(loadActionID) {
            issues.append(.init(
                path: "\(path).loadActionID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if let eventActionID,
           !ExtensionIdentifierRules.isContributionIdentifier(eventActionID) {
            issues.append(.init(
                path: "\(path).eventActionID",
                message: ExtensionIdentifierRules.contributionMessage
            ))
        }
        if let pipeline {
            issues.append(contentsOf: pipeline.validationIssues(
                path: "\(path).pipeline",
                options: options,
                intents: intents
            ))
            if loadActionID != nil {
                issues.append(.init(
                    path: "\(path).loadActionID",
                    message: "is not available with a host-evaluated pipeline"
                ))
            }
            if eventActionID != nil {
                issues.append(.init(
                    path: "\(path).eventActionID",
                    message: "is not available with a host-evaluated pipeline"
                ))
            }
        } else if !intents.isEmpty {
            issues.append(.init(
                path: "\(path).intents",
                message: "are available only with a host-evaluated pipeline"
            ))
        }
        if let preferredWidth,
           !preferredWidth.isFinite
            || preferredWidth < Self.minimumPreferredWidth
            || preferredWidth > Self.maximumPreferredWidth {
            issues.append(.init(
                path: "\(path).preferredWidth",
                message: "must be finite and between 180 and 640"
            ))
        }

        var structureCount = 0
        var collectionCount = 0
        var itemCount = 0
        var collectionIDs = Set<String>()
        var chromeNodes: [(path: String, node: ExtensionNode)] = []
        validateNode(
            root,
            path: "\(path).root",
            depth: 0,
            structureCount: &structureCount,
            collectionCount: &collectionCount,
            itemCount: &itemCount,
            collectionIDs: &collectionIDs,
            chromeNodes: &chromeNodes,
            issues: &issues
        )
        Self.chromeConstraints.validateRoots(
            chromeNodes,
            issues: &issues
        )
        return issues
    }

    private func validateNode(
        _ node: ExtensionWorkspaceNavigatorNode,
        path: String,
        depth: Int,
        structureCount: inout Int,
        collectionCount: inout Int,
        itemCount: inout Int,
        collectionIDs: inout Set<String>,
        chromeNodes: inout [(path: String, node: ExtensionNode)],
        issues: inout [ExtensionValidationIssue]
    ) {
        guard depth <= Self.maximumStructureDepth else {
            issues.append(.init(
                path: path,
                message: "exceeds maximum depth \(Self.maximumStructureDepth)"
            ))
            return
        }
        structureCount += 1
        guard structureCount <= Self.maximumStructureNodes else {
            if structureCount == Self.maximumStructureNodes + 1 {
                issues.append(.init(
                    path: path,
                    message: "exceeds maximum node count \(Self.maximumStructureNodes)"
                ))
            }
            return
        }

        switch node {
        case .content(let content):
            chromeNodes.append(("\(path).content", content))
        case .collection(let collection):
            collectionCount += 1
            if collectionCount > Self.maximumCollections {
                issues.append(.init(
                    path: path,
                    message: "exceeds maximum collection count \(Self.maximumCollections)"
                ))
            }
            if !collectionIDs.insert(collection.id).inserted {
                issues.append(.init(
                    path: "\(path).collection.id",
                    message: "must be unique across the navigator"
                ))
            }
            itemCount += collection.items.count
            if itemCount > Self.maximumItems {
                issues.append(.init(
                    path: "\(path).collection.items",
                    message: "exceeds aggregate item count \(Self.maximumItems)"
                ))
            }
            validateCollection(collection, path: "\(path).collection", issues: &issues)
        case .divider, .spacer, .flexibleSpacer:
            break
        case .stack(_, _, let children):
            if children.isEmpty {
                issues.append(.init(path: "\(path).children", message: "must not be empty"))
            }
            for (index, child) in children.enumerated() {
                validateNode(
                    child,
                    path: "\(path).children[\(index)]",
                    depth: depth + 1,
                    structureCount: &structureCount,
                    collectionCount: &collectionCount,
                    itemCount: &itemCount,
                    collectionIDs: &collectionIDs,
                    chromeNodes: &chromeNodes,
                    issues: &issues
                )
            }
        case .overlay(let base, let overlay):
            validateNode(
                base,
                path: "\(path).base",
                depth: depth + 1,
                structureCount: &structureCount,
                collectionCount: &collectionCount,
                itemCount: &itemCount,
                collectionIDs: &collectionIDs,
                chromeNodes: &chromeNodes,
                issues: &issues
            )
            validateNode(
                overlay,
                path: "\(path).overlay",
                depth: depth + 1,
                structureCount: &structureCount,
                collectionCount: &collectionCount,
                itemCount: &itemCount,
                collectionIDs: &collectionIDs,
                chromeNodes: &chromeNodes,
                issues: &issues
            )
        }
    }

    private func validateCollection(
        _ collection: ExtensionWorkspaceNavigatorCollection,
        path: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        validateStableID(collection.id, path: "\(path).id", issues: &issues)
        if case .grid(let columns) = collection.layout,
           columns < 1 || columns > 8 {
            issues.append(.init(
                path: "\(path).layout.columns",
                message: "must be between 1 and 8"
            ))
        }

        var sectionIDs = Set<String>()
        for (index, section) in collection.sections.enumerated() {
            let sectionPath = "\(path).sections[\(index)]"
            validateStableID(section.id, path: "\(sectionPath).id", issues: &issues)
            if !sectionIDs.insert(section.id).inserted {
                issues.append(.init(path: "\(sectionPath).id", message: "must be unique"))
            }
            if let header = section.header {
                appendValidation(
                    constraints: Self.itemConstraints,
                    node: header,
                    path: "\(sectionPath).header",
                    issues: &issues
                )
            }
        }

        if collection.items.isEmpty {
            issues.append(.init(path: "\(path).items", message: "must not be empty"))
        }
        var itemIndices: [String: Int] = [:]
        for (index, item) in collection.items.enumerated() {
            let itemPath = "\(path).items[\(index)]"
            validateStableID(item.id, path: "\(itemPath).id", issues: &issues)
            if itemIndices.updateValue(index, forKey: item.id) != nil {
                issues.append(.init(path: "\(itemPath).id", message: "must be unique"))
            }
            if let sectionID = item.sectionID, !sectionIDs.contains(sectionID) {
                issues.append(.init(
                    path: "\(itemPath).sectionID",
                    message: "does not name a declared section"
                ))
            }
            appendValidation(
                constraints: Self.itemConstraints,
                node: item.content,
                path: "\(itemPath).content",
                issues: &issues
            )
            if let accessibilityLabel = item.accessibilityLabel {
                let trimmed = accessibilityLabel.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if trimmed.isEmpty {
                    issues.append(.init(
                        path: "\(itemPath).accessibilityLabel",
                        message: "must not be empty when present"
                    ))
                } else if accessibilityLabel.count > 256 {
                    issues.append(.init(
                        path: "\(itemPath).accessibilityLabel",
                        message: "must contain at most 256 characters"
                    ))
                }
            } else if case .grid = collection.layout, item.activation != nil {
                issues.append(.init(
                    path: "\(itemPath).accessibilityLabel",
                    message: "is required for an actionable grid item"
                ))
            }
            if let activation = item.activation {
                issues.append(contentsOf: activation.validationIssues(
                    path: "\(itemPath).activation"
                ))
            }
        }

        let selectedCount = collection.items.lazy.filter(\.isSelected).count
        if collection.selectionMode == .none, selectedCount > 0 {
            issues.append(.init(
                path: "\(path).items",
                message: "may not select items when selectionMode is none"
            ))
        } else if collection.selectionMode == .single, selectedCount > 1 {
            issues.append(.init(
                path: "\(path).items",
                message: "may contain at most one selected item"
            ))
        }

        for (index, item) in collection.items.enumerated() {
            let itemPath = "\(path).items[\(index)]"
            if collection.layout != .outline {
                if item.parentID != nil {
                    issues.append(.init(
                        path: "\(itemPath).parentID",
                        message: "is available only for outline collections"
                    ))
                }
                if item.isExpanded {
                    issues.append(.init(
                        path: "\(itemPath).isExpanded",
                        message: "is available only for outline collections"
                    ))
                }
                continue
            }
            guard let parentID = item.parentID else { continue }
            guard let parentIndex = itemIndices[parentID] else {
                issues.append(.init(
                    path: "\(itemPath).parentID",
                    message: "does not name an item in this collection"
                ))
                continue
            }
            if parentID == item.id {
                issues.append(.init(
                    path: "\(itemPath).parentID",
                    message: "must not refer to the item itself"
                ))
            }
            if collection.items[parentIndex].sectionID != item.sectionID {
                issues.append(.init(
                    path: "\(itemPath).parentID",
                    message: "must name an item in the same section"
                ))
            }
            if hasParentCycle(
                startingAt: item.id,
                items: collection.items,
                itemIndices: itemIndices
            ) {
                issues.append(.init(
                    path: "\(itemPath).parentID",
                    message: "must not form a parent cycle"
                ))
            }
        }
    }

    private func hasParentCycle(
        startingAt id: String,
        items: [ExtensionWorkspaceNavigatorItem],
        itemIndices: [String: Int]
    ) -> Bool {
        var visited = Set<String>()
        var current: String? = id
        while let candidate = current {
            guard visited.insert(candidate).inserted else { return true }
            guard let index = itemIndices[candidate] else { return false }
            current = items[index].parentID
        }
        return false
    }

    private func appendValidation(
        constraints: ExtensionComponentNodeConstraints,
        node: ExtensionNode,
        path: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        do {
            try constraints.validate(node, path: path)
        } catch let error as ExtensionValidationError {
            issues.append(contentsOf: error.issues)
        } catch {
            issues.append(.init(path: path, message: error.localizedDescription))
        }
    }

    private func validateStableID(
        _ id: String,
        path: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: path, message: "must not be empty"))
        } else if id.count > 256 {
            issues.append(.init(path: path, message: "must contain at most 256 characters"))
        }
    }
}
