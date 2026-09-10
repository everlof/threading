import Foundation

/// The stable, documented name of a host component that extensions may customize.
public struct ExtensionComponentID: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension ExtensionComponentID {
    /// The complete content of Threading's main application window.
    static let applicationMainWindow: Self = "application.main-window"

    /// The prompt used to start a new session from a selected project.
    static let composerSessionStart: Self = "composer.session-start"

    /// The prompt used to send another turn in a native conversation.
    static let composerConversationReply: Self = "composer.conversation-reply"

    /// One user-authored message in a native conversation.
    static let conversationUserMessage: Self = "conversation.user-message"

    /// One finished assistant message in a native conversation.
    static let conversationAssistantMessage: Self = "conversation.assistant-message"

    /// One collapsible tool invocation and its eventual result.
    static let conversationToolCall: Self = "conversation.tool-call"

    /// One inline tool-permission request and its host-owned decision controls.
    static let conversationPermissionCard: Self = "conversation.permission-card"

    /// The shared chrome row above one session's display-pane content.
    static let displayPaneHeader: Self = "display.pane-header"

    /// One native tab header in a session's display pane.
    static let displayTabHeader: Self = "display.tab-header"

    /// A project row in the main source-list sidebar.
    static let sidebarProjectRow: Self = "sidebar.project-row"

    /// The hover card presented from a project row.
    static let sidebarProjectHoverCard: Self = "sidebar.project-hover-card"

    /// A session row in the main source-list sidebar.
    static let sidebarSessionRow: Self = "sidebar.session-row"

    /// The hover card presented from a session row.
    static let sidebarSessionHoverCard: Self = "sidebar.session-hover-card"

    /// The provider/account composition at the leading edge of a sidebar session row.
    static let sidebarSessionIdentity: Self = "sidebar.session-identity"

    /// The usage detail popover presented from the toolbar's active-account item.
    static let toolbarAccountUsagePopover: Self = "toolbar.account-usage-popover"

    /// The ground beneath the project sidebar's brand row, list and footer.
    ///
    /// A hook here draws *under* the sidebar's content, never over it: the contract requires an
    /// overlay whose top is `.proceed`, admits only a fill-the-column image and a host-run
    /// fragment surface, and the host hit-tests straight through everything it composes. The
    /// theme's own sidebar dressing stays beneath this; an opaque navigator well a theme states
    /// stays above it.
    static let sidebarBackdrop: Self = "sidebar.backdrop"

    /// The floating corner card over the selected session's content pane.
    ///
    /// Deliberately not named after any one content kind: today the card carries the
    /// checkout's branch and change counters, but it is the pane's corner surface, not a git
    /// surface. The slot ID names the corner — `top-trailing` is the only corner with a card
    /// today; `top-leading` is reserved for a future leading card and arrives as an additive
    /// slot rather than a rename.
    static let sessionCornerCard: Self = "session.corner-card"
}

/// A semantic property exposed by a component contract.
public struct ExtensionComponentPropertyID: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let title: Self = "title"
    public static let identityImage: Self = "identity-image"
    public static let toolTip: Self = "tool-tip"
}

/// A named insertion point exposed by a component contract.
public struct ExtensionComponentSlotID: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The kind of host snapshot supplied while an extension calculates a patch.
///
/// This is open-ended rather than an enum so a newer host can publish a context kind without
/// making an older SDK unable to decode the component catalogue.
public struct ExtensionComponentContextKind: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let application: Self = "application"
    public static let projectPresentation: Self = "project-presentation"
    public static let sessionPresentation: Self = "session-presentation"
    public static let accountPresentation: Self = "account-presentation"
    public static let conversationRow: Self = "conversation-row"
}

/// An image request which Threading resolves and renders.
///
/// Extensions never supply `NSImage`, paths outside their package, or a view. Host assets are
/// opaque identifiers from a context snapshot; extension resources remain package-relative.
public enum ExtensionImageReference: Codable, Equatable, Hashable, Sendable {
    case hostAsset(String)
    case extensionResource(String)
    case systemSymbol(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case identifier
        case path
        case name
    }

    private enum Kind: String, Codable {
        case hostAsset
        case extensionResource
        case systemSymbol
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hostAsset:
            self = .hostAsset(try container.decode(String.self, forKey: .identifier))
        case .extensionResource:
            self = .extensionResource(try container.decode(String.self, forKey: .path))
        case .systemSymbol:
            self = .systemSymbol(try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostAsset(let identifier):
            try container.encode(Kind.hostAsset, forKey: .type)
            try container.encode(identifier, forKey: .identifier)
        case .extensionResource(let path):
            try container.encode(Kind.extensionResource, forKey: .type)
            try container.encode(path, forKey: .path)
        case .systemSymbol(let name):
            try container.encode(Kind.systemSymbol, forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

/// A host-rendered identity recipe. The full identity pipeline is intentionally a value so it
/// can later be shared by provider icons, account icons, and complete session identities.
public indirect enum ExtensionIdentityComposition: Codable, Equatable, Hashable, Sendable {
    case image(ExtensionImageReference)
    case overlay(
        base: ExtensionIdentityComposition,
        badge: ExtensionIdentityComposition,
        alignment: ExtensionIdentityBadgeAlignment
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case image
        case base
        case badge
        case alignment
    }

    private enum Kind: String, Codable {
        case image
        case overlay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .image:
            self = .image(
                try container.decode(ExtensionImageReference.self, forKey: .image)
            )
        case .overlay:
            self = .overlay(
                base: try container.decode(Self.self, forKey: .base),
                badge: try container.decode(Self.self, forKey: .badge),
                alignment: try container.decode(
                    ExtensionIdentityBadgeAlignment.self,
                    forKey: .alignment
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let image):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(image, forKey: .image)
        case .overlay(let base, let badge, let alignment):
            try container.encode(Kind.overlay, forKey: .type)
            try container.encode(base, forKey: .base)
            try container.encode(badge, forKey: .badge)
            try container.encode(alignment, forKey: .alignment)
        }
    }
}

public enum ExtensionIdentityBadgeAlignment: String, Codable, Equatable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

/// The vocabulary a disclosure's revealed level may use.
///
/// A box, and `indirect` is the reason it exists: a constraint set that describes a constraint
/// set is a recursive value, and Swift needs one boxed edge to give it a size. It encodes as the
/// nested vocabulary itself, so the published catalogue reads as one constraint set inside
/// another rather than as a wrapper nobody asked about.
public indirect enum ExtensionComponentDetailConstraints: Equatable, Sendable {
    case vocabulary(ExtensionComponentNodeConstraints)

    public var constraints: ExtensionComponentNodeConstraints {
        switch self {
        case .vocabulary(let constraints): return constraints
        }
    }
}

extension ExtensionComponentDetailConstraints: Codable {
    public init(from decoder: Decoder) throws {
        self = .vocabulary(try ExtensionComponentNodeConstraints(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try constraints.encode(to: encoder)
    }
}

/// Machine-readable limits for semantic content rendered inside a compact host component.
///
/// The SDK can apply the same validation as Threading before publishing a patch. Empty role/axis
/// arrays mean that node kind is unavailable; booleans cover the kinds which have no role.
/// Where a hook's `.proceed` may stand in relation to the extension's own content.
///
/// `anywhere` is the ordinary around-hook: the host's content may be wrapped, preceded,
/// followed or overlaid. `overlayTop` is the *backdrop* shape — the root must be an `overlay`
/// whose top is exactly `.proceed`, so everything the extension draws lands beneath the host's
/// content and nothing can be composited over the rows a person reads. It is the window hook's
/// overlay turned over, stated as a rule rather than left to the author's memory.
public enum ExtensionProceedPlacement: String, Codable, Equatable, Sendable {
    case anywhere
    case overlayTop
}

public struct ExtensionComponentNodeConstraints: Codable, Equatable, Sendable {
    public let maximumDepth: Int
    public let maximumNodes: Int
    /// Aggregate host-rendered elements across the tree.
    ///
    /// Nodes, picker options, and scene marks all consume this budget. Keeping it separate from
    /// `maximumNodes` prevents a shallow tree from hiding an unbounded amount of eager renderer
    /// work inside value-bearing nodes.
    public let maximumRenderedElements: Int
    public let maximumTextLength: Int
    public let requiredRootAxis: ExtensionAxis?
    public let allowedStackAxes: [ExtensionAxis]
    public let allowedTextRoles: [ExtensionTextRole]
    public let allowedImageRoles: [ExtensionImageRole]
    public let allowedButtonRoles: [ExtensionButtonRole]
    public let allowedStatusRoles: [ExtensionStatusRole]
    /// Whether this surface accepts editable text fields.
    public let allowsTextInput: Bool
    /// Zero disallows pickers; a positive value is the option budget for each picker.
    public let maximumPickerOptions: Int
    /// Zero disallows scenes; a positive value is the mark budget for each scene.
    public let maximumSceneItems: Int
    public let allowsDivider: Bool
    public let allowsFixedSpacer: Bool
    public let allowsFlexibleSpacer: Bool
    public let allowsProceed: Bool
    public let requiresProceed: Bool
    public let allowsOverlay: Bool
    /// Whether this surface accepts a host-played media document.
    ///
    /// Defaults to **false**, deliberately: a media node is the one thing in the vocabulary whose
    /// pixels move on their own and whose canvas has a clock, so no existing contract gains a
    /// player by an SDK release. A surface opts in, and the manifest capability
    /// `ui.media-documents` gates it a second time.
    public let allowsMedia: Bool
    public let allowedCustomSurfaceKinds: [ExtensionCustomSurfaceKind]
    /// Where `.proceed` must stand. Defaults to `anywhere`, which is every contract that
    /// existed before a surface drew *under* its host content.
    public let proceedPlacement: ExtensionProceedPlacement
    /// A cadence ceiling for custom surfaces on this surface, or nil for the SDK's own 60.
    ///
    /// A surface that lives as long as the window — a backdrop under a list — is not a
    /// transient effect, and a full-rate shader behind a column of names is a battery cost the
    /// reader never asked for. The contract states the ceiling, the SDK refuses a patch above
    /// it, and the host clamps to the same number when it builds the view.
    public let maximumCustomSurfaceFramesPerSecond: Int?

    /// What a summary's second level may say here, or nil where summaries have no second level.
    ///
    /// One switch rather than a Boolean beside a vocabulary, which could disagree with each
    /// other. The revealed level is described in full rather than inherited: Threading shows it
    /// on a surface of its own, so a row that must stay a compact reading without controls can
    /// still reveal a list that scrolls, groups and acts.
    public let disclosureDetail: ExtensionComponentDetailConstraints?

    public init(
        maximumDepth: Int,
        maximumNodes: Int,
        maximumRenderedElements: Int? = nil,
        maximumTextLength: Int,
        requiredRootAxis: ExtensionAxis? = nil,
        allowedStackAxes: [ExtensionAxis] = [],
        allowedTextRoles: [ExtensionTextRole] = [],
        allowedImageRoles: [ExtensionImageRole] = [],
        allowedButtonRoles: [ExtensionButtonRole] = [],
        allowedStatusRoles: [ExtensionStatusRole] = [],
        allowsTextInput: Bool = false,
        maximumPickerOptions: Int = 0,
        maximumSceneItems: Int = 0,
        allowsDivider: Bool = false,
        allowsFixedSpacer: Bool = false,
        allowsFlexibleSpacer: Bool = false,
        allowsProceed: Bool = false,
        requiresProceed: Bool = false,
        allowsOverlay: Bool = false,
        allowsMedia: Bool = false,
        allowedCustomSurfaceKinds: [ExtensionCustomSurfaceKind] = [],
        proceedPlacement: ExtensionProceedPlacement = .anywhere,
        maximumCustomSurfaceFramesPerSecond: Int? = nil,
        disclosureDetail: ExtensionComponentDetailConstraints? = nil
    ) {
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumRenderedElements = maximumRenderedElements ?? maximumNodes
        self.maximumTextLength = maximumTextLength
        self.requiredRootAxis = requiredRootAxis
        self.allowedStackAxes = allowedStackAxes
        self.allowedTextRoles = allowedTextRoles
        self.allowedImageRoles = allowedImageRoles
        self.allowedButtonRoles = allowedButtonRoles
        self.allowedStatusRoles = allowedStatusRoles
        self.allowsTextInput = allowsTextInput
        self.maximumPickerOptions = maximumPickerOptions
        self.maximumSceneItems = maximumSceneItems
        self.allowsDivider = allowsDivider
        self.allowsFixedSpacer = allowsFixedSpacer
        self.allowsFlexibleSpacer = allowsFlexibleSpacer
        self.allowsProceed = allowsProceed
        self.requiresProceed = requiresProceed
        self.allowsOverlay = allowsOverlay
        self.allowsMedia = allowsMedia
        self.allowedCustomSurfaceKinds = allowedCustomSurfaceKinds
        self.proceedPlacement = proceedPlacement
        self.maximumCustomSurfaceFramesPerSecond = maximumCustomSurfaceFramesPerSecond
        self.disclosureDetail = disclosureDetail
    }

    private enum CodingKeys: String, CodingKey {
        case maximumDepth, maximumNodes, maximumRenderedElements, maximumTextLength
        case requiredRootAxis
        case allowedStackAxes, allowedTextRoles, allowedImageRoles, allowedButtonRoles
        case allowedStatusRoles, allowsTextInput, maximumPickerOptions, maximumSceneItems
        case allowsDivider, allowsFixedSpacer, allowsFlexibleSpacer
        case allowsProceed, requiresProceed, allowsOverlay, allowsMedia
        case allowedCustomSurfaceKinds
        case proceedPlacement, maximumCustomSurfaceFramesPerSecond
        case disclosureDetail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumDepth = try container.decode(Int.self, forKey: .maximumDepth)
        maximumNodes = try container.decode(Int.self, forKey: .maximumNodes)
        maximumRenderedElements = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumRenderedElements
        ) ?? maximumNodes
        maximumTextLength = try container.decode(Int.self, forKey: .maximumTextLength)
        requiredRootAxis = try container.decodeIfPresent(
            ExtensionAxis.self,
            forKey: .requiredRootAxis
        )
        allowedStackAxes = try container.decode(
            [ExtensionAxis].self,
            forKey: .allowedStackAxes
        )
        allowedTextRoles = try container.decode(
            [ExtensionTextRole].self,
            forKey: .allowedTextRoles
        )
        allowedImageRoles = try container.decode(
            [ExtensionImageRole].self,
            forKey: .allowedImageRoles
        )
        allowedButtonRoles = try container.decode(
            [ExtensionButtonRole].self,
            forKey: .allowedButtonRoles
        )
        allowedStatusRoles = try container.decode(
            [ExtensionStatusRole].self,
            forKey: .allowedStatusRoles
        )
        allowsTextInput = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsTextInput
        ) ?? false
        maximumPickerOptions = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumPickerOptions
        ) ?? 0
        maximumSceneItems = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumSceneItems
        ) ?? 0
        allowsDivider = try container.decode(Bool.self, forKey: .allowsDivider)
        allowsFixedSpacer = try container.decode(Bool.self, forKey: .allowsFixedSpacer)
        allowsFlexibleSpacer = try container.decode(Bool.self, forKey: .allowsFlexibleSpacer)
        allowsProceed = try container.decodeIfPresent(Bool.self, forKey: .allowsProceed) ?? false
        requiresProceed = try container.decodeIfPresent(Bool.self, forKey: .requiresProceed) ?? false
        allowsOverlay = try container.decodeIfPresent(Bool.self, forKey: .allowsOverlay) ?? false
        allowsMedia = try container.decodeIfPresent(Bool.self, forKey: .allowsMedia) ?? false
        allowedCustomSurfaceKinds = try container.decodeIfPresent(
            [ExtensionCustomSurfaceKind].self,
            forKey: .allowedCustomSurfaceKinds
        ) ?? []
        proceedPlacement = try container.decodeIfPresent(
            ExtensionProceedPlacement.self,
            forKey: .proceedPlacement
        ) ?? .anywhere
        maximumCustomSurfaceFramesPerSecond = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumCustomSurfaceFramesPerSecond
        )
        disclosureDetail = try container.decodeIfPresent(
            ExtensionComponentDetailConstraints.self,
            forKey: .disclosureDetail
        )
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if maximumDepth < 0 {
            issues.append(.init(path: "maximumDepth", message: "must not be negative"))
        }
        if maximumNodes < 1 {
            issues.append(.init(path: "maximumNodes", message: "must be at least 1"))
        }
        if maximumRenderedElements < maximumNodes {
            issues.append(.init(
                path: "maximumRenderedElements",
                message: "must be at least maximumNodes"
            ))
        }
        if maximumTextLength < 1 {
            issues.append(.init(path: "maximumTextLength", message: "must be at least 1"))
        }
        if maximumPickerOptions < 0 {
            issues.append(.init(path: "maximumPickerOptions", message: "must not be negative"))
        }
        if maximumSceneItems < 0 {
            issues.append(.init(path: "maximumSceneItems", message: "must not be negative"))
        }
        if let requiredRootAxis,
           !allowedStackAxes.contains(requiredRootAxis) {
            issues.append(.init(
                path: "requiredRootAxis",
                message: "must also appear in allowedStackAxes"
            ))
        }
        if requiresProceed && !allowsProceed {
            issues.append(.init(
                path: "requiresProceed",
                message: "requires allowsProceed"
            ))
        }
        if proceedPlacement == .overlayTop, !(allowsOverlay && requiresProceed) {
            issues.append(.init(
                path: "proceedPlacement",
                message: "overlayTop requires allowsOverlay and requiresProceed"
            ))
        }
        if let cap = maximumCustomSurfaceFramesPerSecond,
           !(1...ExtensionMetalSurface.maximumFramesPerSecond).contains(cap) {
            issues.append(.init(
                path: "maximumCustomSurfaceFramesPerSecond",
                message: "must be between 1 and \(ExtensionMetalSurface.maximumFramesPerSecond)"
            ))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }

    public func validate(
        _ node: ExtensionNode,
        path: String = "node"
    ) throws {
        try validate()
        var issues: [ExtensionValidationIssue] = []
        var count = 0
        var renderedElementCount = 0
        var proceedCount = 0
        validateNode(
            node,
            path: path,
            depth: 0,
            count: &count,
            renderedElementCount: &renderedElementCount,
            proceedCount: &proceedCount,
            issues: &issues
        )
        if proceedCount > 1 {
            issues.append(.init(path: path, message: "may contain at most one proceed node"))
        } else if requiresProceed && proceedCount != 1 {
            issues.append(.init(path: path, message: "must contain exactly one proceed node"))
        }
        if proceedPlacement == .overlayTop {
            // The one shape that keeps the extension's content beneath the host's: the root
            // is an overlay, and its top is the proceed node itself — not a stack holding it,
            // which would let a sibling share the top layer with the rows.
            var proceedIsOnTop = false
            if case .overlay(_, .proceed) = node { proceedIsOnTop = true }
            if !proceedIsOnTop {
                issues.append(.init(
                    path: path,
                    message: "root must be an overlay whose overlay is the proceed node, "
                        + "so extension content stays beneath the host content"
                ))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }

    /// Several roots against one budget — what a disclosure's revealed level is.
    ///
    /// `validate(_:)` starts a fresh count per call, which is right for a slot's own root and
    /// wrong for a list: validated one at a time, ten rows would each be allowed the whole
    /// node budget.
    func validateSiblings(
        _ nodes: [ExtensionNode],
        path: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        validateRoots(
            nodes.enumerated().map { ("\(path)[\($0.offset)]", $0.element) },
            aggregatePath: path,
            issues: &issues
        )
    }

    /// Several independently located roots against one eager-render budget.
    ///
    /// This is used by composite host surfaces whose semantic content is interleaved with
    /// virtualized or host-owned structure. Keeping the real paths makes validation failures
    /// actionable without granting every fragment a fresh budget.
    func validateRoots(
        _ roots: [(path: String, node: ExtensionNode)],
        aggregatePath: String? = nil,
        issues: inout [ExtensionValidationIssue]
    ) {
        var count = 0
        var renderedElementCount = 0
        var proceedCount = 0
        for root in roots {
            validateNode(
                root.node,
                path: root.path,
                depth: 0,
                count: &count,
                renderedElementCount: &renderedElementCount,
                proceedCount: &proceedCount,
                issues: &issues
            )
        }
        if proceedCount > 0 {
            issues.append(.init(
                path: aggregatePath ?? roots.first?.path ?? "content",
                message: "may not contain a proceed node"
            ))
        }
    }

    private func validateNode(
        _ node: ExtensionNode,
        path: String,
        depth: Int,
        count: inout Int,
        renderedElementCount: inout Int,
        proceedCount: inout Int,
        issues: inout [ExtensionValidationIssue]
    ) {
        guard depth <= maximumDepth else {
            issues.append(.init(
                path: path,
                message: "exceeds maximum depth \(maximumDepth)"
            ))
            return
        }

        count += 1
        renderedElementCount += 1
        guard count <= maximumNodes else {
            if count == maximumNodes + 1 {
                issues.append(.init(
                    path: path,
                    message: "exceeds maximum node count \(maximumNodes)"
                ))
            }
            return
        }
        if renderedElementCount > maximumRenderedElements,
           renderedElementCount == maximumRenderedElements + 1 {
            issues.append(.init(
                path: path,
                message: "exceeds aggregate rendered-element count \(maximumRenderedElements)"
            ))
        }

        switch node {
        case .text(let text, let role):
            require(
                allowedTextRoles.contains(role),
                path: path,
                message: "text role '\(role.rawValue)' is not allowed",
                issues: &issues
            )
            validateText(text, path: "\(path).text", issues: &issues)

        case .image(_, let role, _):
            require(
                allowedImageRoles.contains(role),
                path: path,
                message: "image role '\(role.rawValue)' is not allowed",
                issues: &issues
            )

        case .button(let id, let title, let role, _):
            require(
                allowedButtonRoles.contains(role),
                path: path,
                message: "button role '\(role.rawValue)' is not allowed",
                issues: &issues
            )
            require(
                ExtensionIdentifierRules.isContributionIdentifier(id),
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage,
                issues: &issues
            )
            validateText(title, path: "\(path).title", issues: &issues)

        case .textInput(let id, let value, let placeholder, let accessibilityLabel, _, _):
            require(
                allowsTextInput,
                path: path,
                message: "text input is not allowed",
                issues: &issues
            )
            require(
                ExtensionIdentifierRules.isContributionIdentifier(id),
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage,
                issues: &issues
            )
            require(
                value.count <= maximumTextLength,
                path: "\(path).value",
                message: "exceeds maximum length \(maximumTextLength)",
                issues: &issues
            )
            if let placeholder {
                validateText(
                    placeholder,
                    path: "\(path).placeholder",
                    issues: &issues
                )
            }
            validateText(
                accessibilityLabel,
                path: "\(path).accessibilityLabel",
                issues: &issues
            )

        case .picker(let id, let selection, let options, let accessibilityLabel, _):
            require(
                maximumPickerOptions > 0,
                path: path,
                message: "picker is not allowed",
                issues: &issues
            )
            require(
                ExtensionIdentifierRules.isContributionIdentifier(id),
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage,
                issues: &issues
            )
            require(
                !options.isEmpty,
                path: "\(path).options",
                message: "must not be empty",
                issues: &issues
            )
            require(
                options.count <= maximumPickerOptions,
                path: "\(path).options",
                message: "exceeds maximum option count \(maximumPickerOptions)",
                issues: &issues
            )
            let renderedElementCountBeforeOptions = renderedElementCount
            renderedElementCount += options.count
            if renderedElementCountBeforeOptions <= maximumRenderedElements,
               renderedElementCount > maximumRenderedElements {
                issues.append(.init(
                    path: "\(path).options",
                    message: "exceeds aggregate rendered-element count \(maximumRenderedElements)"
                ))
            }
            var optionValues = Set<String>()
            for (index, option) in options.enumerated() {
                let optionPath = "\(path).options[\(index)]"
                require(
                    !option.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    path: "\(optionPath).value",
                    message: "must not be empty",
                    issues: &issues
                )
                require(
                    option.value.count <= maximumTextLength,
                    path: "\(optionPath).value",
                    message: "exceeds maximum length \(maximumTextLength)",
                    issues: &issues
                )
                require(
                    optionValues.insert(option.value).inserted,
                    path: "\(optionPath).value",
                    message: "must be unique",
                    issues: &issues
                )
                validateText(option.title, path: "\(optionPath).title", issues: &issues)
            }
            if let selection {
                require(
                    options.contains { $0.value == selection },
                    path: "\(path).selection",
                    message: "must match an option value",
                    issues: &issues
                )
            }
            validateText(
                accessibilityLabel,
                path: "\(path).accessibilityLabel",
                issues: &issues
            )

        case .scene(let scene):
            require(
                maximumSceneItems > 0,
                path: path,
                message: "scene is not allowed",
                issues: &issues
            )
            if maximumSceneItems > 0 {
                let renderedElementCountBeforeItems = renderedElementCount
                renderedElementCount += scene.items.count
                if renderedElementCountBeforeItems <= maximumRenderedElements,
                   renderedElementCount > maximumRenderedElements {
                    issues.append(.init(
                        path: "\(path).scene.items",
                        message: """
                        exceeds aggregate rendered-element count \(maximumRenderedElements)
                        """
                    ))
                }
                issues.append(contentsOf: scene.validationIssues(
                    path: "\(path).scene",
                    maximumItems: maximumSceneItems,
                    maximumTextLength: maximumTextLength
                ))
            }

        case .media(let document):
            require(
                allowsMedia,
                path: path,
                message: "media is not allowed",
                issues: &issues
            )
            issues.append(contentsOf: document.validationIssues(
                path: "\(path).document",
                maximumTextLength: maximumTextLength
            ))

        case .status(let text, let role):
            require(
                allowedStatusRoles.contains(role),
                path: path,
                message: "status role '\(role.rawValue)' is not allowed",
                issues: &issues
            )
            validateText(text, path: "\(path).text", issues: &issues)

        case .disclosure(let id, let summary, let detail):
            require(
                disclosureDetail != nil,
                path: path,
                message: "disclosure is not allowed",
                issues: &issues
            )
            require(
                ExtensionIdentifierRules.isContributionIdentifier(id),
                path: "\(path).id",
                message: ExtensionIdentifierRules.contributionMessage,
                issues: &issues
            )
            // The summary is drawn in place, so it spends this vocabulary's own budget.
            validateNode(
                summary,
                path: "\(path).summary",
                depth: depth + 1,
                count: &count,
                renderedElementCount: &renderedElementCount,
                proceedCount: &proceedCount,
                issues: &issues
            )
            require(
                !detail.isEmpty,
                path: "\(path).detail",
                message: "must not be empty",
                issues: &issues
            )
            // The revealed level is drawn somewhere else, so it spends a budget of its own —
            // one shared across its rows, not one per row.
            if let detailConstraints = disclosureDetail?.constraints {
                detailConstraints.validateSiblings(
                    detail,
                    path: "\(path).detail",
                    issues: &issues
                )
            }

        case .proceed:
            proceedCount += 1
            require(
                allowsProceed,
                path: path,
                message: "proceed is not allowed",
                issues: &issues
            )

        case .overlay(let base, let overlay):
            require(
                allowsOverlay,
                path: path,
                message: "overlay is not allowed",
                issues: &issues
            )
            validateNode(
                base,
                path: "\(path).base",
                depth: depth + 1,
                count: &count,
                renderedElementCount: &renderedElementCount,
                proceedCount: &proceedCount,
                issues: &issues
            )
            validateNode(
                overlay,
                path: "\(path).overlay",
                depth: depth + 1,
                count: &count,
                renderedElementCount: &renderedElementCount,
                proceedCount: &proceedCount,
                issues: &issues
            )

        case .customSurface(let surface, let accessibilityLabel):
            require(
                allowedCustomSurfaceKinds.contains(surface.kind),
                path: path,
                message: "custom surface '\(surface.kind.rawValue)' is not allowed",
                issues: &issues
            )
            issues.append(contentsOf: surface.validationIssues(path: path))
            if let cap = maximumCustomSurfaceFramesPerSecond,
               case .metal(let metal) = surface {
                require(
                    metal.preferredFramesPerSecond <= cap,
                    path: "\(path).preferredFramesPerSecond",
                    message: "must be at most \(cap) on this surface",
                    issues: &issues
                )
            }
            if let accessibilityLabel {
                validateText(
                    accessibilityLabel,
                    path: "\(path).accessibilityLabel",
                    issues: &issues
                )
            }

        case .divider:
            require(
                allowsDivider,
                path: path,
                message: "divider is not allowed",
                issues: &issues
            )

        case .spacer(_):
            require(
                allowsFixedSpacer,
                path: path,
                message: "fixed spacer is not allowed",
                issues: &issues
            )

        case .flexibleSpacer:
            require(
                allowsFlexibleSpacer,
                path: path,
                message: "flexible spacer is not allowed",
                issues: &issues
            )

        case .stack(let axis, _, let children):
            require(
                allowedStackAxes.contains(axis),
                path: path,
                message: "stack axis '\(axis.rawValue)' is not allowed",
                issues: &issues
            )
            if depth == 0, let requiredRootAxis {
                require(
                    axis == requiredRootAxis,
                    path: path,
                    message: "root must be a \(requiredRootAxis.rawValue) stack",
                    issues: &issues
                )
            }
            require(
                !children.isEmpty,
                path: "\(path).children",
                message: "must not be empty",
                issues: &issues
            )
            for (index, child) in children.enumerated() {
                validateNode(
                    child,
                    path: "\(path).children[\(index)]",
                    depth: depth + 1,
                    count: &count,
                    renderedElementCount: &renderedElementCount,
                    proceedCount: &proceedCount,
                    issues: &issues
                )
            }
        }
    }

    private func validateText(
        _ text: String,
        path: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        require(
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            path: path,
            message: "must not be empty",
            issues: &issues
        )
        require(
            text.count <= maximumTextLength,
            path: path,
            message: "exceeds maximum length \(maximumTextLength)",
            issues: &issues
        )
    }

    private func require(
        _ condition: Bool,
        path: String,
        message: String,
        issues: inout [ExtensionValidationIssue]
    ) {
        guard !condition else { return }
        issues.append(.init(path: path, message: message))
    }
}

public struct ExtensionComponentSlotContract: Codable, Equatable, Sendable {
    public let id: ExtensionComponentSlotID
    public let maximumInlineItems: Int
    public let contentConstraints: ExtensionComponentNodeConstraints?

    public init(
        id: ExtensionComponentSlotID,
        maximumInlineItems: Int,
        contentConstraints: ExtensionComponentNodeConstraints? = nil
    ) {
        self.id = id
        self.maximumInlineItems = maximumInlineItems
        self.contentConstraints = contentConstraints
    }
}

public enum ExtensionComponentReplacementPolicy: String, Codable, Equatable, Sendable {
    case none
    case contentOnly
}

/// Behavior which remains in Threading's shell even when visual content is replaced.
public struct ExtensionHostOwnedBehavior: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let selection: Self = "selection"
    public static let dragAndDrop: Self = "drag-and-drop"
    public static let rowActions: Self = "row-actions"
    public static let activityState: Self = "activity-state"
    public static let aggregateCount: Self = "aggregate-count"
    public static let accessibilityContainer: Self = "accessibility-container"
    public static let windowChrome: Self = "window-chrome"
    public static let inputRouting: Self = "input-routing"
    public static let hoverTrigger: Self = "hover-trigger"
    public static let presentationLifecycle: Self = "presentation-lifecycle"
    public static let popoverChrome: Self = "popover-chrome"
    public static let dataRefresh: Self = "data-refresh"
    public static let accountSelection: Self = "account-selection"
    public static let hoverSurvival: Self = "hover-survival"
    public static let textInput: Self = "text-input"
    public static let submission: Self = "submission"
    public static let keyboardRouting: Self = "keyboard-routing"
    public static let draftPersistence: Self = "draft-persistence"
    public static let streamAvailability: Self = "stream-availability"
    public static let permissionState: Self = "permission-state"
    public static let transcriptOrder: Self = "transcript-order"
    public static let messageContent: Self = "message-content"
    public static let turnBoundary: Self = "turn-boundary"
    public static let streamingLifecycle: Self = "streaming-lifecycle"
    public static let toolResultAttachment: Self = "tool-result-attachment"
    public static let toolExpansion: Self = "tool-expansion"
    public static let permissionDecision: Self = "permission-decision"
    public static let permissionQueue: Self = "permission-queue"
    public static let remoteMirroring: Self = "remote-mirroring"
    public static let tabSelection: Self = "tab-selection"
    public static let tabClosure: Self = "tab-closure"
    public static let tabOrder: Self = "tab-order"
    public static let tabIdentity: Self = "tab-identity"
    public static let tabActiveState: Self = "tab-active-state"
    public static let tabOverflow: Self = "tab-overflow"
    public static let tabPersistence: Self = "tab-persistence"
    public static let newTabMenu: Self = "new-tab-menu"
    public static let paneVisibility: Self = "pane-visibility"
    public static let cardNavigation: Self = "card-navigation"

    /// The host composites a backdrop below a stated opacity ceiling, whatever the tree draws,
    /// so the content above it keeps a floor of its own contrast.
    public static let legibilityCeiling: Self = "legibility-ceiling"
    /// The host clamps a live surface's frame rate to the contract's ceiling and holds its
    /// frames while its window is occluded, miniaturized or hidden.
    public static let frameCadence: Self = "frame-cadence"
    /// The host hit-tests through the whole backdrop; nothing in it can take a click.
    public static let pointerPassthrough: Self = "pointer-passthrough"
    /// Under Reduce Motion the host freezes a live surface's clock.
    public static let reducedMotion: Self = "reduced-motion"
}

/// A machine-readable description of exactly what one host component allows.
public struct ExtensionComponentContract: Codable, Equatable, Sendable {
    public let id: ExtensionComponentID
    public let version: Int
    public let context: ExtensionComponentContextKind
    public let properties: [ExtensionComponentPropertyID]
    public let slots: [ExtensionComponentSlotContract]
    public let replacement: ExtensionComponentReplacementPolicy
    public let replacementConstraints: ExtensionComponentNodeConstraints?
    /// Constraints for composable around-content hooks. Nil means this component exposes no
    /// hook seam. Hook recipes call the next hook through `.proceed`.
    public let hookConstraints: ExtensionComponentNodeConstraints?
    public let hostOwnedBehavior: [ExtensionHostOwnedBehavior]

    public init(
        id: ExtensionComponentID,
        version: Int,
        context: ExtensionComponentContextKind,
        properties: [ExtensionComponentPropertyID] = [],
        slots: [ExtensionComponentSlotContract] = [],
        replacement: ExtensionComponentReplacementPolicy = .none,
        replacementConstraints: ExtensionComponentNodeConstraints? = nil,
        hookConstraints: ExtensionComponentNodeConstraints? = nil,
        hostOwnedBehavior: [ExtensionHostOwnedBehavior] = []
    ) {
        self.id = id
        self.version = version
        self.context = context
        self.properties = properties
        self.slots = slots
        self.replacement = replacement
        self.replacementConstraints = replacementConstraints
        self.hookConstraints = hookConstraints
        self.hostOwnedBehavior = hostOwnedBehavior
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []

        if id.rawValue.isEmpty {
            issues.append(.init(path: "id", message: "must not be empty"))
        }
        if version < 1 {
            issues.append(.init(path: "version", message: "must be at least 1"))
        }

        issues.append(contentsOf: duplicateIssues(
            properties.map(\.rawValue),
            path: "properties"
        ))
        issues.append(contentsOf: duplicateIssues(
            slots.map(\.id.rawValue),
            path: "slots"
        ))

        for (index, slot) in slots.enumerated() where slot.maximumInlineItems < 1 {
            issues.append(.init(
                path: "slots[\(index)].maximumInlineItems",
                message: "must be at least 1"
            ))
        }
        for (index, slot) in slots.enumerated() {
            do {
                try slot.contentConstraints?.validate()
            } catch let error as ExtensionValidationError {
                issues.append(contentsOf: error.issues.map {
                    .init(
                        path: "slots[\(index)].contentConstraints.\($0.path)",
                        message: $0.message
                    )
                })
            } catch {
                issues.append(.init(
                    path: "slots[\(index)].contentConstraints",
                    message: error.localizedDescription
                ))
            }
        }

        if replacement == .none, replacementConstraints != nil {
            issues.append(.init(
                path: "replacementConstraints",
                message: "requires contentOnly replacement"
            ))
        }
        do {
            try replacementConstraints?.validate()
        } catch let error as ExtensionValidationError {
            issues.append(contentsOf: error.issues.map {
                .init(
                    path: "replacementConstraints.\($0.path)",
                    message: $0.message
                )
            })
        } catch {
            issues.append(.init(
                path: "replacementConstraints",
                message: error.localizedDescription
            ))
        }
        do {
            try hookConstraints?.validate()
        } catch let error as ExtensionValidationError {
            issues.append(contentsOf: error.issues.map {
                .init(
                    path: "hookConstraints.\($0.path)",
                    message: $0.message
                )
            })
        } catch {
            issues.append(.init(
                path: "hookConstraints",
                message: error.localizedDescription
            ))
        }
        if let hookConstraints, !hookConstraints.requiresProceed {
            issues.append(.init(
                path: "hookConstraints.requiresProceed",
                message: "must be true for composable hooks"
            ))
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }

    private func duplicateIssues(_ values: [String], path: String) -> [ExtensionValidationIssue] {
        var seen: Set<String> = []
        return values.enumerated().compactMap { index, value in
            guard !value.isEmpty else {
                return .init(path: "\(path)[\(index)]", message: "must not be empty")
            }
            guard seen.insert(value).inserted else {
                return .init(path: "\(path)[\(index)]", message: "duplicates '\(value)'")
            }
            return nil
        }
    }
}

/// A component family or one concrete entity-backed component instance.
///
/// A nil `entityID` is a family-wide patch. A concrete entity patch is layered on top of it.
public struct ExtensionComponentTarget: Codable, Equatable, Hashable, Sendable {
    public let component: ExtensionComponentID
    public let contractVersion: Int
    public let entityID: String?

    public init(
        component: ExtensionComponentID,
        contractVersion: Int,
        entityID: String? = nil
    ) {
        self.component = component
        self.contractVersion = contractVersion
        self.entityID = entityID
    }
}

public extension ExtensionComponentTarget {
    /// Targets every session identity when `sessionID` is nil, or one concrete session.
    static func sessionIdentity(sessionID: String? = nil) -> Self {
        Self(
            component: .sidebarSessionIdentity,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets the one sidebar backdrop. The sidebar is app-wide, so there is no entity.
    static func sidebarBackdrop() -> Self {
        Self(component: .sidebarBackdrop, contractVersion: 1)
    }

    /// Targets every project hover card when `projectID` is nil, or one concrete project.
    static func projectHoverCard(projectID: String? = nil) -> Self {
        Self(
            component: .sidebarProjectHoverCard,
            contractVersion: 1,
            entityID: projectID
        )
    }

    /// Targets every session hover card when `sessionID` is nil, or one concrete session.
    static func sessionHoverCard(sessionID: String? = nil) -> Self {
        Self(
            component: .sidebarSessionHoverCard,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets every session's corner card when `sessionID` is nil, or one concrete session.
    static func sessionCornerCard(sessionID: String? = nil) -> Self {
        Self(
            component: .sessionCornerCard,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets every account usage popover when `accountID` is nil, or one concrete account.
    static func accountUsagePopover(accountID: String? = nil) -> Self {
        Self(
            component: .toolbarAccountUsagePopover,
            contractVersion: 1,
            entityID: accountID
        )
    }

    /// Targets every new-session composer when `projectID` is nil, or one project instance.
    static func sessionStartComposer(projectID: String? = nil) -> Self {
        Self(
            component: .composerSessionStart,
            contractVersion: 1,
            entityID: projectID
        )
    }

    /// Targets every reply composer when `sessionID` is nil, or one conversation instance.
    static func conversationReplyComposer(sessionID: String? = nil) -> Self {
        Self(
            component: .composerConversationReply,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets user-message rows in every conversation, or all such rows in one session.
    static func conversationUserMessage(sessionID: String? = nil) -> Self {
        Self(
            component: .conversationUserMessage,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets assistant-message rows in every conversation, or all such rows in one session.
    static func conversationAssistantMessage(sessionID: String? = nil) -> Self {
        Self(
            component: .conversationAssistantMessage,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets tool-call rows in every conversation, or all such rows in one session.
    static func conversationToolCall(sessionID: String? = nil) -> Self {
        Self(
            component: .conversationToolCall,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets permission cards in every conversation, or all such cards in one session.
    static func conversationPermissionCard(sessionID: String? = nil) -> Self {
        Self(
            component: .conversationPermissionCard,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets the display-pane header for every session, or one session's header.
    static func displayPaneHeader(sessionID: String? = nil) -> Self {
        Self(
            component: .displayPaneHeader,
            contractVersion: 1,
            entityID: sessionID
        )
    }

    /// Targets every display-tab header, or all tab headers belonging to one session.
    ///
    /// Tab instances remain host-owned and intentionally have no public UUID-based target.
    static func displayTabHeader(sessionID: String? = nil) -> Self {
        Self(
            component: .displayTabHeader,
            contractVersion: 1,
            entityID: sessionID
        )
    }
}

/// A host snapshot supplied to extension logic. Its values are semantic and serializable.
public struct ExtensionComponentContext: Codable, Equatable, Sendable {
    public let target: ExtensionComponentTarget
    public let kind: ExtensionComponentContextKind
    public let values: [String: ExtensionJSONValue]

    public init(
        target: ExtensionComponentTarget,
        kind: ExtensionComponentContextKind,
        values: [String: ExtensionJSONValue] = [:]
    ) {
        self.target = target
        self.kind = kind
        self.values = values
    }
}

public enum ExtensionComponentPropertyValue: Codable, Equatable, Sendable {
    case text(String)
    case flag(Bool)
    case image(ExtensionImageReference)
    case identity(ExtensionIdentityComposition)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case flag
        case image
        case identity
    }

    private enum Kind: String, Codable {
        case text
        case flag
        case image
        case identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .flag:
            self = .flag(try container.decode(Bool.self, forKey: .flag))
        case .image:
            self = .image(
                try container.decode(ExtensionImageReference.self, forKey: .image)
            )
        case .identity:
            self = .identity(
                try container.decode(ExtensionIdentityComposition.self, forKey: .identity)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .flag(let flag):
            try container.encode(Kind.flag, forKey: .type)
            try container.encode(flag, forKey: .flag)
        case .image(let image):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(image, forKey: .image)
        case .identity(let identity):
            try container.encode(Kind.identity, forKey: .type)
            try container.encode(identity, forKey: .identity)
        }
    }
}

public struct ExtensionComponentPropertyPatch: Codable, Equatable, Sendable {
    public let property: ExtensionComponentPropertyID
    public let value: ExtensionComponentPropertyValue

    public init(
        property: ExtensionComponentPropertyID,
        value: ExtensionComponentPropertyValue
    ) {
        self.property = property
        self.value = value
    }
}

public struct ExtensionComponentSlotPatch: Codable, Equatable, Sendable {
    public let slot: ExtensionComponentSlotID
    public let children: [ExtensionNode]

    public init(slot: ExtensionComponentSlotID, children: [ExtensionNode]) {
        self.slot = slot
        self.children = children
    }
}

/// One atomic customization publication.
public struct ExtensionComponentPatch: Codable, Equatable, Sendable {
    public let id: String
    public let target: ExtensionComponentTarget
    public let properties: [ExtensionComponentPropertyPatch]
    public let slots: [ExtensionComponentSlotPatch]
    public let replacement: ExtensionNode?
    public let hook: ExtensionNode?

    public init(
        id: String,
        target: ExtensionComponentTarget,
        properties: [ExtensionComponentPropertyPatch] = [],
        slots: [ExtensionComponentSlotPatch] = [],
        replacement: ExtensionNode? = nil,
        hook: ExtensionNode? = nil
    ) {
        self.id = id
        self.target = target
        self.properties = properties
        self.slots = slots
        self.replacement = replacement
        self.hook = hook
    }
}

public extension ExtensionComponentContract {
    /// Validates one patch against this exact contract.
    ///
    /// Threading calls this before accepting a process publication, and extension-authoring
    /// tools call the same function before previewing generated JSON. Keeping the rule in the
    /// Foundation-only SDK prevents the host and an AI-authored extension from drifting.
    func validate(_ patch: ExtensionComponentPatch) throws {
        var issues: [ExtensionValidationIssue] = []

        if patch.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "id", message: "must not be empty"))
        }
        if patch.target.component != id {
            issues.append(.init(
                path: "target.component",
                message: "must equal '\(id.rawValue)'"
            ))
        }
        if patch.target.contractVersion != version {
            issues.append(.init(
                path: "target.contractVersion",
                message: "must equal \(version)"
            ))
        }
        if !patch.properties.isEmpty || !patch.slots.isEmpty
            || patch.replacement != nil || patch.hook != nil {
            // At least one contribution exists.
        } else {
            issues.append(.init(
                path: "patch",
                message: "must contain properties, slots, a replacement, or a hook"
            ))
        }

        let allowedProperties = Set(properties)
        var seenProperties: Set<ExtensionComponentPropertyID> = []
        for (index, property) in patch.properties.enumerated() {
            if !allowedProperties.contains(property.property) {
                issues.append(.init(
                    path: "properties[\(index)].property",
                    message: "'\(property.property.rawValue)' is not exposed"
                ))
            }
            if !seenProperties.insert(property.property).inserted {
                issues.append(.init(
                    path: "properties[\(index)].property",
                    message: "duplicates '\(property.property.rawValue)'"
                ))
            }
        }

        let slotContracts = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        var seenSlots: Set<ExtensionComponentSlotID> = []
        for (slotIndex, slot) in patch.slots.enumerated() {
            guard let slotContract = slotContracts[slot.slot] else {
                issues.append(.init(
                    path: "slots[\(slotIndex)].slot",
                    message: "'\(slot.slot.rawValue)' is not exposed"
                ))
                continue
            }
            if !seenSlots.insert(slot.slot).inserted {
                issues.append(.init(
                    path: "slots[\(slotIndex)].slot",
                    message: "duplicates '\(slot.slot.rawValue)'"
                ))
            }
            if slot.children.isEmpty {
                issues.append(.init(
                    path: "slots[\(slotIndex)].children",
                    message: "must not be empty"
                ))
            }
            if slot.children.count > slotContract.maximumInlineItems {
                issues.append(.init(
                    path: "slots[\(slotIndex)].children",
                    message: "exceeds item limit \(slotContract.maximumInlineItems)"
                ))
            }
            if let constraints = slotContract.contentConstraints {
                for (childIndex, child) in slot.children.enumerated() {
                    collectValidationIssues(
                        for: child,
                        constraints: constraints,
                        path: "slots[\(slotIndex)].children[\(childIndex)]",
                        into: &issues
                    )
                }
            }
        }

        if patch.replacement != nil, replacement != .contentOnly {
            issues.append(.init(
                path: "replacement",
                message: "is not allowed by this contract"
            ))
        }
        if let replacement = patch.replacement,
           let replacementConstraints {
            collectValidationIssues(
                for: replacement,
                constraints: replacementConstraints,
                path: "replacement",
                into: &issues
            )
        }
        if patch.hook != nil, hookConstraints == nil {
            issues.append(.init(path: "hook", message: "is not allowed by this contract"))
        }
        if let hook = patch.hook, let hookConstraints {
            collectValidationIssues(
                for: hook,
                constraints: hookConstraints,
                path: "hook",
                into: &issues
            )
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }

    private func collectValidationIssues(
        for node: ExtensionNode,
        constraints: ExtensionComponentNodeConstraints,
        path: String,
        into issues: inout [ExtensionValidationIssue]
    ) {
        do {
            try constraints.validate(node, path: path)
        } catch let error as ExtensionValidationError {
            issues.append(contentsOf: error.issues)
        } catch {
            issues.append(.init(path: path, message: error.localizedDescription))
        }
    }
}
