import AppKit

enum SettingsSearchDefaults {
    /// Between the terms on a result's second line. A middle dot rather than a comma: the terms
    /// are separate labels, several of which contain commas' worth of words already.
    static let termSeparator = " · "
}

// MARK: - Settings Search Results

/// What the settings pane shows while a search is running: every section the query landed in,
/// each with the terms it landed on and a way into the page.
///
/// The sidebar narrows to the same set, so this could have been left out — and was, which is
/// exactly what made searching feel like nothing had happened. Narrowing a list of fifteen
/// names to two is a change most of the window does not report: the pane goes on showing
/// whichever page was open before the query, so the one surface the reader is looking at says
/// nothing about what was found. This is that answer, in the place their eyes already are.
///
/// It is not a settings *page*: it has no ID, is never cached, and is rebuilt from the query on
/// every keystroke — there is no state in it worth keeping between two different searches.
@MainActor
final class SettingsSearchResultsViewController: NSViewController {

    // MARK: - Properties

    /// The page a result row was asked to open.
    var onOpen: ((String) -> Void)?

    private var query: String
    private var matches: [SettingsSearchMatch]
    /// The page each row's button opens, indexed by the button's tag.
    ///
    /// The tag indexes *this* rather than `SettingsPages.all`: an extension starting or stopping
    /// re-numbers the catalogue, and a button holding a stale index into it would quietly open
    /// the wrong page. The rows and this list are rebuilt together or not at all.
    private var rowPageIDs: [String] = []

    // MARK: - Initialization

    init(query: String, matches: [SettingsSearchMatch]) {
        self.query = query
        self.matches = matches
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Restates the page for a new query. The pane keeps one results controller across a whole
    /// typing run, so the reader's scroll position and the pane's own transition survive the
    /// letters rather than restarting at each one.
    func update(query: String, matches: [SettingsSearchMatch]) {
        guard query != self.query || matches != self.matches else { return }
        self.query = query
        self.matches = matches
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
        guard !matches.isEmpty else {
            return [SettingsUI.section(
                nil,
                SettingsCard(rows: [SettingsUI.fullRow(
                    SettingsUI.note(L10n.string("No settings found."))
                )])
            )]
        }

        return [SettingsUI.section(
            L10n.format("Matches for “%@”", query),
            SettingsCard(rows: matches.map(row(for:))),
            localizesTitle: false
        )]
    }

    /// One matched section: what it is called, what the query touched inside it, and the way in.
    ///
    /// The terms are the row's *subtitle* rather than rows of their own, because a term does not
    /// name a destination — nothing here can scroll a page to the word "mute". Saying which
    /// words matched is the useful half; pretending each is separately reachable is not.
    private func row(for match: SettingsSearchMatch) -> NSView {
        let open = SettingsUI.button(
            L10n.string("Open"),
            target: self,
            action: #selector(openClicked)
        )
        open.tag = rowPageIDs.count
        open.setAccessibilityLabel(L10n.format("Open %@", match.title))
        rowPageIDs.append(match.pageID)

        // No subtitle when the query only touched the section's own name: an empty second line
        // would be a row explaining that it has nothing to explain.
        return SettingsUI.row(
            title: match.title,
            subtitle: match.terms.isEmpty
                ? nil
                : match.terms.joined(separator: SettingsSearchDefaults.termSeparator),
            control: open,
            localizes: false
        )
    }

    @objc private func openClicked(_ sender: NSControl) {
        guard rowPageIDs.indices.contains(sender.tag) else { return }
        onOpen?(rowPageIDs[sender.tag])
    }
}
