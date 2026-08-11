import Foundation

public struct AgentScenarioPrivacyFinding: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case credentialLikeValue
        case privateKey
        case unnormalizedHomePath
        case forbiddenFragment
    }

    public let step: Int
    public let kind: Kind

    public init(step: Int, kind: Kind) {
        self.step = step
        self.kind = kind
    }
}

/// Conservative commit-time inspection for recorded traffic.
///
/// This is a rejection gate, not a redactor. A recorder must normalize known dynamic values while
/// it still knows their meaning. Silently rewriting an unknown token here could produce a tape
/// that passes review but no longer reproduces what the provider sent.
public enum AgentScenarioPrivacyAudit {
    public static func findings(
        in tape: AgentScenarioTape,
        forbiddenFragments: [String] = []
    ) -> [AgentScenarioPrivacyFinding] {
        tape.steps.enumerated().flatMap { index, step -> [AgentScenarioPrivacyFinding] in
            let payload: String
            switch step {
            case .expectHost(_, let value), .emitAgent(_, let value, _):
                payload = value
            case .writeFixtureFile(let path, let contents):
                payload = path + "\n" + contents
            case .checkpoint, .exit:
                return []
            }

            var kinds: [AgentScenarioPrivacyFinding.Kind] = []
            if payload.range(of: "-----BEGIN ", options: [.caseInsensitive]) != nil,
               payload.range(of: "PRIVATE KEY-----", options: [.caseInsensitive]) != nil {
                kinds.append(.privateKey)
            }
            if credentialPatterns.contains(where: {
                payload.range(of: $0, options: .regularExpression) != nil
            }) {
                kinds.append(.credentialLikeValue)
            }
            if homePathPatterns.contains(where: {
                payload.range(of: $0, options: .regularExpression) != nil
            }) {
                kinds.append(.unnormalizedHomePath)
            }
            if forbiddenFragments.contains(where: { !$0.isEmpty && payload.contains($0) }) {
                kinds.append(.forbiddenFragment)
            }
            return kinds.map { AgentScenarioPrivacyFinding(step: index, kind: $0) }
        }
    }

    private static let credentialPatterns = [
        #"(?i)bearer[ ]+[A-Za-z0-9._~+/\-]{12,}"#,
        #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{16,}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{16,}\b"#,
    ]

    /// Synthetic fixture paths use `${SCENARIO_ROOT}`. A literal user home in a committed tape is
    /// either personal data or a normalization bug, and both should stop at review.
    private static let homePathPatterns = [
        #"/Users/[A-Za-z0-9._-]+/"#,
        #"/home/[A-Za-z0-9._-]+/"#,
    ]
}
