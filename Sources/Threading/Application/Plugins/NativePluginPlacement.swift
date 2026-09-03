import Foundation
import ThreadingDomain

/// What the host is willing to tell a plugin about where it has been put.
///
/// A value type with no store and no UI, for the same reason `NativePluginApprovals` is one: the
/// interesting part is the mapping, and the mapping should be testable without loading a bundle or
/// ordering a window.
///
/// The plugin contract hands over a `[String: String]`, deliberately: a plugin never receives a
/// session, a project, a store or a window, so anything it needs is *named* here first and becomes
/// part of the versioned surface. This type is where those names are decided, once, rather than
/// being spelled at the call site and drifting.
///
/// **Naming a folder is not granting access to it.** A native plugin is unsandboxed and could
/// enumerate the disk regardless; what it cannot do is guess *which* checkout the user is looking
/// at. So this answers "where am I", not "what may I touch", and it is the difference between a
/// project-scoped plugin and one that has to ask the user to find its own files.
struct NativePluginPlacement: Equatable {

    /// Names of the arguments, so a plugin author and the host agree on spelling in one place.
    enum Key {
        static let sessionID = "sessionID"
        static let projectID = "projectID"
        static let projectName = "projectName"
        static let checkoutPath = "checkoutPath"
    }

    var sessionID: SessionID?
    var projectID: ProjectID?
    var projectName: String?

    /// The folder the session actually executes in, which differs from the project's own folder
    /// exactly when the session opted into a managed workspace. A plugin that used the project
    /// folder instead would quietly read the wrong tree for any session working in a draft
    /// worktree, which is the sort of bug that looks like stale data rather than a wrong path.
    var checkoutPath: String?

    init(
        sessionID: SessionID? = nil,
        projectID: ProjectID? = nil,
        projectName: String? = nil,
        checkoutPath: String? = nil
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.projectName = projectName
        self.checkoutPath = checkoutPath
    }

    /// The narrow dictionary the plugin receives.
    ///
    /// An absent value is an absent key rather than an empty string: a plugin asking
    /// `argument("checkoutPath")` should get `nil` when there is no checkout, not `""`, which
    /// every path API would happily interpret as somewhere.
    var arguments: [String: String] {
        var arguments: [String: String] = [:]
        if let sessionID { arguments[Key.sessionID] = sessionID.uuidString }
        if let projectID { arguments[Key.projectID] = projectID.uuidString }
        if let projectName, !projectName.isEmpty { arguments[Key.projectName] = projectName }
        if let checkoutPath, !checkoutPath.isEmpty { arguments[Key.checkoutPath] = checkoutPath }
        return arguments
    }
}
