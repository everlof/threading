import AppKit

/// A visual comparison between a stored baseline and the page as it is now.
///
/// **Its bytes live here and nowhere else, and the tab is deliberately not persisted.** The rolling
/// browser artifact cache evicts by count, so a persisted tab pointing at it would come back after a
/// relaunch naming files that had been swept — a comparison that shows two empty boxes is worse than
/// no tab at all. The plan's alternative was a comparison bundle whose lifetime is tied to the tab;
/// this is the other contract, chosen because a comparison is a moment rather than a document: the
/// page has moved on by the next launch, and re-running the comparison is one tool call. The
/// baseline itself is durable — only the *comparison* is ephemeral.
///
/// The surface is `ImageCompareView`, which already has wipe, crossfade, difference and
/// side-by-side over one shared scrub. What this adds is the header: what the numbers were, a way to
/// look at the computed diff map instead of the pair, and the approve gesture.
///
/// **Accept New Revision is user-only.** It is the Percy and Chromatic approve step: a baseline is a
/// claim about intent, and an agent that both captured the baseline and decided the new render
/// matched it would assert nothing at all.
@MainActor
final class BrowserComparisonViewController: NSViewController {

    // MARK: - Content

    /// What a caller may offer the user to approve.
    ///
    /// Absent for a comparison against a loose PNG path, and for a comparison against a baseline
    /// this build cannot write to — there is nothing to approve into.
    struct Approval: Equatable {
        let projectID: ProjectID
        let baselineID: BrowserBaselineID
        let baselineName: String
        let capturePNG: Data
        let conditions: BrowserBaselineConditions
    }

    struct Content {
        let baselineTitle: String
        let actualTitle: String
        let baselinePNG: Data
        let actualPNG: Data
        let diffPNG: Data?
        /// One line of plain numbers, in the app's words.
        let summary: String
        let approval: Approval?
    }

    // MARK: - Properties

    let sessionID: SessionID
    private(set) var content: Content

    /// Answered when the user approves the current capture as a new revision. The controller does
    /// not write to the store itself: the pane does not own baselines, and the caller that made the
    /// comparison is the one that knows how to record one.
    var onAcceptRevision: ((Approval) -> Void)?

    private enum View: Int {
        case pair
        case diff
    }

    private var shownView: View = .pair

    private lazy var compareView: ImageCompareView = {
        let view = ImageCompareView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var summaryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var viewPicker: ThemedSegmentedControl = {
        let control = ThemedSegmentedControl()
        control.onSelect = { [weak self] index in
            self?.shownView = View(rawValue: index) ?? .pair
            self?.applyContent()
        }
        return control
    }()

    private lazy var acceptButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Accept New Revision"),
            target: self,
            action: #selector(acceptRevision)
        )
        button.toolTip = L10n.string(
            "Record the current capture as this baseline’s new approved revision"
        )
        return button
    }()

    /// The picker and the summary at one edge, the actions at the other.
    ///
    /// A plain stack rather than a control row, and the reason is the pane's protected 260pt
    /// minimum. Five controls stand here — the picker, the compare surface's mode chip, the
    /// summary, Accept New Revision and the expand button — and only the summary can give ground.
    /// A row that springs to a content-driven minimum therefore overflows the pane instead of
    /// letting the one compressible member compress, which is exactly what
    /// `testTheComparisonSurvivesTheNarrowPane` catches.
    private lazy var headerRow: NSStackView = {
        let row = NSStackView(views: [viewPicker, summaryLabel, acceptButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.tight
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }()

    private lazy var scrollView: ThemedScrollView = {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clip
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }()

    private lazy var stack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )
        return stack
    }()

    private var compareHeightConstraint: NSLayoutConstraint?

    // MARK: - Initialization

    init(sessionID: SessionID, content: Content) {
        self.sessionID = sessionID
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(headerRow)
        view.addSubview(scrollView)
        stack.addArrangedSubview(compareView)

        let height = compareView.heightAnchor.constraint(equalToConstant: 0)
        compareHeightConstraint = height

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Design.Spacing.inset
            ),
            headerRow.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Design.Spacing.inset
            ),
            headerRow.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Design.Spacing.inset
            ),
            scrollView.topAnchor.constraint(
                equalTo: headerRow.bottomAnchor, constant: Design.Spacing.small
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            compareView.leadingAnchor.constraint(
                equalTo: stack.leadingAnchor, constant: Design.Spacing.inset
            ),
            compareView.trailingAnchor.constraint(
                equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset
            ),
            height
        ])

        // The compare surface's own controls sit in this header, above the scroll view, for the
        // reason the Compare tab already found: under a tall screenshot they scroll away exactly
        // when a reader has got far enough down it to want a different mode.
        let controls = compareView.hostControls()
        headerRow.insertArrangedSubview(controls.mode, at: 1)
        headerRow.addArrangedSubview(controls.expansion)
        compareView.onModeChange = { [weak self] _ in self?.updateCompareHeight() }

        applyContent()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateCompareHeight()
    }

    // MARK: - Public Methods

    /// Replaces what the tab shows, for a second comparison against the same baseline.
    func update(_ content: Content) {
        self.content = content
        guard isViewLoaded else { return }
        applyContent()
    }

    // MARK: - Private Methods

    private func applyContent() {
        summaryLabel.stringValue = content.summary
        acceptButton.isHidden = content.approval == nil
        viewPicker.configure(
            titles: content.diffPNG == nil
                ? [L10n.string("Baseline and current")]
                : [L10n.string("Baseline and current"), L10n.string("Difference")],
            selectedIndex: content.diffPNG == nil ? 0 : shownView.rawValue
        )

        switch shownView {
        case .pair:
            compareView.configure(
                old: NSImage(data: content.baselinePNG).map {
                    .init(image: $0, title: content.baselineTitle)
                },
                new: NSImage(data: content.actualPNG).map {
                    .init(image: $0, title: content.actualTitle)
                }
            )
        case .diff:
            // One side on purpose. The diff map is already a comparison; wiping it against
            // something else would be a comparison of a comparison.
            compareView.configure(
                old: nil,
                new: content.diffPNG.flatMap(NSImage.init(data:)).map {
                    .init(image: $0, title: L10n.string("Difference"))
                }
            )
        }
        updateCompareHeight()
    }

    /// The height the canvas wants at the width the pane currently has. Written only when it
    /// changes: this runs on every layout pass, and assigning a constant marks the view dirty.
    private func updateCompareHeight() {
        guard let compareHeightConstraint else { return }
        let available = max(view.bounds.width - Design.Spacing.inset * 2, 1)
        let height = compareView.preferredHeight(forWidth: available)
        guard abs(compareHeightConstraint.constant - height) > 0.5 else { return }
        compareHeightConstraint.constant = height
    }

    @objc private func acceptRevision() {
        guard let approval = content.approval else {
            NSSound.beep()
            return
        }
        onAcceptRevision?(approval)
    }
}
