import Foundation

/// Where one project's agent sessions launch, decided in one place for every surface that asks.
///
/// **Three answers, and the third is the point.** A project with no host runs here. A project with
/// a usable host runs there. A project with a host this build cannot honour — a public build, or
/// a record that fails validation — is *refused*, never quietly run on this Mac instead: the
/// person chose where the work happens, and a launch in a different checkout on a different
/// machine is worse than one that stops and says why.
enum RemoteExecutionHostRoute: Equatable {
    case local
    case remote(ProjectExecutionHost)
    case refused(RemoteExecutionHostRefusal)

    /// Whether this build runs sessions on remote hosts at all. Developer builds only while the
    /// feature is a draft (`docs/feature-drafts/remote-execution-hosts.md`).
    static var buildSupportsRemoteHosts: Bool {
        #if DEBUG || THREADING_INTERNAL
        return true
        #else
        return false
        #endif
    }

    static func resolve(
        _ host: ProjectExecutionHost?,
        buildSupportsRemoteHosts: Bool = RemoteExecutionHostRoute.buildSupportsRemoteHosts
    ) -> RemoteExecutionHostRoute {
        guard let host else { return .local }
        guard buildSupportsRemoteHosts else { return .refused(.unsupportedBuild) }
        if let problem = host.problem { return .refused(.invalid(problem)) }
        return .remote(host)
    }
}

enum RemoteExecutionHostRefusal: Equatable {
    case unsupportedBuild
    case invalid(ProjectExecutionHost.Problem)

    var message: String {
        switch self {
        case .unsupportedBuild:
            return L10n.string(
                "This project is set to run on a remote host, which this build of Threading doesn’t support. Remove the host from the project to run it on this Mac."
            )
        case .invalid(let problem):
            return problem.message
        }
    }

    var token: String {
        switch self {
        case .unsupportedBuild: return "unsupportedBuild"
        case .invalid(let problem): return "invalidHost.\(problem.token)"
        }
    }
}

extension ProjectExecutionHost {
    /// How `ssh` addresses this host.
    var sshDestination: RemoteHostDestination {
        RemoteHostDestination(alias: destination, configFile: sshConfigFile)
    }
}

// MARK: - Presentation

/// The mark and words every surface uses for a project that runs on a remote host, so the sidebar,
/// the hover card and the menu say it the same way.
enum RemoteExecutionHostMark {
    static let symbol = "server.rack"
    static let projectMarkIdentifier = "sidebar.project.execution-host"
    static let sessionMarkIdentifier = "sidebar.session.execution-host"

    /// "Runs on pi" — the mark's accessibility label, its tooltip and the hover card line.
    static func runsOn(_ destination: String) -> String {
        L10n.format("Runs on %@", destination)
    }
}
