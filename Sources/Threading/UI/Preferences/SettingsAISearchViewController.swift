import AppKit

// MARK: - Settings AI Search

/// What the settings pane shows for an Ask AI search: the run's progress, then the pages it
/// pointed at — each with the run's own sentence saying why, and a way in.
///
/// Like `SettingsSearchResultsViewController` it is not a settings *page*: it has no ID and is
/// never cached by id. Unlike it, its content costs a run of the user's account, so it is
/// rebuilt only when a run starts or answers — never on a keystroke.
@MainActor
final class SettingsAISearchViewController: NSViewController {

    // MARK: - Properties

    /// The page a result row was asked to open.
    var onOpen: ((String) -> Void)?

    /// What the pane is showing. Internal so the tests can render an answer without spending
    /// a run.
    enum Phase: Equatable {
        case idle
        case running(query: String, providerName: String)
        case answered(query: String, matches: [SettingsSearchResearch.Match])
        case failed(query: String, message: String)
    }

    private(set) var phase: Phase = .idle

    /// The page each row's button opens, indexed by the button's tag — rebuilt with the rows
    /// or not at all, `SettingsSearchResultsViewController`'s rule.
    private var rowPageIDs: [String] = []

    // MARK: - Public Methods

    /// Starts a run for the query and shows its progress.
    ///
    /// A click while a run is in flight is ignored rather than refused with an error: the
    /// spinner already says a run is happening, and failing the surface over an impatient
    /// second click would replace progress with an apology.
    func begin(query: String) {
        guard !SettingsSearchResearch.isRunning else { return }

        let providerName = SettingsSearchResearch.provider?.displayName ?? ""
        apply(.running(query: query, providerName: providerName))

        SettingsSearchResearch.run(query: query) { [weak self] result in
            guard let self else { return }
            // Only the run for the query on screen may answer; a stale completion after the
            // user asked again would replace the newer question's progress.
            guard case .running(let current, _) = self.phase, current == query else { return }

            switch result {
            case .success(let matches):
                self.apply(.answered(query: query, matches: matches))
            case .failure(let error):
                self.apply(.failed(query: query, message: error.message))
            }
        }
    }

    /// Internal for the tests: renders a phase without spawning anything.
    func apply(_ phase: Phase) {
        self.phase = phase
        guard isViewLoaded else { return }
        rebuild()
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        rebuild()
    }

    // MARK: - Private Methods

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        rowPageIDs = []

        let page = SettingsUI.page(sections())
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)

        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func sections() -> [NSView] {
        switch phase {
        case .idle:
            return []

        case .running(_, let providerName):
            let spinner = ThemedSpinner()
            spinner.isAnimating = true
            spinner.translatesAutoresizingMaskIntoConstraints = false

            let label = SettingsUI.note(
                L10n.format("Asking %@…", providerName),
                localizes: false
            )
            let row = NSStackView(views: [spinner, label])
            row.orientation = .horizontal
            row.spacing = Design.Spacing.small
            row.alignment = .centerY

            return [SettingsUI.section(
                nil,
                SettingsCard(rows: [SettingsUI.fullRow(row)])
            )]

        case .answered(let query, let matches):
            guard !matches.isEmpty else {
                return [SettingsUI.section(
                    nil,
                    SettingsCard(rows: [SettingsUI.fullRow(
                        SettingsUI.note(L10n.string("No settings found."))
                    )])
                )]
            }

            return [SettingsUI.section(
                L10n.format("Suggestions for “%@”", query),
                SettingsCard(rows: matches.map(row(for:))),
                localizesTitle: false
            )]

        case .failed(_, let message):
            return [SettingsUI.section(
                nil,
                SettingsCard(rows: [SettingsUI.fullRow(
                    SettingsUI.note(message, localizes: false)
                )])
            )]
        }
    }

    /// One suggested page: what it is called, the run's sentence on why, and the way in.
    private func row(for match: SettingsSearchResearch.Match) -> NSView {
        let open = SettingsUI.button(
            L10n.string("Open"),
            target: self,
            action: #selector(openClicked)
        )
        open.tag = rowPageIDs.count
        open.setAccessibilityLabel(L10n.format("Open %@", match.title))
        rowPageIDs.append(match.pageID)

        return SettingsUI.row(
            title: match.title,
            subtitle: match.reason.isEmpty ? nil : match.reason,
            control: open,
            localizes: false
        )
    }

    @objc private func openClicked(_ sender: NSControl) {
        guard rowPageIDs.indices.contains(sender.tag) else { return }
        onOpen?(rowPageIDs[sender.tag])
    }
}
