import Foundation

/// Explicit provider-documented minimums, used as update guidance rather than a model catalog.
/// Unknown models stay with the runtime; meeting a minimum does not grant account access.
struct AgentCLIModelRequirement: Equatable, Sendable {
    let model: String
    let minimumVersion: String

    static let claudeDocumentation = URL(string: "https://code.claude.com/docs/en/model-config")!
    static let claude: [AgentCLIModelRequirement] = [
        .init(model: "Fable 5.1", minimumVersion: "2.1.257"),
        .init(model: "Opus 5.5", minimumVersion: "2.1.280"),
        .init(model: "Sonnet 5.5", minimumVersion: "2.1.284")
    ]

    static func unmet(by version: String) -> [AgentCLIModelRequirement] {
        guard let installed = AgentCLIVersion(version) else { return [] }
        return claude.filter { requirement in
            guard let minimum = AgentCLIVersion(requirement.minimumVersion) else { return false }
            return installed < minimum
        }
    }

    static func enabledBy(_ update: AgentCLIUpdate) -> [AgentCLIModelRequirement] {
        guard update.id == AgentKind.claude.rawValue,
              let target = AgentCLIVersion(update.latestVersion) else { return [] }
        return unmet(by: update.installedVersion).filter {
            guard let minimum = AgentCLIVersion($0.minimumVersion) else { return false }
            return minimum <= target
        }
    }
}

extension AgentKind {
    /// Provider-owned install instructions cover package-manager installs as well as native ones.
    var cliInstallationGuide: URL {
        let address: String
        switch self {
        case .claude: address = "https://code.claude.com/docs/en/setup"
        case .codex: address = "https://developers.openai.com/codex/cli"
        case .grok: address = "https://docs.x.ai/build/overview"
        case .openCode: address = "https://opencode.ai/docs/"
        case .cursor: address = "https://cursor.com/docs/cli/installation"
        }
        return URL(string: address)!
    }
}
