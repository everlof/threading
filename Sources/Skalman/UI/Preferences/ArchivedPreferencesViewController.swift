import AppKit

/// Archived-sessions preferences: the conversations filed away out of the sidebar.
///
/// Archiving keeps a session's conversation but takes it off the sidebar, so this is where the
/// archived ones live — to be restored to the sidebar or deleted for good. Nothing is created
/// here; the list only reflects what has been archived.
///
/// Built from the settings kit (`SettingsUI`, `SettingsCard`, `FlatButton`) rather than an
/// `NSTableView`: each archived conversation is a flat card row carrying its own Restore and
/// Delete actions, so there is no selection state and no footer button bar.
final class ArchivedPreferencesViewController: NSViewController {

    // MARK: - Properties

    private var rows: [(project: Project, session: AgentSession)] = []
    private let appEvents = AppEventObservations()

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.reload()
        }
    }

    // MARK: - Build

    /// Rebuilds the whole page from the current archived list. Cheap enough to do wholesale:
    /// the list is short, and a fresh build keeps each row's button tags in step with `rows`.
    private func reload() {
        rows = ProjectStore.shared.archivedSessions()

        view.subviews.forEach { $0.removeFromSuperview() }

        var sections: [NSView] = [
            SettingsUI.heading("Archived"),
            SettingsUI.note(ArchivedPreferencesStrings.explanation)
        ]

        if rows.isEmpty {
            sections.append(SettingsUI.note(ArchivedPreferencesStrings.empty))
        } else {
            let rowViews = rows.enumerated().map { index, entry in
                makeRow(entry: entry, index: index)
            }
            sections.append(SettingsUI.section(nil, SettingsCard(rows: rowViews)))
        }

        let page = SettingsUI.page(sections)
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// One archived conversation: a title over a "<project> · <archived when>" caption, with
    /// trailing Restore and Delete actions. The buttons carry the row's index in their tag, so
    /// an action maps straight back to its session in `rows`.
    private func makeRow(entry: (project: Project, session: AgentSession), index: Int) -> NSView {
        let titleLabel = NSTextField(labelWithString: entry.session.displayTitle)
        titleLabel.font = Design.Typography.body()
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let when = Self.relativeDate.localizedString(for: entry.session.lastActiveAt, relativeTo: Date())
        let captionLabel = NSTextField(labelWithString: "\(entry.project.name) · \(when)")
        captionLabel.font = Design.Typography.subheading()
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, captionLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let restore = SettingsUI.button("Restore", target: self, action: #selector(restoreSession(_:)))
        restore.tag = index
        restore.setContentHuggingPriority(.required, for: .horizontal)

        let delete = SettingsUI.button("Delete…", target: self, action: #selector(deleteSession(_:)))
        delete.tag = index
        delete.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [labels, spacer, restore, delete])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small

        return padded(row)
    }

    /// Wraps a row's content with the card's standard insets and minimum height.
    private func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.Spacing.medium),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.Spacing.inset),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsUIDefaults.rowHeight)
        ])

        return container
    }

    // MARK: - Actions

    private func session(for sender: NSButton) -> (project: Project, session: AgentSession)? {
        guard sender.tag >= 0, sender.tag < rows.count else { return nil }
        return rows[sender.tag]
    }

    /// Puts the session back on the sidebar, where selecting it resumes the conversation.
    @objc private func restoreSession(_ sender: NSButton) {
        guard let entry = session(for: sender) else { return }
        ProjectStore.shared.setArchived(false, for: entry.session.id)
        reload()
    }

    /// Deletes the session for good, after confirming — its conversation cannot be recovered
    /// from the sidebar afterwards, though the CLI's own transcript on disk is untouched.
    @objc private func deleteSession(_ sender: NSButton) {
        guard let entry = session(for: sender) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(entry.session.displayTitle)\"?"
        alert.informativeText = "It is removed from Skalman. The saved conversation on disk is not deleted, "
            + "so it could still be imported again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        AgentRuntime.shared.discard(sessionID: entry.session.id)
        ProjectStore.shared.removeSession(id: entry.session.id)
        reload()
    }
}

// MARK: - Archived Preferences Strings

private enum ArchivedPreferencesStrings {
    static let explanation = """
        Archived conversations are kept but taken off the sidebar. Restore one to put it back \
        where selecting it resumes the conversation, or delete it to remove it from Skalman.
        """
    static let empty = "No archived conversations."
}
