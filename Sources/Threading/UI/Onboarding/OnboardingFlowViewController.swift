import AppKit

// MARK: - Onboarding Page

/// One screen of the first-launch walkthrough.
///
/// Pages are view controllers with a footer contract: the flow owns Back/Continue/skip, and a
/// page states only what its Continue says and whether it can be skipped. Work a page performs
/// on the way out (the import) happens in `pageWillContinue` — skipping bypasses it, which is
/// the entire difference between the two buttons.
@MainActor
protocol OnboardingPage: NSViewController {
    var pageTitle: String { get }
    var continueTitle: String { get }
    var skipTitle: String? { get }
    func pageWillAppear()
    func pageWillDisappear()
    func pageWillContinue()
}

extension OnboardingPage {
    var continueTitle: String { L10n.string("Continue") }
    var skipTitle: String? { nil }
    func pageWillAppear() {}
    func pageWillDisappear() {}
    func pageWillContinue() {}
}

// MARK: - Onboarding Flow

/// The walkthrough's spine: an ordered page list, a footer, and one exit.
///
/// Back is always safe — nothing any page does on the way forward is destructive, so
/// revisiting the theme grid or the account list merely shows the current state. Escape is
/// Back rather than close, because during first launch the onboarding window is the last
/// window and closing it quits the app (`applicationShouldTerminateAfterLastWindowClosed`) —
/// a deliberate behavior for abandoning setup, but not one a reflex key should reach.
final class OnboardingFlowViewController: NSViewController {

    private enum Layout {
        static let footerHeight: CGFloat = 64
    }

    private let pages: [any OnboardingPage]
    private let onFinish: () -> Void
    private(set) var pageIndex = 0

    private let contentContainer = NSView()
    private let stepLabel = NSTextField(labelWithString: "")
    private lazy var backButton = ThemedButton(
        title: L10n.string("Back"),
        target: self,
        action: #selector(goBack)
    )
    private lazy var skipButton = ThemedButton(
        title: "",
        target: self,
        action: #selector(skipPage)
    )
    private lazy var continueButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Continue"),
            target: self,
            action: #selector(advance)
        )
        button.emphasis = .primary
        button.shortcut = KeyboardShortcut(key: "\r", modifiers: [])
        button.setAccessibilityIdentifier("onboarding.continue")
        return button
    }()

    init(pages: [any OnboardingPage], onFinish: @escaping () -> Void) {
        precondition(!pages.isEmpty, "A walkthrough needs at least one page")
        self.pages = pages
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        setupViews()
        install(pageAt: 0, appearing: true)
    }

    private func setupViews() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        stepLabel.applyFont(.caption)
        stepLabel.textColor = Design.Text.secondary
        stepLabel.setAccessibilityElement(false)

        backButton.emphasis = .secondary
        skipButton.emphasis = .secondary

        let separator = SeparatorView()

        let footer = NSStackView(views: [backButton, stepLabel, skipButton, continueButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Design.Spacing.inset
        footer.setCustomSpacing(Design.Spacing.small, after: skipButton)
        footer.translatesAutoresizingMaskIntoConstraints = false

        // The step count floats between Back and the actions; the spacer is the gap.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.insertArrangedSubview(spacer, at: 2)

        view.addSubview(separator)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            separator.topAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            footer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            footer.heightAnchor.constraint(
                equalToConstant: Layout.footerHeight - Design.Radius.border
            ),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            footer.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            )
        ])
    }

    // MARK: - Paging

    var currentPage: any OnboardingPage { pages[pageIndex] }

    private func install(pageAt newIndex: Int, appearing: Bool = false) {
        if !appearing {
            let leaving = pages[pageIndex]
            leaving.pageWillDisappear()
            leaving.view.removeFromSuperview()
            leaving.removeFromParent()
        }

        pageIndex = newIndex
        let page = pages[newIndex]
        addChild(page)
        let pageView = page.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            pageView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
        ])
        page.pageWillAppear()
        refreshFooter()
    }

    private func refreshFooter() {
        let page = pages[pageIndex]
        backButton.isHidden = pageIndex == 0
        continueButton.title = page.continueTitle
        skipButton.isHidden = page.skipTitle == nil
        skipButton.title = page.skipTitle ?? ""
        stepLabel.stringValue = L10n.format(
            "%lld of %lld",
            Int64(pageIndex + 1),
            Int64(pages.count)
        )
    }

    @objc private func goBack() {
        guard pageIndex > 0 else { return }
        install(pageAt: pageIndex - 1)
    }

    /// Continue: the page performs its work, then the flow moves on — or finishes.
    @objc private func advance() {
        let page = pages[pageIndex]
        page.pageWillContinue()
        finishOrShow(pageIndex + 1)
    }

    /// Skip: the same movement without the work. Only offered where a page states a skip.
    @objc private func skipPage() {
        finishOrShow(pageIndex + 1)
    }

    private func finishOrShow(_ nextIndex: Int) {
        if nextIndex == pages.count {
            pages[pageIndex].pageWillDisappear()
            onFinish()
        } else {
            install(pageAt: nextIndex)
        }
    }

    /// Escape steps back rather than closing — see the type comment.
    override func cancelOperation(_ sender: Any?) {
        goBack()
    }
}
