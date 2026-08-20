/// The sidebar receipt for a completed agent-tool health check.
///
/// The check itself never mutates a tool installation. Only this explicit action creates an
/// execution plan, which the window runs in a visible standalone terminal.
@MainActor
enum AgentCLIUpdateToast {
    static let identifier = "sidebar.toast.agent-cli-updates"

    static func request(
        for updates: [AgentCLIUpdate],
        runUpdates: @escaping ([AgentCLIUpdate]) -> Void
    ) -> ToastRequest {
        precondition(!updates.isEmpty, "An update toast requires at least one update")

        let message = updates.count == 1
            ? L10n.string("An agent tool update is available")
            : L10n.format("%lld agent tool updates are available", Int64(updates.count))
        let comparison = ToastComparison(
            currentTitle: L10n.string("Now"),
            targetTitle: L10n.string("Latest"),
            rows: updates.map {
                ToastComparisonRow(
                    label: $0.displayName,
                    currentValue: $0.installedVersion,
                    targetValue: $0.latestVersion
                )
            }
        )

        return ToastRequest(
            message: message,
            comparison: comparison,
            actionTitle: updates.count == 1
                ? L10n.format("Update %@", updates[0].displayName)
                : L10n.string("Update All"),
            action: { runUpdates(updates) },
            dwell: ToastDefaults.unattendedDwell,
            identifier: identifier
        )
    }
}
