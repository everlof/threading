import AppKit

/// Repository publishing policy lives on the project's own menu: this is the scope a person is
/// choosing for, while the store makes the answer common to every worktree of that repository.
extension ProjectSidebarViewController {

    func projectChangeRequestEntry(for projectID: ProjectID) -> ThemedMenuEntry {
        guard let project = projectStore.project(withID: projectID) else {
            return .item(ThemedMenuItem(
                title: L10n.string("Pull Requests"),
                isEnabled: false
            ))
        }

        guard GitInfo.repositoryIdentity(for: project.folderPath) != nil else {
            return .item(ThemedMenuItem(
                title: L10n.string("Pull Requests"),
                isEnabled: false
            ))
        }

        let selected = ChangeRequestConfigurationStore.shared
            .configuration(forProjectPath: project.folderPath)
            .publishPolicy
        let choices = ChangeRequestPublishPolicy.allCases.map { policy in
            ThemedMenuEntry.item(ThemedMenuItem(
                title: policy.title,
                subtitle: policy.explanation,
                representedValue: policy.rawValue,
                isSelected: policy == selected,
                onChoose: {
                    ChangeRequestConfigurationStore.shared.setPublishPolicy(
                        policy,
                        forProjectPath: project.folderPath
                    )
                }
            ))
        }

        return .item(ThemedMenuItem(
            title: L10n.string("Pull Requests"),
            submenu: choices
        ))
    }
}
