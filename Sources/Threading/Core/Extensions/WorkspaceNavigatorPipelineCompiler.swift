import Foundation
import ThreadingExtensionKit

struct WorkspaceNavigatorPipelineCompilationIssue: Equatable, Hashable, Sendable {
    let path: String
    let message: String
}

enum WorkspaceNavigatorPipelineCompilationResult: Sendable {
    case ready(CompiledWorkspaceNavigatorPipeline)
    case unavailable(missingRequiredFacts: [ExtensionFactKey])
    case invalid([WorkspaceNavigatorPipelineCompilationIssue])
}

/// A provider-checked, option-specialized pipeline which is safe to evaluate without IPC.
///
/// Compilation removes provider-level `enhances` gaps. Per-subject gaps deliberately remain for
/// the evaluator so they can follow unknown and fallback semantics against one frozen revision.
struct CompiledWorkspaceNavigatorPipeline: Sendable {
    let snapshot: ExtensionFactSnapshot
    let search: ExtensionWorkspaceNavigatorSearch?
    let filters: [ExtensionWorkspaceNavigatorFilterClause]
    let bucket: ExtensionWorkspaceNavigatorBucketStrategy?
    let sort: [ExtensionWorkspaceNavigatorSortClause]
    let output: ExtensionWorkspaceNavigatorPipelineOutput
    let rowTemplate: ExtensionWorkspaceNavigatorTemplateNode?
}

struct WorkspaceNavigatorPipelineCompiler {
    func compile(
        _ pipeline: ExtensionWorkspaceNavigatorPipeline,
        snapshot: ExtensionFactSnapshot,
        optionValues: [String: ExtensionJSONValue]
    ) -> WorkspaceNavigatorPipelineCompilationResult {
        let requirements = Dictionary(
            pipeline.consumes.map { ($0.key, $0.requirement) },
            uniquingKeysWith: { first, _ in first }
        )
        let missingRequired = pipeline.consumes.compactMap { consumption in
            consumption.requirement == .required && !snapshot.hasProvider(for: consumption.key)
                ? consumption.key
                : nil
        }.sorted(by: factKeyLessThan)
        if !missingRequired.isEmpty {
            return .unavailable(missingRequiredFacts: missingRequired)
        }

        var validator = RuntimePipelineValidator(
            pipeline: pipeline,
            snapshot: snapshot,
            requirements: requirements
        )
        let issues = validator.validate()
        if !issues.isEmpty {
            return .invalid(issues)
        }

        let missingEnhancements = Set(pipeline.consumes.compactMap { consumption in
            consumption.requirement == .enhances && !snapshot.hasProvider(for: consumption.key)
                ? consumption.key
                : nil
        })
        let isActive: ([ExtensionWorkspaceNavigatorOptionCondition]) -> Bool = { conditions in
            conditions.allSatisfy { optionValues[$0.optionID] == $0.equals }
        }

        let search = pipeline.search.flatMap { search -> ExtensionWorkspaceNavigatorSearch? in
            let fields = search.fields.filter {
                $0.degradationDependencyKeys.isDisjoint(with: missingEnhancements)
            }
            guard !fields.isEmpty else { return nil }
            return .init(
                placeholder: search.placeholder,
                accessibilityLabel: search.accessibilityLabel,
                fields: fields
            )
        }
        let filters = pipeline.filters.filter {
            isActive($0.when)
                && $0.predicate.referencedFactKeys.isDisjoint(with: missingEnhancements)
        }
        let sort = pipeline.sort.filter {
            isActive($0.when)
                && $0.operand.fact.degradationDependencyKeys.isDisjoint(
                    with: missingEnhancements
                )
        }
        let bucket = firstSurvivingBucket(
            pipeline.buckets,
            missingEnhancements: missingEnhancements,
            isActive: isActive
        )
        let rowTemplate = degradeTemplate(
            pipeline.output.rowTemplate,
            missingEnhancements: missingEnhancements
        )

        return .ready(.init(
            snapshot: snapshot,
            search: search,
            filters: filters,
            bucket: bucket,
            sort: sort,
            output: pipeline.output,
            rowTemplate: rowTemplate
        ))
    }

    private func firstSurvivingBucket(
        _ clauses: [ExtensionWorkspaceNavigatorBucketClause],
        missingEnhancements: Set<ExtensionFactKey>,
        isActive: ([ExtensionWorkspaceNavigatorOptionCondition]) -> Bool
    ) -> ExtensionWorkspaceNavigatorBucketStrategy? {
        for clause in clauses where isActive(clause.when) {
            switch clause.strategy {
            case let .fact(operand, direction, explicitOrder):
                guard operand.fact.degradationDependencyKeys.isDisjoint(
                    with: missingEnhancements
                ) else { continue }
                return .fact(
                    operand,
                    direction: direction,
                    explicitOrder: explicitOrder
                )
            case let .rules(rules, unmatched):
                let surviving = rules.filter {
                    $0.predicate.referencedFactKeys.isDisjoint(with: missingEnhancements)
                }
                guard !surviving.isEmpty else { continue }
                return .rules(surviving, unmatched: unmatched)
            }
        }
        return nil
    }

    private func degradeTemplate(
        _ node: ExtensionWorkspaceNavigatorTemplateNode,
        missingEnhancements: Set<ExtensionFactKey>
    ) -> ExtensionWorkspaceNavigatorTemplateNode? {
        switch node {
        case let .text(binding, role):
            guard let binding = degradeTextBinding(
                binding,
                missingEnhancements: missingEnhancements
            ) else { return nil }
            return .text(binding, role: role)
        case let .image(binding, role, accessibilityLabel):
            guard let binding = degradeImageBinding(
                binding,
                missingEnhancements: missingEnhancements
            ) else { return nil }
            return .image(binding, role: role, accessibilityLabel: accessibilityLabel)
        case let .status(binding, role):
            guard let binding = degradeTextBinding(
                binding,
                missingEnhancements: missingEnhancements
            ) else { return nil }
            return .status(
                binding,
                role: degradeStatusBinding(role, missingEnhancements: missingEnhancements)
            )
        case .activityIndicator, .divider, .spacer, .flexibleSpacer:
            return node
        case let .conditional(predicate, content):
            guard predicate.referencedFactKeys.isDisjoint(with: missingEnhancements),
                  let content = degradeTemplate(
                      content,
                      missingEnhancements: missingEnhancements
                  ) else { return nil }
            return .conditional(predicate, content: content)
        case let .stack(axis, spacing, children):
            let children = children.compactMap {
                degradeTemplate($0, missingEnhancements: missingEnhancements)
            }
            guard !children.isEmpty else { return nil }
            return .stack(axis: axis, spacing: spacing, children: children)
        }
    }

    private func degradeTextBinding(
        _ binding: ExtensionWorkspaceNavigatorTextBinding,
        missingEnhancements: Set<ExtensionFactKey>
    ) -> ExtensionWorkspaceNavigatorTextBinding? {
        switch binding {
        case .literal:
            return binding
        case let .fact(fact, _, fallback)
            where !fact.degradationDependencyKeys.isDisjoint(with: missingEnhancements):
            return fallback.map(ExtensionWorkspaceNavigatorTextBinding.literal)
        case .fact:
            return binding
        }
    }

    private func degradeImageBinding(
        _ binding: ExtensionWorkspaceNavigatorImageBinding,
        missingEnhancements: Set<ExtensionFactKey>
    ) -> ExtensionWorkspaceNavigatorImageBinding? {
        switch binding {
        case .literal:
            return binding
        case let .factIcon(fact, fallback)
            where !fact.degradationDependencyKeys.isDisjoint(with: missingEnhancements):
            return fallback.map(ExtensionWorkspaceNavigatorImageBinding.literal)
        case .factIcon:
            return binding
        }
    }

    private func degradeStatusBinding(
        _ binding: ExtensionWorkspaceNavigatorStatusBinding,
        missingEnhancements: Set<ExtensionFactKey>
    ) -> ExtensionWorkspaceNavigatorStatusBinding {
        switch binding {
        case .literal:
            return binding
        case let .factStatus(fact, fallback)
            where !fact.degradationDependencyKeys.isDisjoint(with: missingEnhancements):
            return .literal(fallback)
        case .factStatus:
            return binding
        }
    }
}

private struct RuntimePipelineValidator {
    let pipeline: ExtensionWorkspaceNavigatorPipeline
    let snapshot: ExtensionFactSnapshot
    let requirements: [ExtensionFactKey: ExtensionWorkspaceNavigatorFactRequirement]

    private var issues: [WorkspaceNavigatorPipelineCompilationIssue] = []

    init(
        pipeline: ExtensionWorkspaceNavigatorPipeline,
        snapshot: ExtensionFactSnapshot,
        requirements: [ExtensionFactKey: ExtensionWorkspaceNavigatorFactRequirement]
    ) {
        self.pipeline = pipeline
        self.snapshot = snapshot
        self.requirements = requirements
    }

    mutating func validate() -> [WorkspaceNavigatorPipelineCompilationIssue] {
        for (index, consumption) in pipeline.consumes.enumerated()
            where snapshot.hasProvider(for: consumption.key)
            && snapshot.definition(for: consumption.key) == nil
        {
            add(
                "pipeline.consumes[\(index)].key",
                "has a live provider but no compatible fact definition"
            )
        }

        if let search = pipeline.search {
            for (index, field) in search.fields.enumerated() {
                validate(
                    field,
                    usage: .searchable,
                    expectedType: .string,
                    path: "pipeline.search.fields[\(index)]"
                )
            }
        }
        for (index, filter) in pipeline.filters.enumerated() {
            validate(
                filter.predicate,
                usage: .filterable,
                path: "pipeline.filters[\(index)].predicate"
            )
        }
        for (index, bucket) in pipeline.buckets.enumerated() {
            switch bucket.strategy {
            case let .fact(operand, _, explicitOrder):
                let path = "pipeline.buckets[\(index)].strategy"
                let definition = validate(
                    operand,
                    usage: .groupable,
                    path: "\(path).operand"
                )
                if let definition {
                    for (valueIndex, value) in explicitOrder.enumerated()
                        where value.type != definition.valueType
                    {
                        add(
                            "\(path).explicitOrder[\(valueIndex)]",
                            "must have type '\(definition.valueType.rawValue)'"
                        )
                    }
                }
            case let .rules(rules, _):
                for (ruleIndex, rule) in rules.enumerated() {
                    validate(
                        rule.predicate,
                        usage: .groupable,
                        path: "pipeline.buckets[\(index)].strategy.rules[\(ruleIndex)].predicate"
                    )
                }
            }
        }
        for (index, sort) in pipeline.sort.enumerated() {
            validate(
                sort.operand,
                usage: .sortable,
                path: "pipeline.sort[\(index)].operand"
            )
        }
        validate(pipeline.output.rowTemplate, path: "pipeline.output.rowTemplate")
        return issues
    }

    @discardableResult
    private mutating func validate(
        _ operand: ExtensionWorkspaceNavigatorFactOperand,
        usage: ExtensionFactUsage,
        path: String
    ) -> ExtensionFactDefinition? {
        let definition = validate(operand.fact, usage: usage, path: "\(path).fact")
        if let definition, let fallback = operand.fallback,
           fallback.type != definition.valueType
        {
            add(
                "\(path).fallback",
                "must have type '\(definition.valueType.rawValue)'"
            )
        }
        return definition
    }

    @discardableResult
    private mutating func validate(
        _ reference: ExtensionWorkspaceNavigatorFactReference,
        usage: ExtensionFactUsage,
        expectedType: ExtensionFactValueType? = nil,
        path: String
    ) -> ExtensionFactDefinition? {
        guard requirements[reference.key] != nil else {
            add(path, "references an undeclared consumed fact")
            return nil
        }
        if reference.scope == .project,
           requirements[ExtensionHostFactKey.sessionProjectID] == nil
        {
            add(path, "project scope requires consuming 'session.project-id'")
        }
        guard snapshot.hasProvider(for: reference.key) else { return nil }
        guard let definition = snapshot.definition(for: reference.key) else { return nil }

        if !definition.usages.contains(usage) {
            add(path, "fact is not declared '\(usage.rawValue)'")
        }
        if let expectedType, definition.valueType != expectedType {
            add(path, "fact must have type '\(expectedType.rawValue)'")
        }
        let supportedKinds: Set<ExtensionFactSubjectKind> = switch reference.scope {
        case .item:
            [.session, .repository, .repositoryBranch]
        case .project:
            [.project, .repository, .repositoryBranch]
        }
        if definition.subjectKinds.isDisjoint(with: supportedKinds) {
            add(path, "fact cannot resolve at '\(reference.scope.rawValue)' scope")
        }
        return definition
    }

    private mutating func validate(
        _ predicate: ExtensionWorkspaceNavigatorPredicate,
        usage: ExtensionFactUsage,
        path: String
    ) {
        switch predicate {
        case let .comparison(operand, operation, value):
            let definition = validate(operand, usage: usage, path: "\(path).operand")
            if let definition, value.type != definition.valueType {
                add(
                    "\(path).value",
                    "must have type '\(definition.valueType.rawValue)'"
                )
            }
            if let definition, definition.valueType == .boolean,
               operation != .equal, operation != .notEqual
            {
                add("\(path).operation", "boolean facts only support equality comparisons")
            }
        case let .isPresent(reference):
            validate(reference, usage: usage, path: "\(path).fact")
        case let .relativeDate(operand, range):
            validate(
                operand.fact,
                usage: usage,
                expectedType: .date,
                path: "\(path).operand.fact"
            )
            if let fallback = operand.fallback, fallback.type != .date {
                add("\(path).operand.fallback", "must have type 'date'")
            }
            if case let .lastDays(days) = range, days < 1 {
                add("\(path).range", "lastDays must be positive")
            }
        case let .all(predicates), let .any(predicates):
            for (index, child) in predicates.enumerated() {
                validate(child, usage: usage, path: "\(path).predicates[\(index)]")
            }
        case let .not(predicate):
            validate(predicate, usage: usage, path: "\(path).predicate")
        }
    }

    private mutating func validate(
        _ node: ExtensionWorkspaceNavigatorTemplateNode,
        path: String
    ) {
        switch node {
        case let .text(binding, _):
            validate(binding, path: "\(path).binding")
        case let .image(binding, _, _):
            if case let .factIcon(reference, _) = binding {
                validate(reference, usage: .presentable, path: "\(path).binding.fact")
            }
        case let .status(binding, role):
            validate(binding, path: "\(path).binding")
            if case let .factStatus(reference, _) = role {
                validate(reference, usage: .presentable, path: "\(path).role.fact")
            }
        case let .conditional(predicate, content):
            validate(predicate, usage: .filterable, path: "\(path).predicate")
            validate(content, path: "\(path).content")
        case let .stack(_, _, children):
            for (index, child) in children.enumerated() {
                validate(child, path: "\(path).children[\(index)]")
            }
        case .activityIndicator, .divider, .spacer, .flexibleSpacer:
            break
        }
    }

    private mutating func validate(
        _ binding: ExtensionWorkspaceNavigatorTextBinding,
        path: String
    ) {
        if case let .fact(reference, _, _) = binding {
            validate(reference, usage: .presentable, path: "\(path).fact")
        }
    }

    private mutating func add(_ path: String, _ message: String) {
        issues.append(.init(path: path, message: message))
    }
}

extension ExtensionWorkspaceNavigatorPredicate {
    var referencedFactKeys: Set<ExtensionFactKey> {
        switch self {
        case let .comparison(operand, _, _), let .relativeDate(operand, _):
            operand.fact.degradationDependencyKeys
        case let .isPresent(reference):
            reference.degradationDependencyKeys
        case let .all(predicates), let .any(predicates):
            predicates.reduce(into: []) { $0.formUnion($1.referencedFactKeys) }
        case let .not(predicate):
            predicate.referencedFactKeys
        }
    }
}

private extension ExtensionWorkspaceNavigatorFactReference {
    /// Provider absence for a project-scoped value includes absence of the explicit structural
    /// join. Without `session.project-id`, no source subject can reach the project provider, so
    /// keeping the stanza would confuse provider-level degradation with per-subject unknown.
    var degradationDependencyKeys: Set<ExtensionFactKey> {
        switch scope {
        case .item:
            [key]
        case .project:
            [key, ExtensionHostFactKey.sessionProjectID]
        }
    }
}

private func factKeyLessThan(_ lhs: ExtensionFactKey, _ rhs: ExtensionFactKey) -> Bool {
    lhs.id == rhs.id ? lhs.version < rhs.version : lhs.id < rhs.id
}
