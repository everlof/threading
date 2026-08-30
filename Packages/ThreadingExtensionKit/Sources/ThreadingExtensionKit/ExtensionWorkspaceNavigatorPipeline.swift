import Foundation

/// The host-owned entity stream evaluated by a declarative workspace navigator.
///
/// Format 1 deliberately starts with sessions. More source shapes can be added without making
/// the first evaluator pretend it can reproduce the native mixed project/session/terminal tree.
public enum ExtensionWorkspaceNavigatorPipelineSource: String, Codable, Equatable, Sendable {
    case sessions
}

/// Whether losing every provider for a consumed fact disables the navigator or degrades the
/// smallest declaration unit which uses that fact.
///
/// An unavailable `enhances` key removes its search field, filter clause, sort clause, fact bucket
/// clause, rule-bucket rule, or conditional-template node. A fact-bound presentation leaf uses
/// its fallback and is omitted when it has no fallback. These decisions happen before evaluating
/// individual source subjects; a live provider with no value for one subject is ordinary unknown
/// data instead. A missing `required` provider makes the complete navigator unavailable.
public enum ExtensionWorkspaceNavigatorFactRequirement: String, Codable, Equatable, Sendable {
    case required
    case enhances
}

/// One statically inspectable fact dependency of a navigator pipeline.
public struct ExtensionWorkspaceNavigatorFactConsumption: Codable, Equatable, Sendable {
    public let key: ExtensionFactKey
    public let requirement: ExtensionWorkspaceNavigatorFactRequirement

    public init(
        key: ExtensionFactKey,
        requirement: ExtensionWorkspaceNavigatorFactRequirement = .enhances
    ) {
        self.key = key
        self.requirement = requirement
    }
}

/// Where a fact is resolved relative to the current source item.
///
/// Project scope follows `session.project-id`; declaring any project-scoped reference therefore
/// also requires an explicit consumption of that join key. It is opt-in rather than inheritance
/// applied to every session fact lookup. A source session with no project ID has no value at this
/// scope, so ordinary per-subject unknown/fallback semantics apply.
public enum ExtensionWorkspaceNavigatorFactScope: String, Codable, Equatable, Hashable, Sendable {
    case item
    case project
}

public struct ExtensionWorkspaceNavigatorFactReference: Codable, Equatable, Hashable, Sendable {
    public let key: ExtensionFactKey
    public let scope: ExtensionWorkspaceNavigatorFactScope

    public init(
        _ key: ExtensionFactKey,
        scope: ExtensionWorkspaceNavigatorFactScope = .item
    ) {
        self.key = key
        self.scope = scope
    }
}

/// A fact input with an optional value used only when that subject has no value.
///
/// Provider absence is handled by the declaration's `required` / `enhances` tier before this
/// fallback is considered.
public struct ExtensionWorkspaceNavigatorFactOperand: Codable, Equatable, Sendable {
    public let fact: ExtensionWorkspaceNavigatorFactReference
    public let fallback: ExtensionFactValue?

    public init(
        _ fact: ExtensionWorkspaceNavigatorFactReference,
        fallback: ExtensionFactValue? = nil
    ) {
        self.fact = fact
        self.fallback = fallback
    }
}

/// An all-of condition over host-persisted navigator option values.
public struct ExtensionWorkspaceNavigatorOptionCondition: Codable, Equatable, Sendable {
    public let optionID: String
    public let equals: ExtensionJSONValue

    public init(optionID: String, equals: ExtensionJSONValue) {
        self.optionID = optionID
        self.equals = equals
    }
}

public enum ExtensionWorkspaceNavigatorComparison: String, Codable, Equatable, Sendable {
    case equal
    case notEqual
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

/// A host-calendar range. The host owns the clock, locale calendar, time zone and midnight edge.
public enum ExtensionWorkspaceNavigatorRelativeDateRange: Codable, Equatable, Sendable {
    case today
    case yesterday
    case lastDays(Int)

    private enum CodingKeys: String, CodingKey {
        case type
        case days
    }

    private enum Kind: String, Codable {
        case today
        case yesterday
        case lastDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .today:
            self = .today
        case .yesterday:
            self = .yesterday
        case .lastDays:
            self = try .lastDays(container.decode(Int.self, forKey: .days))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .today:
            try container.encode(Kind.today, forKey: .type)
        case .yesterday:
            try container.encode(Kind.yesterday, forKey: .type)
        case let .lastDays(days):
            try container.encode(Kind.lastDays, forKey: .type)
            try container.encode(days, forKey: .days)
        }
    }
}

/// A bounded predicate language evaluated with three-valued fact semantics by the host.
public indirect enum ExtensionWorkspaceNavigatorPredicate: Codable, Equatable, Sendable {
    case comparison(
        ExtensionWorkspaceNavigatorFactOperand,
        ExtensionWorkspaceNavigatorComparison,
        ExtensionFactValue
    )
    case isPresent(ExtensionWorkspaceNavigatorFactReference)
    case relativeDate(
        ExtensionWorkspaceNavigatorFactOperand,
        ExtensionWorkspaceNavigatorRelativeDateRange
    )
    case all([Self])
    case any([Self])
    case not(Self)

    private enum CodingKeys: String, CodingKey {
        case type
        case operand
        case operation
        case value
        case fact
        case range
        case predicates
        case predicate
    }

    private enum Kind: String, Codable {
        case comparison
        case isPresent
        case relativeDate
        case all
        case any
        case not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .comparison:
            self = try .comparison(
                container.decode(
                    ExtensionWorkspaceNavigatorFactOperand.self,
                    forKey: .operand
                ),
                container.decode(
                    ExtensionWorkspaceNavigatorComparison.self,
                    forKey: .operation
                ),
                container.decode(ExtensionFactValue.self, forKey: .value)
            )
        case .isPresent:
            self = try .isPresent(container.decode(
                ExtensionWorkspaceNavigatorFactReference.self,
                forKey: .fact
            ))
        case .relativeDate:
            self = try .relativeDate(
                container.decode(
                    ExtensionWorkspaceNavigatorFactOperand.self,
                    forKey: .operand
                ),
                container.decode(
                    ExtensionWorkspaceNavigatorRelativeDateRange.self,
                    forKey: .range
                )
            )
        case .all:
            self = try .all(container.decode([Self].self, forKey: .predicates))
        case .any:
            self = try .any(container.decode([Self].self, forKey: .predicates))
        case .not:
            self = try .not(container.decode(Self.self, forKey: .predicate))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .comparison(operand, operation, value):
            try container.encode(Kind.comparison, forKey: .type)
            try container.encode(operand, forKey: .operand)
            try container.encode(operation, forKey: .operation)
            try container.encode(value, forKey: .value)
        case let .isPresent(fact):
            try container.encode(Kind.isPresent, forKey: .type)
            try container.encode(fact, forKey: .fact)
        case let .relativeDate(operand, range):
            try container.encode(Kind.relativeDate, forKey: .type)
            try container.encode(operand, forKey: .operand)
            try container.encode(range, forKey: .range)
        case let .all(predicates):
            try container.encode(Kind.all, forKey: .type)
            try container.encode(predicates, forKey: .predicates)
        case let .any(predicates):
            try container.encode(Kind.any, forKey: .type)
            try container.encode(predicates, forKey: .predicates)
        case let .not(predicate):
            try container.encode(Kind.not, forKey: .type)
            try container.encode(predicate, forKey: .predicate)
        }
    }
}

/// One filter stanza. Active stanzas are ANDed in declaration order.
public struct ExtensionWorkspaceNavigatorFilterClause: Codable, Equatable, Sendable {
    public let when: [ExtensionWorkspaceNavigatorOptionCondition]
    public let predicate: ExtensionWorkspaceNavigatorPredicate

    public init(
        when conditions: [ExtensionWorkspaceNavigatorOptionCondition] = [],
        predicate: ExtensionWorkspaceNavigatorPredicate
    ) {
        when = conditions
        self.predicate = predicate
    }
}

public enum ExtensionWorkspaceNavigatorSortDirection: String, Codable, Equatable, Sendable {
    case ascending
    case descending
}

/// One conditional sort key. A missing subject value uses the operand fallback when present;
/// without one it follows present values in either direction. Opaque subject identity is the
/// host-owned final tie-break.
public struct ExtensionWorkspaceNavigatorSortClause: Codable, Equatable, Sendable {
    public let when: [ExtensionWorkspaceNavigatorOptionCondition]
    public let operand: ExtensionWorkspaceNavigatorFactOperand
    public let direction: ExtensionWorkspaceNavigatorSortDirection

    public init(
        when conditions: [ExtensionWorkspaceNavigatorOptionCondition] = [],
        operand: ExtensionWorkspaceNavigatorFactOperand,
        direction: ExtensionWorkspaceNavigatorSortDirection
    ) {
        when = conditions
        self.operand = operand
        self.direction = direction
    }
}

public struct ExtensionWorkspaceNavigatorBucketRule: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let predicate: ExtensionWorkspaceNavigatorPredicate

    public init(id: String, title: String, predicate: ExtensionWorkspaceNavigatorPredicate) {
        self.id = id
        self.title = title
        self.predicate = predicate
    }
}

public enum ExtensionWorkspaceNavigatorUnmatchedBucket: Codable, Equatable, Sendable {
    case omit
    case bucket(id: String, title: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case title
    }

    private enum Kind: String, Codable {
        case omit
        case bucket
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .omit:
            self = .omit
        case .bucket:
            self = try .bucket(
                id: container.decode(String.self, forKey: .id),
                title: container.decode(String.self, forKey: .title)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .omit:
            try container.encode(Kind.omit, forKey: .type)
        case let .bucket(id, title):
            try container.encode(Kind.bucket, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
        }
    }
}

/// How active source items become ordered sections.
public enum ExtensionWorkspaceNavigatorBucketStrategy: Codable, Equatable, Sendable {
    case fact(
        ExtensionWorkspaceNavigatorFactOperand,
        direction: ExtensionWorkspaceNavigatorSortDirection,
        explicitOrder: [ExtensionFactValue]
    )
    case rules(
        [ExtensionWorkspaceNavigatorBucketRule],
        unmatched: ExtensionWorkspaceNavigatorUnmatchedBucket
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case operand
        case direction
        case explicitOrder
        case rules
        case unmatched
    }

    private enum Kind: String, Codable {
        case fact
        case rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .fact:
            self = try .fact(
                container.decode(
                    ExtensionWorkspaceNavigatorFactOperand.self,
                    forKey: .operand
                ),
                direction: container.decode(
                    ExtensionWorkspaceNavigatorSortDirection.self,
                    forKey: .direction
                ),
                explicitOrder: container.decodeIfPresent(
                    [ExtensionFactValue].self,
                    forKey: .explicitOrder
                ) ?? []
            )
        case .rules:
            self = try .rules(
                container.decode(
                    [ExtensionWorkspaceNavigatorBucketRule].self,
                    forKey: .rules
                ),
                unmatched: container.decode(
                    ExtensionWorkspaceNavigatorUnmatchedBucket.self,
                    forKey: .unmatched
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fact(operand, direction, explicitOrder):
            try container.encode(Kind.fact, forKey: .type)
            try container.encode(operand, forKey: .operand)
            try container.encode(direction, forKey: .direction)
            if !explicitOrder.isEmpty {
                try container.encode(explicitOrder, forKey: .explicitOrder)
            }
        case let .rules(rules, unmatched):
            try container.encode(Kind.rules, forKey: .type)
            try container.encode(rules, forKey: .rules)
            try container.encode(unmatched, forKey: .unmatched)
        }
    }
}

/// The first active bucket clause supplies the navigator's sectioning strategy.
public struct ExtensionWorkspaceNavigatorBucketClause: Codable, Equatable, Sendable {
    public let when: [ExtensionWorkspaceNavigatorOptionCondition]
    public let strategy: ExtensionWorkspaceNavigatorBucketStrategy

    public init(
        when conditions: [ExtensionWorkspaceNavigatorOptionCondition] = [],
        strategy: ExtensionWorkspaceNavigatorBucketStrategy
    ) {
        when = conditions
        self.strategy = strategy
    }
}

/// A host-owned search field and the string facts it indexes entirely in memory.
public struct ExtensionWorkspaceNavigatorSearch: Codable, Equatable, Sendable {
    public let placeholder: String
    public let accessibilityLabel: String
    public let fields: [ExtensionWorkspaceNavigatorFactReference]

    public init(
        placeholder: String,
        accessibilityLabel: String,
        fields: [ExtensionWorkspaceNavigatorFactReference]
    ) {
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.fields = fields
    }
}

public enum ExtensionWorkspaceNavigatorTextFacet: String, Codable, Equatable, Sendable {
    case value
    case label
}

public enum ExtensionWorkspaceNavigatorTextBinding: Codable, Equatable, Sendable {
    case literal(String)
    case fact(
        ExtensionWorkspaceNavigatorFactReference,
        facet: ExtensionWorkspaceNavigatorTextFacet,
        fallback: String?
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case fact
        case facet
        case fallback
    }

    private enum Kind: String, Codable {
        case literal
        case fact
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .literal:
            self = try .literal(container.decode(String.self, forKey: .text))
        case .fact:
            self = try .fact(
                container.decode(
                    ExtensionWorkspaceNavigatorFactReference.self,
                    forKey: .fact
                ),
                facet: container.decode(
                    ExtensionWorkspaceNavigatorTextFacet.self,
                    forKey: .facet
                ),
                fallback: container.decodeIfPresent(String.self, forKey: .fallback)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .literal(text):
            try container.encode(Kind.literal, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .fact(fact, facet, fallback):
            try container.encode(Kind.fact, forKey: .type)
            try container.encode(fact, forKey: .fact)
            try container.encode(facet, forKey: .facet)
            try container.encodeIfPresent(fallback, forKey: .fallback)
        }
    }
}

public enum ExtensionWorkspaceNavigatorImageBinding: Codable, Equatable, Sendable {
    case literal(ExtensionImageReference)
    case factIcon(
        ExtensionWorkspaceNavigatorFactReference,
        fallback: ExtensionImageReference?
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case reference
        case fact
        case fallback
    }

    private enum Kind: String, Codable {
        case literal
        case factIcon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .literal:
            self = try .literal(container.decode(
                ExtensionImageReference.self,
                forKey: .reference
            ))
        case .factIcon:
            self = try .factIcon(
                container.decode(
                    ExtensionWorkspaceNavigatorFactReference.self,
                    forKey: .fact
                ),
                fallback: container.decodeIfPresent(
                    ExtensionImageReference.self,
                    forKey: .fallback
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .literal(reference):
            try container.encode(Kind.literal, forKey: .type)
            try container.encode(reference, forKey: .reference)
        case let .factIcon(fact, fallback):
            try container.encode(Kind.factIcon, forKey: .type)
            try container.encode(fact, forKey: .fact)
            try container.encodeIfPresent(fallback, forKey: .fallback)
        }
    }
}

public enum ExtensionWorkspaceNavigatorStatusBinding: Codable, Equatable, Sendable {
    case literal(ExtensionStatusRole)
    case factStatus(
        ExtensionWorkspaceNavigatorFactReference,
        fallback: ExtensionStatusRole
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case role
        case fact
        case fallback
    }

    private enum Kind: String, Codable {
        case literal
        case factStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .literal:
            self = try .literal(container.decode(ExtensionStatusRole.self, forKey: .role))
        case .factStatus:
            self = try .factStatus(
                container.decode(
                    ExtensionWorkspaceNavigatorFactReference.self,
                    forKey: .fact
                ),
                fallback: container.decode(ExtensionStatusRole.self, forKey: .fallback)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .literal(role):
            try container.encode(Kind.literal, forKey: .type)
            try container.encode(role, forKey: .role)
        case let .factStatus(fact, fallback):
            try container.encode(Kind.factStatus, forKey: .type)
            try container.encode(fact, forKey: .fact)
            try container.encode(fallback, forKey: .fallback)
        }
    }
}

/// One noninteractive row template realized only for visible source subjects.
public indirect enum ExtensionWorkspaceNavigatorTemplateNode: Codable, Equatable, Sendable {
    case text(ExtensionWorkspaceNavigatorTextBinding, role: ExtensionTextRole)
    case image(
        ExtensionWorkspaceNavigatorImageBinding,
        role: ExtensionImageRole,
        accessibilityLabel: String?
    )
    case status(
        ExtensionWorkspaceNavigatorTextBinding,
        role: ExtensionWorkspaceNavigatorStatusBinding
    )
    case activityIndicator(accessibilityLabel: String)
    /// A host-rendered control which asks Threading to perform one declared source-session
    /// intent. No gesture or source identity crosses into the extension process.
    case intent(ExtensionWorkspaceNavigatorIntent)
    case conditional(
        ExtensionWorkspaceNavigatorPredicate,
        content: Self
    )
    case divider
    case spacer(ExtensionSpacing)
    case flexibleSpacer
    case stack(axis: ExtensionAxis, spacing: ExtensionSpacing, children: [Self])

    private enum CodingKeys: String, CodingKey {
        case type
        case binding
        case role
        case accessibilityLabel
        case intent
        case predicate
        case content
        case spacing
        case axis
        case children
    }

    private enum Kind: String, Codable {
        case text
        case image
        case status
        case activityIndicator
        case intent
        case conditional
        case divider
        case spacer
        case flexibleSpacer
        case stack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = try .text(
                container.decode(
                    ExtensionWorkspaceNavigatorTextBinding.self,
                    forKey: .binding
                ),
                role: container.decode(ExtensionTextRole.self, forKey: .role)
            )
        case .image:
            self = try .image(
                container.decode(
                    ExtensionWorkspaceNavigatorImageBinding.self,
                    forKey: .binding
                ),
                role: container.decode(ExtensionImageRole.self, forKey: .role),
                accessibilityLabel: container.decodeIfPresent(
                    String.self,
                    forKey: .accessibilityLabel
                )
            )
        case .status:
            self = try .status(
                container.decode(
                    ExtensionWorkspaceNavigatorTextBinding.self,
                    forKey: .binding
                ),
                role: container.decode(
                    ExtensionWorkspaceNavigatorStatusBinding.self,
                    forKey: .role
                )
            )
        case .activityIndicator:
            self = try .activityIndicator(accessibilityLabel: container.decode(
                String.self,
                forKey: .accessibilityLabel
            ))
        case .intent:
            self = try .intent(container.decode(
                ExtensionWorkspaceNavigatorIntent.self,
                forKey: .intent
            ))
        case .conditional:
            self = try .conditional(
                container.decode(
                    ExtensionWorkspaceNavigatorPredicate.self,
                    forKey: .predicate
                ),
                content: container.decode(Self.self, forKey: .content)
            )
        case .divider:
            self = .divider
        case .spacer:
            self = try .spacer(container.decode(ExtensionSpacing.self, forKey: .spacing))
        case .flexibleSpacer:
            self = .flexibleSpacer
        case .stack:
            self = try .stack(
                axis: container.decode(ExtensionAxis.self, forKey: .axis),
                spacing: container.decode(ExtensionSpacing.self, forKey: .spacing),
                children: container.decode([Self].self, forKey: .children)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(binding, role):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(binding, forKey: .binding)
            try container.encode(role, forKey: .role)
        case let .image(binding, role, accessibilityLabel):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(binding, forKey: .binding)
            try container.encode(role, forKey: .role)
            try container.encodeIfPresent(accessibilityLabel, forKey: .accessibilityLabel)
        case let .status(binding, role):
            try container.encode(Kind.status, forKey: .type)
            try container.encode(binding, forKey: .binding)
            try container.encode(role, forKey: .role)
        case let .activityIndicator(accessibilityLabel):
            try container.encode(Kind.activityIndicator, forKey: .type)
            try container.encode(accessibilityLabel, forKey: .accessibilityLabel)
        case let .intent(intent):
            try container.encode(Kind.intent, forKey: .type)
            try container.encode(intent, forKey: .intent)
        case let .conditional(predicate, content):
            try container.encode(Kind.conditional, forKey: .type)
            try container.encode(predicate, forKey: .predicate)
            try container.encode(content, forKey: .content)
        case .divider:
            try container.encode(Kind.divider, forKey: .type)
        case let .spacer(spacing):
            try container.encode(Kind.spacer, forKey: .type)
            try container.encode(spacing, forKey: .spacing)
        case .flexibleSpacer:
            try container.encode(Kind.flexibleSpacer, forKey: .type)
        case let .stack(axis, spacing, children):
            try container.encode(Kind.stack, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(spacing, forKey: .spacing)
            try container.encode(children, forKey: .children)
        }
    }
}

public struct ExtensionWorkspaceNavigatorEmptyState: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

/// The host route attached to every row emitted from the pipeline's source.
///
/// Format 1 evaluates session source items only, so activation is the corresponding host-owned
/// session destination. The extension never receives a row click or supplies an arbitrary ID.
public enum ExtensionWorkspaceNavigatorPipelineActivation: String, Codable, Equatable, Sendable {
    case sourceSession

    /// Resolves a generated row to the host-owned route for its current source subject.
    public func destination(
        sourceSessionID: String,
        projectID: String?
    ) -> ExtensionWorkspaceNavigatorDestination {
        switch self {
        case .sourceSession:
            .session(id: sourceSessionID, projectID: projectID)
        }
    }
}

/// Format-1 behavior when more source subjects survive than its materialized output bound.
///
/// The host emits the first `itemLimit` subjects in final bucket and sort order, then appends a
/// host-localized, nonselectable notice reporting the omitted count. Rollout 7 replaces this
/// deliberately finite bridge with a windowed output format.
public enum ExtensionWorkspaceNavigatorPipelineOverflow: String, Codable, Equatable, Sendable {
    case truncateWithNotice
}

/// The stable collection shell produced by the pipeline. Format 1 accepts a single-select list;
/// later output shapes remain additive enum cases rather than claims made by this first host.
public struct ExtensionWorkspaceNavigatorPipelineOutput: Codable, Equatable, Sendable {
    public let collectionID: String
    public let layout: ExtensionWorkspaceNavigatorCollectionLayout
    public let selectionMode: ExtensionWorkspaceNavigatorSelectionMode
    public let activation: ExtensionWorkspaceNavigatorPipelineActivation
    public let itemLimit: Int
    public let overflow: ExtensionWorkspaceNavigatorPipelineOverflow
    public let rowTemplate: ExtensionWorkspaceNavigatorTemplateNode
    public let emptyState: ExtensionWorkspaceNavigatorEmptyState?

    public init(
        collectionID: String,
        layout: ExtensionWorkspaceNavigatorCollectionLayout = .list,
        selectionMode: ExtensionWorkspaceNavigatorSelectionMode = .single,
        activation: ExtensionWorkspaceNavigatorPipelineActivation = .sourceSession,
        itemLimit: Int = ExtensionWorkspaceNavigatorPipeline.maximumOutputItems,
        overflow: ExtensionWorkspaceNavigatorPipelineOverflow = .truncateWithNotice,
        rowTemplate: ExtensionWorkspaceNavigatorTemplateNode,
        emptyState: ExtensionWorkspaceNavigatorEmptyState? = nil
    ) {
        self.collectionID = collectionID
        self.layout = layout
        self.selectionMode = selectionMode
        self.activation = activation
        self.itemLimit = itemLimit
        self.overflow = overflow
        self.rowTemplate = rowTemplate
        self.emptyState = emptyState
    }
}

/// A static, host-evaluated navigator declaration.
///
/// It receives only immutable fact snapshots, the navigator's own option values, the host search
/// query and host clock. No extension code runs for evaluation or row realization.
public struct ExtensionWorkspaceNavigatorPipeline: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let maximumConsumptions = 32
    public static let maximumSearchFields = 8
    public static let maximumFilterClauses = 16
    public static let maximumBucketClauses = 8
    public static let maximumBucketRules = 32
    public static let maximumExplicitBucketValues = 32
    public static let maximumSortClauses = 8
    public static let maximumConditionsPerClause = 4
    public static let maximumPredicateDepth = 8
    public static let maximumPredicateNodes = 128
    public static let maximumTemplateDepth = 8
    public static let maximumTemplateNodes = 32
    public static let maximumTemplateTextLength = 1000
    public static let maximumOutputItems = 1000

    public let formatVersion: Int
    public let source: ExtensionWorkspaceNavigatorPipelineSource
    public let consumes: [ExtensionWorkspaceNavigatorFactConsumption]
    public let search: ExtensionWorkspaceNavigatorSearch?
    public let filters: [ExtensionWorkspaceNavigatorFilterClause]
    public let buckets: [ExtensionWorkspaceNavigatorBucketClause]
    public let sort: [ExtensionWorkspaceNavigatorSortClause]
    public let output: ExtensionWorkspaceNavigatorPipelineOutput

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        source: ExtensionWorkspaceNavigatorPipelineSource = .sessions,
        consumes: [ExtensionWorkspaceNavigatorFactConsumption],
        search: ExtensionWorkspaceNavigatorSearch? = nil,
        filters: [ExtensionWorkspaceNavigatorFilterClause] = [],
        buckets: [ExtensionWorkspaceNavigatorBucketClause] = [],
        sort: [ExtensionWorkspaceNavigatorSortClause] = [],
        output: ExtensionWorkspaceNavigatorPipelineOutput
    ) {
        self.formatVersion = formatVersion
        self.source = source
        self.consumes = consumes
        self.search = search
        self.filters = filters
        self.buckets = buckets
        self.sort = sort
        self.output = output
    }

    public func validationIssues(
        path: String = "pipeline",
        options: [ExtensionWorkspaceNavigatorOption] = [],
        intents: [ExtensionWorkspaceNavigatorIntent] = []
    ) -> [ExtensionValidationIssue] {
        var validator = WorkspaceNavigatorPipelineValidator(
            pipeline: self,
            options: options,
            intents: intents,
            path: path
        )
        return validator.validate()
    }
}

private struct WorkspaceNavigatorPipelineValidator {
    let pipeline: ExtensionWorkspaceNavigatorPipeline
    let options: [ExtensionWorkspaceNavigatorOption]
    let intents: [ExtensionWorkspaceNavigatorIntent]
    let path: String

    private var issues: [ExtensionValidationIssue] = []
    private var referencedFacts = Set<ExtensionFactKey>()
    private var referencedOptions = Set<String>()
    private var referencedIntents = Set<ExtensionWorkspaceNavigatorIntent>()
    private var predicateNodeCount = 0

    init(
        pipeline: ExtensionWorkspaceNavigatorPipeline,
        options: [ExtensionWorkspaceNavigatorOption],
        intents: [ExtensionWorkspaceNavigatorIntent],
        path: String
    ) {
        self.pipeline = pipeline
        self.options = options
        self.intents = intents
        self.path = path
    }

    mutating func validate() -> [ExtensionValidationIssue] {
        if pipeline.formatVersion != ExtensionWorkspaceNavigatorPipeline.currentFormatVersion {
            append("\(path).formatVersion", "must equal 1")
        }
        validateConsumptions()
        validateSearch()

        if pipeline.filters.count > ExtensionWorkspaceNavigatorPipeline.maximumFilterClauses {
            append(
                "\(path).filters",
                "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumFilterClauses) clauses"
            )
        }
        for (index, clause) in pipeline.filters.enumerated() {
            let clausePath = "\(path).filters[\(index)]"
            validateConditions(clause.when, path: "\(clausePath).when")
            validatePredicate(clause.predicate, path: "\(clausePath).predicate", depth: 0)
        }

        validateBuckets()

        if pipeline.sort.count > ExtensionWorkspaceNavigatorPipeline.maximumSortClauses {
            append(
                "\(path).sort",
                "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumSortClauses) clauses"
            )
        }
        for (index, clause) in pipeline.sort.enumerated() {
            let clausePath = "\(path).sort[\(index)]"
            validateConditions(clause.when, path: "\(clausePath).when")
            validateOperand(clause.operand, path: "\(clausePath).operand")
        }

        validateOutput()
        validateDeclaredDependencies()
        return issues
    }

    private mutating func validateConsumptions() {
        if pipeline.consumes.isEmpty {
            append("\(path).consumes", "must not be empty")
        } else if pipeline.consumes.count
            > ExtensionWorkspaceNavigatorPipeline.maximumConsumptions
        {
            append(
                "\(path).consumes",
                "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumConsumptions) facts"
            )
        }
        var seen = Set<ExtensionFactKey>()
        for (index, consumption) in pipeline.consumes.enumerated() {
            let itemPath = "\(path).consumes[\(index)]"
            issues.append(contentsOf: consumption.key.validationIssues(path: "\(itemPath).key"))
            if !seen.insert(consumption.key).inserted {
                append("\(itemPath).key", "duplicates a consumed fact key")
            }
        }
    }

    private mutating func validateSearch() {
        guard let search = pipeline.search else { return }
        validateText(search.placeholder, path: "\(path).search.placeholder", maximum: 120)
        validateText(
            search.accessibilityLabel,
            path: "\(path).search.accessibilityLabel",
            maximum: 256
        )
        if search.fields.isEmpty {
            append("\(path).search.fields", "must not be empty")
        } else if search.fields.count
            > ExtensionWorkspaceNavigatorPipeline.maximumSearchFields
        {
            append(
                "\(path).search.fields",
                "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumSearchFields) facts"
            )
        }
        var seen = Set<ExtensionWorkspaceNavigatorFactReference>()
        for (index, field) in search.fields.enumerated() {
            validateReference(field, path: "\(path).search.fields[\(index)]")
            if !seen.insert(field).inserted {
                append("\(path).search.fields[\(index)]", "duplicates a search field")
            }
        }
    }

    private mutating func validateBuckets() {
        if pipeline.buckets.count > ExtensionWorkspaceNavigatorPipeline.maximumBucketClauses {
            append(
                "\(path).buckets",
                "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumBucketClauses) clauses"
            )
        }
        for (index, clause) in pipeline.buckets.enumerated() {
            let clausePath = "\(path).buckets[\(index)]"
            validateConditions(clause.when, path: "\(clausePath).when")
            if clause.when.isEmpty, index != pipeline.buckets.indices.last {
                append(
                    "\(clausePath).when",
                    "an unconditional bucket clause must be last"
                )
            }
            validateBucketStrategy(clause.strategy, path: "\(clausePath).strategy")
        }
    }

    private mutating func validateBucketStrategy(
        _ strategy: ExtensionWorkspaceNavigatorBucketStrategy,
        path strategyPath: String
    ) {
        switch strategy {
        case let .fact(operand, _, explicitOrder):
            validateOperand(operand, path: "\(strategyPath).operand")
            if explicitOrder.count
                > ExtensionWorkspaceNavigatorPipeline.maximumExplicitBucketValues
            {
                append(
                    "\(strategyPath).explicitOrder",
                    "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumExplicitBucketValues) values"
                )
            }
            var seen = Set<ExtensionFactValue>()
            var valueType: ExtensionFactValueType?
            for (index, value) in explicitOrder.enumerated() {
                issues.append(contentsOf: value.validationIssues(
                    path: "\(strategyPath).explicitOrder[\(index)]"
                ))
                if !seen.insert(value).inserted {
                    append(
                        "\(strategyPath).explicitOrder[\(index)]",
                        "duplicates an explicit bucket value"
                    )
                }
                if let valueType, valueType != value.type {
                    append(
                        "\(strategyPath).explicitOrder[\(index)]",
                        "must have the same scalar type as the other explicit values"
                    )
                } else {
                    valueType = value.type
                }
            }
            if let fallbackType = operand.fallback?.type,
               let valueType,
               fallbackType != valueType
            {
                append(
                    "\(strategyPath).operand.fallback",
                    "must have the same scalar type as the explicit bucket values"
                )
            }
        case let .rules(rules, unmatched):
            if rules.isEmpty {
                append("\(strategyPath).rules", "must not be empty")
            } else if rules.count > ExtensionWorkspaceNavigatorPipeline.maximumBucketRules {
                append(
                    "\(strategyPath).rules",
                    "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumBucketRules) rules"
                )
            }
            var ids = Set<String>()
            for (index, rule) in rules.enumerated() {
                let rulePath = "\(strategyPath).rules[\(index)]"
                validateContributionID(rule.id, path: "\(rulePath).id")
                validateText(rule.title, path: "\(rulePath).title", maximum: 120)
                if !ids.insert(rule.id).inserted {
                    append("\(rulePath).id", "must be unique within the bucket strategy")
                }
                validatePredicate(rule.predicate, path: "\(rulePath).predicate", depth: 0)
            }
            if case let .bucket(id, title) = unmatched {
                validateContributionID(id, path: "\(strategyPath).unmatched.id")
                validateText(title, path: "\(strategyPath).unmatched.title", maximum: 120)
                if ids.contains(id) {
                    append(
                        "\(strategyPath).unmatched.id",
                        "must be unique within the bucket strategy"
                    )
                }
            }
        }
    }

    private mutating func validateOutput() {
        let outputPath = "\(path).output"
        validateContributionID(pipeline.output.collectionID, path: "\(outputPath).collectionID")
        if pipeline.output.layout != .list {
            append("\(outputPath).layout", "format 1 supports only list output")
        }
        if pipeline.output.selectionMode != .single {
            append("\(outputPath).selectionMode", "format 1 requires single selection")
        }
        if pipeline.output.activation != .sourceSession {
            append("\(outputPath).activation", "format 1 requires source-session activation")
        }
        if !(1 ... ExtensionWorkspaceNavigatorPipeline.maximumOutputItems).contains(
            pipeline.output.itemLimit
        ) {
            append(
                "\(outputPath).itemLimit",
                "must be between 1 and \(ExtensionWorkspaceNavigatorPipeline.maximumOutputItems)"
            )
        }
        if pipeline.output.overflow != .truncateWithNotice {
            append("\(outputPath).overflow", "format 1 requires truncate-with-notice overflow")
        }
        var templateNodes = 0
        validateTemplate(
            pipeline.output.rowTemplate,
            path: "\(outputPath).rowTemplate",
            depth: 0,
            nodes: &templateNodes
        )
        if let emptyState = pipeline.output.emptyState {
            validateText(emptyState.title, path: "\(outputPath).emptyState.title", maximum: 120)
            if let detail = emptyState.detail {
                validateText(detail, path: "\(outputPath).emptyState.detail", maximum: 500)
            }
        }
    }

    private mutating func validateTemplate(
        _ node: ExtensionWorkspaceNavigatorTemplateNode,
        path nodePath: String,
        depth: Int,
        nodes: inout Int
    ) {
        guard depth <= ExtensionWorkspaceNavigatorPipeline.maximumTemplateDepth else {
            append(
                nodePath,
                "exceeds maximum depth \(ExtensionWorkspaceNavigatorPipeline.maximumTemplateDepth)"
            )
            return
        }
        nodes += 1
        guard nodes <= ExtensionWorkspaceNavigatorPipeline.maximumTemplateNodes else {
            if nodes == ExtensionWorkspaceNavigatorPipeline.maximumTemplateNodes + 1 {
                append(
                    nodePath,
                    "exceeds maximum node count \(ExtensionWorkspaceNavigatorPipeline.maximumTemplateNodes)"
                )
            }
            return
        }
        switch node {
        case let .text(binding, _):
            validateTextBinding(binding, path: "\(nodePath).binding")
        case let .image(binding, _, accessibilityLabel):
            validateImageBinding(binding, path: "\(nodePath).binding")
            if let accessibilityLabel {
                validateText(
                    accessibilityLabel,
                    path: "\(nodePath).accessibilityLabel",
                    maximum: 256
                )
            }
        case let .status(binding, role):
            validateTextBinding(binding, path: "\(nodePath).binding")
            if case let .factStatus(fact, _) = role {
                validateReference(fact, path: "\(nodePath).role.fact")
            }
        case let .activityIndicator(accessibilityLabel):
            validateText(
                accessibilityLabel,
                path: "\(nodePath).accessibilityLabel",
                maximum: 256
            )
        case let .intent(intent):
            referencedIntents.insert(intent)
            if !intents.contains(intent) {
                append(
                    "\(nodePath).intent",
                    "must name an intent declared by the navigator"
                )
            }
        case let .conditional(predicate, content):
            validatePredicate(predicate, path: "\(nodePath).predicate", depth: 0)
            validateTemplate(
                content,
                path: "\(nodePath).content",
                depth: depth + 1,
                nodes: &nodes
            )
        case let .stack(_, _, children):
            if children.isEmpty {
                append("\(nodePath).children", "must not be empty")
            }
            for (index, child) in children.enumerated() {
                validateTemplate(
                    child,
                    path: "\(nodePath).children[\(index)]",
                    depth: depth + 1,
                    nodes: &nodes
                )
            }
        case .divider, .spacer, .flexibleSpacer:
            break
        }
    }

    private mutating func validateTextBinding(
        _ binding: ExtensionWorkspaceNavigatorTextBinding,
        path bindingPath: String
    ) {
        switch binding {
        case let .literal(text):
            validateBoundedText(text, path: "\(bindingPath).text")
        case let .fact(fact, _, fallback):
            validateReference(fact, path: "\(bindingPath).fact")
            if let fallback {
                validateBoundedText(fallback, path: "\(bindingPath).fallback", allowsEmpty: true)
            }
        }
    }

    private mutating func validateImageBinding(
        _ binding: ExtensionWorkspaceNavigatorImageBinding,
        path bindingPath: String
    ) {
        switch binding {
        case let .literal(reference):
            validateImageReference(reference, path: "\(bindingPath).reference")
        case let .factIcon(fact, fallback):
            validateReference(fact, path: "\(bindingPath).fact")
            if let fallback {
                validateImageReference(fallback, path: "\(bindingPath).fallback")
            }
        }
    }

    private mutating func validateImageReference(
        _ reference: ExtensionImageReference,
        path referencePath: String
    ) {
        let value: String
        switch reference {
        case let .hostAsset(identifier):
            value = identifier
        case let .extensionResource(relativePath):
            value = relativePath
            if !ExtensionIdentifierRules.isSafeRelativePath(relativePath) {
                append(referencePath, "extension resource must be a safe package-relative path")
            }
        case let .systemSymbol(name):
            value = name
        }
        if value.isEmpty
            || value != value.trimmingCharacters(in: .whitespacesAndNewlines)
            || value.utf8.count > ExtensionFact.maximumIconReferenceBytes
        {
            append(
                referencePath,
                "must be 1 to \(ExtensionFact.maximumIconReferenceBytes) UTF-8 bytes "
                    + "without surrounding whitespace"
            )
        }
    }

    private mutating func validatePredicate(
        _ predicate: ExtensionWorkspaceNavigatorPredicate,
        path predicatePath: String,
        depth: Int
    ) {
        guard depth <= ExtensionWorkspaceNavigatorPipeline.maximumPredicateDepth else {
            append(
                predicatePath,
                "exceeds maximum depth \(ExtensionWorkspaceNavigatorPipeline.maximumPredicateDepth)"
            )
            return
        }
        predicateNodeCount += 1
        guard predicateNodeCount <= ExtensionWorkspaceNavigatorPipeline.maximumPredicateNodes else {
            if predicateNodeCount == ExtensionWorkspaceNavigatorPipeline.maximumPredicateNodes + 1 {
                append(
                    predicatePath,
                    "exceeds aggregate predicate node count \(ExtensionWorkspaceNavigatorPipeline.maximumPredicateNodes)"
                )
            }
            return
        }
        switch predicate {
        case let .comparison(operand, _, value):
            validateOperand(operand, path: "\(predicatePath).operand")
            issues.append(contentsOf: value.validationIssues(path: "\(predicatePath).value"))
            if let fallback = operand.fallback, fallback.type != value.type {
                append(
                    "\(predicatePath).operand.fallback",
                    "must have the same scalar type as the comparison value"
                )
            }
        case let .isPresent(fact):
            validateReference(fact, path: "\(predicatePath).fact")
        case let .relativeDate(operand, range):
            validateOperand(operand, path: "\(predicatePath).operand")
            if let fallback = operand.fallback, fallback.type != .date {
                append("\(predicatePath).operand.fallback", "must be a date")
            }
            if case let .lastDays(days) = range, !(2 ... 365).contains(days) {
                append("\(predicatePath).range.days", "must be between 2 and 365")
            }
        case let .all(predicates), let .any(predicates):
            if predicates.isEmpty {
                append("\(predicatePath).predicates", "must not be empty")
            }
            for (index, child) in predicates.enumerated() {
                validatePredicate(
                    child,
                    path: "\(predicatePath).predicates[\(index)]",
                    depth: depth + 1
                )
            }
        case let .not(child):
            validatePredicate(child, path: "\(predicatePath).predicate", depth: depth + 1)
        }
    }

    private mutating func validateOperand(
        _ operand: ExtensionWorkspaceNavigatorFactOperand,
        path operandPath: String
    ) {
        validateReference(operand.fact, path: "\(operandPath).fact")
        if let fallback = operand.fallback {
            issues.append(contentsOf: fallback.validationIssues(path: "\(operandPath).fallback"))
        }
    }

    private mutating func validateReference(
        _ reference: ExtensionWorkspaceNavigatorFactReference,
        path referencePath: String
    ) {
        issues.append(contentsOf: reference.key.validationIssues(path: "\(referencePath).key"))
        referencedFacts.insert(reference.key)
        if reference.scope == .project {
            referencedFacts.insert(ExtensionHostFactKey.sessionProjectID)
        }
    }

    private mutating func validateConditions(
        _ conditions: [ExtensionWorkspaceNavigatorOptionCondition],
        path conditionsPath: String
    ) {
        if conditions.count > ExtensionWorkspaceNavigatorPipeline.maximumConditionsPerClause {
            append(
                conditionsPath,
                "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumConditionsPerClause) conditions"
            )
        }
        var seen = Set<String>()
        for (index, condition) in conditions.enumerated() {
            let conditionPath = "\(conditionsPath)[\(index)]"
            validateContributionID(condition.optionID, path: "\(conditionPath).optionID")
            referencedOptions.insert(condition.optionID)
            if !seen.insert(condition.optionID).inserted {
                append("\(conditionPath).optionID", "duplicates a condition in this clause")
            }
            guard condition.equals.isBool || condition.equals.isString else {
                append(
                    "\(conditionPath).equals",
                    "must be a boolean or string navigator option value"
                )
                continue
            }
            guard let option = options.first(where: { $0.id == condition.optionID }) else {
                append("\(conditionPath).optionID", "does not name a declared navigator option")
                continue
            }
            if !option.control.accepts(condition.equals) {
                append("\(conditionPath).equals", "is not accepted by the declared option")
            }
        }
    }

    private mutating func validateDeclaredDependencies() {
        let consumed = Set(pipeline.consumes.map(\.key))
        for fact in referencedFacts.subtracting(consumed).sorted(by: factKeyLessThan) {
            append(
                "\(path).consumes",
                "must declare referenced fact '\(fact.id)@\(fact.version)'"
            )
        }
        for fact in consumed.subtracting(referencedFacts).sorted(by: factKeyLessThan) {
            append(
                "\(path).consumes",
                "declares unused fact '\(fact.id)@\(fact.version)'"
            )
        }

        let declaredOptionIDs = Set(options.map(\.id))
        for optionID in declaredOptionIDs.subtracting(referencedOptions).sorted() {
            append(
                "\(path).options",
                "declared navigator option '\(optionID)' is not consumed by the pipeline"
            )
        }

        let declaredIntents = Set(intents)
        for intent in declaredIntents.subtracting(referencedIntents).sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            append(
                "\(path).output.rowTemplate",
                "declared navigator intent '\(intent.rawValue)' is not bound by the pipeline"
            )
        }
    }

    private func factKeyLessThan(_ lhs: ExtensionFactKey, _ rhs: ExtensionFactKey) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.version < rhs.version
    }

    private mutating func validateContributionID(_ value: String, path valuePath: String) {
        if !ExtensionIdentifierRules.isContributionIdentifier(value) {
            append(valuePath, ExtensionIdentifierRules.contributionMessage)
        }
    }

    private mutating func validateText(
        _ value: String,
        path valuePath: String,
        maximum: Int
    ) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(valuePath, "must not be empty")
        } else if value.count > maximum {
            append(valuePath, "must contain at most \(maximum) characters")
        }
    }

    private mutating func validateBoundedText(
        _ value: String,
        path valuePath: String,
        allowsEmpty: Bool = false
    ) {
        if !allowsEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(valuePath, "must not be empty")
        }
        if value.count > ExtensionWorkspaceNavigatorPipeline.maximumTemplateTextLength {
            append(
                valuePath,
                "must contain at most \(ExtensionWorkspaceNavigatorPipeline.maximumTemplateTextLength) characters"
            )
        }
    }

    private mutating func append(_ issuePath: String, _ message: String) {
        issues.append(.init(path: issuePath, message: message))
    }
}

private extension ExtensionJSONValue {
    var isBool: Bool {
        if case .bool = self { return true }
        return false
    }

    var isString: Bool {
        if case .string = self { return true }
        return false
    }
}
