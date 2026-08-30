import Foundation

/// Public bounds shared by fact providers and Threading's admission registry.
public enum ExtensionFactProviderLimits {
    public static let maximumDefinitions = 128
    public static let maximumSubjectsPerPublication = 2_048
    public static let maximumFactsPerPublication = 2_048
    public static let maximumFactsPerSubject = 32
    public static let maximumFactsPerGeneration = 16_384
}

public extension ExtensionFactSubjectKind {
    /// Subjects a provider may name without learning Threading's opaque entity identifiers.
    var isFactProviderDomain: Bool {
        self == .repository || self == .repositoryBranch
    }
}

public extension ExtensionFactDefinition {
    /// Validation added by the public provider boundary on top of the scalar fact contract.
    func providerValidationIssues(path: String = "definition") -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        do {
            try validate()
        } catch let error as ExtensionValidationError {
            issues.append(contentsOf: error.issues.map {
                let suffix = $0.path == "key" ? "key" : $0.path
                return .init(path: "\(path).\(suffix)", message: $0.message)
            })
        } catch {
            issues.append(.init(path: path, message: error.localizedDescription))
        }
        if ExtensionHostFactKey.isReserved(key) {
            issues.append(.init(
                path: "\(path).key",
                message: "uses a namespace reserved for Threading"
            ))
        }
        for kind in subjectKinds where !kind.isFactProviderDomain {
            issues.append(.init(
                path: "\(path).subjectKinds",
                message: "may contain only repository and repositoryBranch"
            ))
            break
        }
        return issues
    }
}

/// One bounded, atomic replacement of facts owned by the calling process generation.
///
/// Every named subject is complete for this generation after the call. Omitting a previously
/// published fact removes it; an empty `facts` array clears all facts for the named subjects.
/// Source identity and process generation come from the host bearer and never cross in this value.
public struct ExtensionFactPublication: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let replacingSubjects: [ExtensionFactSubject]
    public let facts: [ExtensionFact]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        replacingSubjects: [ExtensionFactSubject],
        facts: [ExtensionFact]
    ) {
        self.protocolVersion = protocolVersion
        self.replacingSubjects = replacingSubjects
        self.facts = facts
    }

    public func validate() throws {
        struct Cell: Hashable {
            let subject: ExtensionFactSubject
            let key: ExtensionFactKey
        }

        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if replacingSubjects.isEmpty {
            issues.append(.init(path: "replacingSubjects", message: "must not be empty"))
        } else if replacingSubjects.count
            > ExtensionFactProviderLimits.maximumSubjectsPerPublication {
            issues.append(.init(
                path: "replacingSubjects",
                message: "must contain at most "
                    + "\(ExtensionFactProviderLimits.maximumSubjectsPerPublication) subjects"
            ))
        }
        if facts.count > ExtensionFactProviderLimits.maximumFactsPerPublication {
            issues.append(.init(
                path: "facts",
                message: "must contain at most "
                    + "\(ExtensionFactProviderLimits.maximumFactsPerPublication) facts"
            ))
        }

        var replacementSet: Set<ExtensionFactSubject> = []
        for (index, subject) in replacingSubjects.enumerated() {
            let path = "replacingSubjects[\(index)]"
            issues.append(contentsOf: subject.validationIssues(path: path))
            if !subject.kind.isFactProviderDomain {
                issues.append(.init(
                    path: path,
                    message: "must be a repository or repositoryBranch subject"
                ))
            }
            if !replacementSet.insert(subject).inserted {
                issues.append(.init(path: path, message: "duplicates an earlier subject"))
            }
        }

        var cells: Set<Cell> = []
        var countBySubject: [ExtensionFactSubject: Int] = [:]
        for (index, fact) in facts.enumerated() {
            let path = "facts[\(index)]"
            do {
                try fact.validate()
            } catch let error as ExtensionValidationError {
                issues.append(contentsOf: error.issues.map {
                    .init(path: "\(path).\($0.path)", message: $0.message)
                })
            } catch {
                issues.append(.init(path: path, message: error.localizedDescription))
            }
            if !fact.subject.kind.isFactProviderDomain {
                issues.append(.init(
                    path: "\(path).subject",
                    message: "must be a repository or repositoryBranch subject"
                ))
            }
            if ExtensionHostFactKey.isReserved(fact.key) {
                issues.append(.init(
                    path: "\(path).key",
                    message: "uses a namespace reserved for Threading"
                ))
            }
            if !replacementSet.contains(fact.subject) {
                issues.append(.init(
                    path: "\(path).subject",
                    message: "is outside replacingSubjects"
                ))
            }
            if !cells.insert(.init(subject: fact.subject, key: fact.key)).inserted {
                issues.append(.init(
                    path: path,
                    message: "duplicates an earlier subject and fact key"
                ))
            }
            countBySubject[fact.subject, default: 0] += 1
        }
        for (subject, count) in countBySubject
        where count > ExtensionFactProviderLimits.maximumFactsPerSubject {
            issues.append(.init(
                path: "facts",
                message: "subject \(subject) has more than "
                    + "\(ExtensionFactProviderLimits.maximumFactsPerSubject) facts"
            ))
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}
