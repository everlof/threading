import Foundation

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
