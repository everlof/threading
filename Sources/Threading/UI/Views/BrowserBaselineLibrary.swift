import AppKit

// MARK: - Capture

/// The user's own half of the baseline workflow: Save as Baseline… and the library it writes into.
///
/// **Capture is not a nicety here, it is the load-bearing half.** "This is what correct looks like"
/// is a judgment, and the judgment is the user's — an agent that both captures the baseline and
/// decides whether the new render matches it asserts nothing. Some states are also only reachable
/// by a person: a password field refuses agent typing by design, so anything behind a sign-in, a
/// passkey or a 2FA prompt is structurally user-capturable only.
///
/// **One capture path.** This goes through `BrowserViewController.captureBaseline`, the same
/// normalized pipeline `browser_screenshot` and `browser_visual_compare` use — not the bare
/// `takeSnapshot` the visible-page screenshot exporter uses. Two paths would mean a user baseline
/// and an agent comparison quietly disagreeing about what a pixel is.
@MainActor
enum BrowserBaselineUI {

    /// Asks for a name, captures, and stores. The order matters: asking first means the picture is
    /// taken of the page as it is *after* the sheet closes, which is the page the user was looking
    /// at rather than one with a sheet over it.
    static func captureBaseline(
        from browser: BrowserViewController,
        sessionID: SessionID,
        projects: ProjectStore = .shared,
        store: BrowserBaselineStore = .shared
    ) {
        guard let project = projects.project(forSessionID: sessionID) else {
            present(
                message: L10n.string("This Chat Has No Project"),
                detail: L10n.string(
                    "Visual baselines belong to a project, so a chat outside one has nowhere to keep them."
                )
            )
            return
        }
        guard browser.currentURL != nil else {
            present(
                message: L10n.string("Nothing to Capture"),
                detail: L10n.string("Load a page in this browser first.")
            )
            return
        }

        let suggested = browser.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = TextPromptAlert.ask(TextPromptRequest(
            title: L10n.string("Save as Baseline"),
            message: L10n.string(
                "The picture is stored with this project, under the name you give it. The agent can compare the page against it later."
            ),
            confirmTitle: L10n.string("Save"),
            current: suggested?.isEmpty == false ? suggested! : "",
            placeholder: L10n.string("Signed-in dashboard")
        ))
        guard case .text(let name)? = answer else { return }

        Task { @MainActor in
            let capture: BrowserBaselineCapture
            do {
                capture = try await browser.captureBaseline(
                    kind: .viewport,
                    includesAttribution: true
                )
            } catch {
                present(
                    message: L10n.string("Couldn’t Capture This Baseline"),
                    detail: error.localizedDescription
                )
                return
            }

            do {
                _ = try store.createBaseline(
                    BrowserBaselineCaptureRequest(
                        name: name,
                        pngData: capture.pngData,
                        conditions: capture.conditions,
                        provenance: .userCaptured,
                        // A private tab holds authenticated pixels. The record is the user's either
                        // way; letting the agent read it is a separate, deliberate choice they make
                        // in the library.
                        isAgentReadable: browser.contextKind == .shared,
                        sourceSessionID: sessionID,
                        attributionJSON: capture.attribution.flatMap {
                            AgentToolCoordinator.encodeAttribution($0)
                        }
                    ),
                    in: project.id
                )
            } catch {
                present(
                    message: L10n.string("Couldn’t Save This Baseline"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Opens the project's library over the browser.
    static func showLibrary(
        from browser: BrowserViewController,
        sessionID: SessionID,
        projects: ProjectStore = .shared,
        store: BrowserBaselineStore = .shared
    ) {
        guard let project = projects.project(forSessionID: sessionID) else {
            present(
                message: L10n.string("This Chat Has No Project"),
                detail: L10n.string(
                    "Visual baselines belong to a project, so a chat outside one has nowhere to keep them."
                )
            )
            return
        }
        let library = BrowserBaselineLibraryViewController(
            projectID: project.id,
            projectName: project.name,
            store: store
        )
        library.onDone = { [weak browser, weak library] in
            guard let browser, let library else { return }
            browser.dismiss(library)
        }
        browser.presentAsSheet(library)
    }

    /// Offers the project's baselines to hold over the live page, or takes the current one down.
    ///
    /// A menu rather than a mode toggle, because "which approved picture" is the question — the
    /// overlay itself has no meaning without one.
    static func presentOverlayPicker(
        from browser: BrowserViewController,
        anchor: NSView,
        sessionID: SessionID,
        projects: ProjectStore = .shared,
        store: BrowserBaselineStore = .shared
    ) -> AnyObject? {
        guard let project = projects.project(forSessionID: sessionID) else {
            present(
                message: L10n.string("This Chat Has No Project"),
                detail: L10n.string(
                    "Visual baselines belong to a project, so a chat outside one has nowhere to keep them."
                )
            )
            return nil
        }

        var entries: [ThemedMenuEntry] = []
        if browser.isShowingBaselineOverlay {
            // Both ways of holding a picture against a page, in the menu that put it there. One
            // scrub position is shared between them, like the compare surface's, so switching keeps
            // the user's place.
            for mode in BrowserBaselineOverlayMode.allCases {
                entries.append(.item(ThemedMenuItem(
                    title: mode.localizedName,
                    isSelected: browser.baselineOverlayMode == mode,
                    onChoose: { [weak browser] in browser?.baselineOverlayMode = mode }
                )))
            }
            entries.append(.separator)
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Stop Holding a Baseline"),
                onChoose: { [weak browser] in browser?.hideBaselineOverlay() }
            )))
            entries.append(.separator)
        }

        let baselines = store.baselines(for: project.id)
        if baselines.isEmpty {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("No baselines in this project yet"),
                isEnabled: false
            )))
        }
        for baseline in baselines.prefix(BrowserBaselineDefaults.maximumListedBaselines) {
            guard let revision = baseline.activeRevision else { continue }
            entries.append(.item(ThemedMenuItem(
                title: baseline.name,
                subtitle: L10n.format(
                    "%@ · %lld×%lld",
                    revision.conditions.captureKind.rawValue,
                    Int64(revision.conditions.pixelWidth),
                    Int64(revision.conditions.pixelHeight)
                ),
                onChoose: { [weak browser] in
                    guard let browser,
                          let image = NSImage(contentsOf: store.pngURL(
                              forRevision: revision.id,
                              of: baseline.id,
                              in: project.id
                          )) else { return }
                    browser.showBaselineOverlay(
                        image: image,
                        name: baseline.name,
                        captureKind: revision.conditions.captureKind,
                        capturedScroll: CGPoint(
                            x: revision.conditions.scrollX,
                            y: revision.conditions.scrollY
                        ),
                        captureSize: CGSize(
                            width: revision.conditions.pixelWidth,
                            height: revision.conditions.pixelHeight
                        )
                    )
                }
            )))
        }

        return ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 260),
            from: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: {}
        )
    }

    private static func present(message: String, detail: String) {
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

// MARK: - Library

/// The project's baselines, as a list the user can manage.
///
/// The one screen where a baseline's *provenance* and its *agent readability* are visibly two
/// different things: a record the user captured in a private tab is theirs, exists, and is still not
/// something the agent may read until they say so here.
@MainActor
final class BrowserBaselineLibraryViewController: NSViewController {

    // MARK: - Properties

    let projectID: ProjectID
    private let projectName: String
    private let store: BrowserBaselineStore

    var onDone: (() -> Void)?

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: L10n.string("Visual Baselines"))
        label.applyFont(.subheading)
        label.textColor = Design.Text.label
        return label
    }()

    private lazy var subtitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        return label
    }()

    private lazy var doneButton = ThemedButton(
        title: L10n.string("Done"),
        target: self,
        action: #selector(done)
    )

    private lazy var rows: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var scrollView: ThemedScrollView = {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clip
        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }()

    private let events = AppEventObservations()

    // MARK: - Initialization

    init(projectID: ProjectID, projectName: String, store: BrowserBaselineStore = .shared) {
        self.projectID = projectID
        self.projectName = projectName
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = ThemedSurfaceView()
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = NSStackView(views: [titleLabel, doneButton])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Design.Spacing.medium
        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        view.addSubview(header)
        view.addSubview(subtitleLabel)
        view.addSubview(scrollView)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: BrowserBaselineLibraryDefaults.width),
            view.heightAnchor.constraint(equalToConstant: BrowserBaselineLibraryDefaults.height),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            header.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Design.Spacing.pane
            ),
            header.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Design.Spacing.pane
            ),
            subtitleLabel.topAnchor.constraint(
                equalTo: header.bottomAnchor, constant: Design.Spacing.tight
            ),
            subtitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: subtitleLabel.bottomAnchor, constant: Design.Spacing.medium
            ),
            scrollView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -Design.Spacing.pane
            ),
            rows.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        events.observe(BrowserBaselinesDidChange.self) { [weak self] event in
            guard event.projectID == self?.projectID else { return }
            self?.reload()
        }
        reload()
    }

    // MARK: - Private Methods

    /// Rebuilt rather than diffed. The list is capped at a couple of hundred rows, it changes only
    /// when someone acts on it, and a rebuild cannot leave a row wired to a record that has gone.
    private func reload() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let baselines = store.baselines(for: projectID)
        var summary = L10n.format(
            "%lld baselines in %@",
            Int64(baselines.count),
            projectName
        )
        if store.isWriteBlocked {
            summary += " · " + L10n.string(
                "Storage is read-only because damaged data could not be set aside."
            )
        }
        if store.unsupportedCount(for: projectID) > 0 {
            summary += " · " + L10n.format(
                "%lld were written by a newer version and were left untouched.",
                Int64(store.unsupportedCount(for: projectID))
            )
        }
        subtitleLabel.stringValue = summary

        guard !baselines.isEmpty else {
            let empty = NSTextField(
                wrappingLabelWithString: L10n.string(
                    "Nothing here yet. Use Save as Baseline in Browser Options to keep a picture of a page you have decided is correct."
                )
            )
            empty.applyFont(.body)
            empty.textColor = Design.Text.tertiary
            empty.translatesAutoresizingMaskIntoConstraints = false
            rows.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            return
        }

        for baseline in baselines {
            let row = makeRow(for: baseline)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func makeRow(for baseline: BrowserBaseline) -> NSView {
        let surface = ThemedSurfaceView()
        surface.applySurface(fill: Design.Surface.panel, radius: .panel, pattern: .none)
        surface.translatesAutoresizingMaskIntoConstraints = false

        let thumbnail = ThemedImagePreview()
        if let revision = baseline.activeRevision {
            let url = store.pngURL(
                forRevision: revision.id,
                of: baseline.id,
                in: projectID
            )
            thumbnail.image = NSImage(contentsOf: url)
            thumbnail.fileURL = url
        }

        let name = NSTextField(labelWithString: baseline.name)
        name.applyFont(.emphasizedBody)
        name.textColor = Design.Text.label
        name.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(wrappingLabelWithString: describe(baseline))
        detail.applyFont(.caption)
        detail.textColor = Design.Text.secondary
        detail.maximumNumberOfLines = 3

        // Every control carries the record's *id*, never its index in the list: rows are rebuilt
        // whenever anything changes, and an index would quietly come to mean a different baseline.
        // A record that has gone by the time a control fires simply resolves to nothing.
        let id = baseline.id
        let readable = ThemedCheckbox(
            title: L10n.string("Agent can read this"),
            state: baseline.isAgentReadable ? .on : .off,
            accessibility: L10n.string("Agent can read this baseline")
        ) { [weak self] state in
            self?.setReadable(state == .on, for: id)
        }
        readable.toolTip = L10n.string(
            "Private-tab captures start user-only, because provenance is not permission to disclose signed-in pixels."
        )

        let rename = ThemedButton(
            title: L10n.string("Rename…"),
            target: self,
            action: #selector(renameClicked(_:))
        )
        let reveal = ThemedButton(
            title: L10n.string("Reveal in Finder"),
            target: self,
            action: #selector(revealClicked(_:))
        )
        let delete = ThemedButton(
            title: L10n.string("Delete"),
            target: self,
            action: #selector(deleteClicked(_:))
        )
        for button in [rename, reveal, delete] {
            button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        }

        let actions = NSStackView(views: [readable, rename, reveal, delete])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let text = NSStackView(views: [name, detail, actions])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.tight
        text.translatesAutoresizingMaskIntoConstraints = false

        surface.addSubview(thumbnail)
        surface.addSubview(text)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(
                equalTo: surface.leadingAnchor, constant: Design.Spacing.medium
            ),
            thumbnail.topAnchor.constraint(
                equalTo: surface.topAnchor, constant: Design.Spacing.medium
            ),
            thumbnail.widthAnchor.constraint(
                equalToConstant: BrowserBaselineLibraryDefaults.thumbnailWidth
            ),
            thumbnail.heightAnchor.constraint(
                equalToConstant: BrowserBaselineLibraryDefaults.thumbnailHeight
            ),
            text.leadingAnchor.constraint(
                equalTo: thumbnail.trailingAnchor, constant: Design.Spacing.medium
            ),
            text.topAnchor.constraint(equalTo: surface.topAnchor, constant: Design.Spacing.medium),
            text.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor, constant: -Design.Spacing.medium
            ),
            surface.bottomAnchor.constraint(
                greaterThanOrEqualTo: text.bottomAnchor, constant: Design.Spacing.medium
            ),
            surface.bottomAnchor.constraint(
                greaterThanOrEqualTo: thumbnail.bottomAnchor, constant: Design.Spacing.medium
            )
        ])
        return surface
    }

    /// What the row says about a record. Everything here came from a page, so it is shown as the
    /// app's own summary rather than as anything the page authored being repeated verbatim as fact.
    private func describe(_ baseline: BrowserBaseline) -> String {
        guard let revision = baseline.activeRevision else {
            return L10n.string("No stored revision.")
        }
        var parts = [BrowserURLRedactor.redact(revision.conditions.url)]
        parts.append(L10n.format(
            "%@ · %lld×%lld · %@ · zoom %lld%%",
            revision.conditions.captureKind.rawValue,
            Int64(revision.conditions.pixelWidth),
            Int64(revision.conditions.pixelHeight),
            revision.conditions.colorScheme,
            Int64((revision.conditions.pageZoom * 100).rounded())
        ))
        parts.append(L10n.format(
            "%@ · %lld revisions · %@",
            baseline.provenance == .userCaptured
                ? L10n.string("You captured this")
                : L10n.string("An agent captured this"),
            Int64(baseline.revisions.count),
            Self.timestamp.string(from: revision.capturedAt)
        ))
        if revision.conditions.browserContext == BrowserContextKind.private.rawValue {
            parts.append(L10n.string("Captured in a private tab."))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Actions

    @objc private func done() {
        onDone?()
    }

    private func setReadable(_ isReadable: Bool, for id: BrowserBaselineID) {
        do {
            _ = try store.setAgentReadable(isReadable, for: id, in: projectID)
        } catch {
            report(error)
        }
    }

    @objc private func renameClicked(_ sender: Any?) {
        guard let id = identifiedBaseline(sender) else { return }
        rename(id)
    }

    @objc private func revealClicked(_ sender: Any?) {
        guard let id = identifiedBaseline(sender) else { return }
        reveal(id)
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let id = identifiedBaseline(sender) else { return }
        delete(id)
    }

    private func identifiedBaseline(_ sender: Any?) -> BrowserBaselineID? {
        guard let view = sender as? NSView, let raw = view.identifier?.rawValue else { return nil }
        return BrowserBaselineID(uuidString: raw)
    }

    private func rename(_ id: BrowserBaselineID) {
        guard let baseline = store.baseline(id: id, in: projectID) else { return }
        let answer = TextPromptAlert.ask(TextPromptRequest(
            title: L10n.string("Rename Baseline"),
            confirmTitle: L10n.string("Rename"),
            current: baseline.name
        ))
        guard case .text(let name)? = answer else { return }
        do {
            _ = try store.rename(baseline.id, in: projectID, to: name)
        } catch {
            report(error)
        }
    }

    private func reveal(_ id: BrowserBaselineID) {
        guard let baseline = store.baseline(id: id, in: projectID),
              let revision = baseline.activeRevision else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            store.pngURL(forRevision: revision.id, of: baseline.id, in: projectID)
        ])
    }

    private func delete(_ id: BrowserBaselineID) {
        guard let baseline = store.baseline(id: id, in: projectID) else { return }
        let request = ConfirmationRequest(
            prompt: .removeBrowserBaseline,
            title: L10n.format("Delete “%@”?", baseline.name),
            message: L10n.format(
                "Its %lld stored revisions are removed from this project. Nothing else is affected.",
                Int64(baseline.revisions.count)
            ),
            confirmTitle: L10n.string("Delete")
        )
        guard ConfirmationAlert.ask(request) else { return }
        do {
            try store.delete(baseline.id, in: projectID)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let alert = ThemedAlert(error: error)
        alert.messageText = L10n.string("Couldn’t Change This Baseline")
        alert.runModal()
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Defaults

enum BrowserBaselineLibraryDefaults {
    static let width: CGFloat = 620
    static let height: CGFloat = 480
    static let thumbnailWidth: CGFloat = 96
    static let thumbnailHeight: CGFloat = 64
}
