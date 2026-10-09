import Foundation

// Host environment resolution stays outside the portable command-plan value.
extension AgentLaunchPlan {
    /// The environment this plan's child is spawned with: the shared one, then this plan's own
    /// entries on top, then its credentials.
    func launchEnvironment() -> [String: String] {
#if os(Linux)
        var environment = baseEnvironment ?? AgentEnvironment.removingInheritedIdentity(from: ProcessInfo.processInfo.environment)
#else
        var environment = baseEnvironment ?? AgentEnvironment.launchEnvironment()
#endif
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return credentialEnvironment.applied(to: environment)
    }
}
