import AppKit

/// The software-update interface: every stage of `UpdateUserDriver`'s flow as a themed sheet
/// on the main window.
///
/// The design is `releasing.md`'s mapping made concrete — the alert is a `ThemedAlert`,
/// download and extraction are a `ThemedProgressBar`, and release notes render as native
/// Markdown in the sheet itself rather than in the display panel's web view. That last point
/// deviates from the doc's original sketch deliberately: the display panel belongs to a
/// session, an update belongs to the app, and Threading's own feed embeds Markdown
/// (the `scripts/generate_appcast.sh` contract), which `MarkdownView` already draws in the
/// current theme.
///
/// Presentation rules, in order of what they protect:
///
/// - **A scheduled check never interrupts.** An update found in the background waits until
///   the app is active and has a window before its sheet appears; a person mid-keystroke in
///   another app is not asked anything. A user-initiated check answers on the spot.
/// - **The checking sheet is late on purpose.** Most checks answer in under a second; the
///   "Checking for Updates" sheet appears only after `checkingSheetDelay`, so the common case
///   is menu click then verdict with nothing flashing in between.
/// - **A narration-only stage needs a window; an answer-needing stage waits for one.** With
///   no window to sheet on, progress stages simply do not draw, and acknowledgement-only
///   verdicts acknowledge immediately, because the modal fallback would park a nested run
///   loop inside a Sparkle callback that later stages still need to reach.
@MainActor
final class UpdatePresenter: UpdatePresenting {

    private enum Defaults {
        /// How long a user-initiated check may run before it earns a sheet.
        static let checkingSheetDelay: TimeInterval = 0.6
        static let notesWidth: CGFloat = 460
        static let notesHeight: CGFloat = 220
        static let progressWidth: CGFloat = 360
    }

    private let hostWindow: () -> NSWindow?
    private let appEvents = AppEventObservations()

    private var alert: ThemedAlert?
    private var notesAccessory: UpdateReleaseNotesAccessoryView?
    private var progressAccessory: UpdateProgressAccessoryView?
    private var checkingSheetTask: Task<Void, Never>?

    /// A found-update presentation waiting for the app to become active with a window.
    private var deferredPresentation: (() -> Void)?

    init(hostWindow: @escaping () -> NSWindow? = { NSApp.mainWindow ?? NSApp.keyWindow }) {
        self.hostWindow = hostWindow
        appEvents.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.presentDeferredIfPossible()
        }
    }

    // MARK: - UpdatePresenting

    func showCheckingForUpdates(cancel: @escaping () -> Void) {
        checkingSheetTask?.cancel()
        checkingSheetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Defaults.checkingSheetDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.presentCheckingSheet(cancel: cancel)
        }
    }

    func showUpdateFound(
        _ info: UpdateVersionInfo,
        origin: UpdateCheckOrigin,
        respond: @escaping (UpdateChoice) -> Void
    ) {
        let respondOnce = Self.once(respond)
        let present: () -> Void = { [weak self] in
            self?.presentFoundSheet(info, respond: respondOnce)
        }
        if origin == .scheduled, !NSApp.isActive || hostWindow() == nil {
            deferredPresentation = present
            return
        }
        guard hostWindow() != nil else {
            deferredPresentation = present
            return
        }
        present()
    }

    func showReleaseNotes(_ notes: UpdateReleaseNotes) {
        notesAccessory?.show(notes)
    }

    func showDownloadStarted(cancel: @escaping () -> Void) {
        let accessory = UpdateProgressAccessoryView(width: Defaults.progressWidth)
        progressAccessory = accessory

        let alert = makeAlert(
            message: L10n.string("Downloading Update…"),
            informative: "",
            accessory: accessory
        )
        alert.addButton(withTitle: L10n.string("Cancel"))
        present(alert) { _ in
            // Every way off this sheet is the same answer: the only button is Cancel, and
            // Escape means nothing stronger. A dismissal caused by the stage advancing is
            // detached before it can land here.
            cancel()
        }
    }

    func showDownloadProgress(_ progress: UpdateDownloadProgress) {
        progressAccessory?.show(fraction: progress.fraction)
    }

    func showExtractionStarted() {
        let accessory = UpdateProgressAccessoryView(width: Defaults.progressWidth)
        progressAccessory = accessory
        accessory.show(fraction: 0)

        // A fresh sheet rather than a relabel, because the download's Cancel does not
        // survive this boundary — Sparkle's cancellation is only valid before extraction —
        // and a Cancel that silently stopped working is worse than a new sheet without one.
        let alert = makeAlert(
            message: L10n.string("Preparing Update…"),
            informative: "",
            accessory: accessory
        )
        alert.addButton(withTitle: L10n.string("Hide"))
        present(alert)
    }

    func showExtractionProgress(_ fraction: Double) {
        progressAccessory?.show(fraction: fraction)
    }

    /// Built apart from its presentation for the same reason as `foundRequest`.
    static func readyRequest() -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .installUpdateAndRelaunch,
            title: L10n.string("Ready to Install"),
            message: L10n.string("Threading will quit and reopen as the new version."),
            confirmTitle: L10n.string("Install and Relaunch"),
            cancelTitle: L10n.string("Later"),
            style: .informational
        )
    }

    func showReadyToInstall(respond: @escaping (UpdateChoice) -> Void) {
        let respondOnce = Self.once(respond)
        let alert = ConfirmationAlert.makeAlert(Self.readyRequest())
        present(alert) { response in
            let accepted = ConfirmationAlert.chosenIndex(response, optionCount: 1) == 0
            respondOnce(accepted ? .install : .dismiss)
        }
    }

    func showInstalling() {
        present(Self.installingAlert())
    }

    /// The final stage is a real alert so its rendered fixture exercises the shipping copy,
    /// button and sheet silhouette together.
    static func installingAlert() -> ThemedAlert {
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("Installing Update…")
        alert.informativeText = L10n.string("Threading will quit in a moment.")
        alert.addButton(withTitle: L10n.string("Hide"))
        return alert
    }

    func showUpdateInstalled(acknowledge: @escaping () -> Void) {
        presentVerdict(
            message: L10n.string("Update Installed"),
            detail: L10n.string("Threading is now running the new version."),
            style: .informational,
            acknowledge: acknowledge
        )
    }

    func showNoUpdateFound(message: String, detail: String, acknowledge: @escaping () -> Void) {
        presentVerdict(
            message: message,
            detail: detail,
            style: .informational,
            acknowledge: acknowledge
        )
    }

    func showUpdateError(message: String, detail: String, acknowledge: @escaping () -> Void) {
        presentVerdict(
            message: message,
            detail: detail,
            style: .critical,
            acknowledge: acknowledge
        )
    }

    func dismissUpdateUI() {
        checkingSheetTask?.cancel()
        checkingSheetTask = nil
        deferredPresentation = nil
        detachAndDismissCurrent()
    }

    func focusUpdateUI() {
        NSApp.activate(ignoringOtherApps: true)
        presentDeferredIfPossible()
        if let panel = alert?.presentedWindow {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Stage sheets

    private func presentCheckingSheet(cancel: @escaping () -> Void) {
        let accessory = UpdateProgressAccessoryView(width: Defaults.progressWidth)
        progressAccessory = accessory
        accessory.show(fraction: nil)

        let alert = makeAlert(
            message: L10n.string("Checking for Updates…"),
            informative: "",
            accessory: accessory
        )
        alert.addButton(withTitle: L10n.string("Cancel"))
        present(alert) { _ in
            cancel()
        }
    }

    /// The found sheet, built without being presented so a test can hold its wording, button
    /// order, and accessory to what the flow actually offers.
    ///
    /// Remind Me Later is the way out, not an option: it is what Escape, a closed sheet,
    /// and a replaced stage all already mean, and Sparkle's dismiss is exactly "later".
    static func foundRequest(
        _ info: UpdateVersionInfo
    ) -> (request: ChoiceRequest, notes: UpdateReleaseNotesAccessoryView?) {
        let presentation = UpdateFoundPresentation(info: info)

        let informative: String
        var options: [ConfirmationOption] = []
        switch presentation.primary {
        case .install:
            informative = L10n.format(
                "Threading %@ is ready to download. You have %@.",
                info.version,
                AppInfo.marketingVersion
            )
            options.append(ConfirmationOption(title: L10n.string("Install Update")))
        case .learnMore:
            informative = L10n.format("Threading %@ is available.", info.version)
            options.append(ConfirmationOption(title: L10n.string("Learn More…")))
        case nil:
            // An information-only item with no page to open — a malformed feed entry. The
            // sheet still says what exists; there is just nothing to do about it here.
            informative = L10n.format("Threading %@ is available.", info.version)
        }
        if presentation.offersSkip {
            options.append(ConfirmationOption(title: L10n.string("Skip This Version")))
        }

        var notes: UpdateReleaseNotesAccessoryView?
        if info.releaseNotes != .none {
            notes = UpdateReleaseNotesAccessoryView(
                notes: info.releaseNotes,
                width: Defaults.notesWidth,
                height: Defaults.notesHeight
            )
        }

        let request = ChoiceRequest(
            prompt: .installUpdate,
            title: L10n.string("Update Available"),
            message: informative,
            options: options,
            cancelTitle: L10n.string("Remind Me Later"),
            style: .informational,
            accessory: notes
        )
        return (request, notes)
    }

    private func presentFoundSheet(
        _ info: UpdateVersionInfo,
        respond: @escaping (UpdateChoice) -> Void
    ) {
        let presentation = UpdateFoundPresentation(info: info)
        let (request, notes) = Self.foundRequest(info)
        notesAccessory = notes

        let alert = ConfirmationAlert.makeAlert(request)
        present(alert) { response in
            switch ConfirmationAlert.chosenIndex(response, optionCount: request.options.count) {
            case 0:
                switch presentation.primary {
                case .install:
                    respond(.install)
                case .learnMore(let url):
                    NSWorkspace.shared.open(url)
                    respond(.dismiss)
                case nil:
                    respond(.dismiss)
                }
            case 1:
                respond(.skip)
            default:
                respond(.dismiss)
            }
        }
    }

    /// A terminal verdict: shown as a sheet where a window exists, acknowledged silently
    /// where none does — an alert with nothing to attach to would have to go modal, and a
    /// nested run loop inside a Sparkle callback is not worth a message nobody is there for.
    private func presentVerdict(
        message: String,
        detail: String,
        style: ThemedAlert.Style,
        acknowledge: @escaping () -> Void
    ) {
        let acknowledgeOnce = Self.once(acknowledge)
        guard hostWindow() != nil else {
            ThreadingLogger.updates.info(
                "Update verdict with no window: \(message, privacy: .private(mask: .hash))"
            )
            acknowledgeOnce()
            return
        }
        let alert = makeAlert(message: message, informative: detail)
        alert.alertStyle = style
        alert.addButton(withTitle: L10n.string("OK"))
        present(alert) { _ in
            acknowledgeOnce()
        }
    }

    // MARK: - Presentation plumbing

    private func makeAlert(
        message: String,
        informative: String,
        accessory: NSView? = nil
    ) -> ThemedAlert {
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.informativeText = informative
        alert.accessoryView = accessory
        return alert
    }

    /// Presents a stage sheet, replacing whichever stage sheet is up.
    ///
    /// The replaced sheet's completion is detached *before* it is dismissed: a stage that
    /// advanced was not answered by the user, and its completion firing with `.abort` must
    /// not be read as Cancel — that is how a download would cancel itself the moment its own
    /// extraction began.
    private func present(
        _ alert: ThemedAlert,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        checkingSheetTask?.cancel()
        checkingSheetTask = nil
        detachAndDismissCurrent()

        self.alert = alert
        guard let window = hostWindow() else {
            // Narration with nowhere to draw. The stage advances silently; the next
            // answer-needing stage defers itself through `showUpdateFound`'s rule instead.
            self.alert = nil
            return
        }
        // Captured per sheet, not stored once: sheet completions arrive after `endSheet`,
        // so a replaced sheet's completion can fire after its successor is already up and
        // must find its *own* answer path, detached, rather than the successor's.
        var isActive = true
        detachCurrentCompletion = { isActive = false }
        alert.beginSheetModal(for: window) { [weak self] response in
            if let self, self.alert === alert {
                self.alert = nil
                self.notesAccessory = nil
                self.progressAccessory = nil
            }
            guard isActive else { return }
            isActive = false
            completion?(response)
        }
    }

    private var detachCurrentCompletion: (() -> Void)?

    private func detachAndDismissCurrent() {
        detachCurrentCompletion?()
        detachCurrentCompletion = nil
        notesAccessory = nil
        progressAccessory = nil
        alert?.dismiss()
        alert = nil
    }

    private func presentDeferredIfPossible() {
        guard let deferred = deferredPresentation,
              NSApp.isActive,
              hostWindow() != nil else { return }
        deferredPresentation = nil
        deferred()
    }

    /// Sparkle's replies must fire exactly once; every path that could double-report goes
    /// through this.
    private static func once<Value>(_ handler: @escaping (Value) -> Void) -> (Value) -> Void {
        var delivered = false
        return { value in
            guard !delivered else { return }
            delivered = true
            handler(value)
        }
    }

    private static func once(_ handler: @escaping () -> Void) -> () -> Void {
        var delivered = false
        return {
            guard !delivered else { return }
            delivered = true
            handler()
        }
    }
}

// MARK: - Release notes accessory

/// The found sheet's scrollable release notes: native Markdown in the app's own reading
/// style, a spinner while linked notes are still on their way, and a sentence when they
/// never arrive. The width and height are stated as constraints because `ThemedAlert`
/// sizes its accessory from `fittingSize`.
@MainActor
final class UpdateReleaseNotesAccessoryView: NSView {

    private let scrollView = ThemedScrollView()
    private let document = UpdateFlippedDocumentView()
    private let spinner = ThemedSpinner()
    private let statusLabel = NSTextField(labelWithString: "")

    init(notes: UpdateReleaseNotes, width: CGFloat, height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = document
        addSubview(scrollView)

        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        addSubview(statusLabel)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // The stated height is a ceiling, not a well: the preferred (breakable) equality
        // tracks the document, so short notes take only the height they need and the buttons
        // move up, while a long document stops at the cap and scrolls. The floor keeps the
        // spinner-and-sentence states from collapsing to a sliver. Resolved by Auto Layout in
        // the alert's own sizing pass — measuring wrapped text in a detached pass is the
        // fixture trap CLAUDE.md warns about, in production clothes.
        let preferred = heightAnchor.constraint(equalTo: document.heightAnchor)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(lessThanOrEqualToConstant: height),
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: Design.Size.chipHeight * 2 + Design.Spacing.large
            ),
            preferred,
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Design.Spacing.inset),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: Design.Spacing.small)
        ])

        show(notes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ notes: UpdateReleaseNotes) {
        document.subviews.forEach { $0.removeFromSuperview() }

        switch notes {
        case .embedded(let text), .downloaded(let text):
            spinner.isAnimating = false
            spinner.isHidden = true
            statusLabel.isHidden = true
            scrollView.isHidden = false
            document.install(MarkdownView(markdown: text), in: scrollView)
        case .pending:
            scrollView.isHidden = true
            spinner.isHidden = false
            spinner.isAnimating = true
            statusLabel.isHidden = false
            statusLabel.stringValue = L10n.string("Loading release notes…")
        case .none, .unavailable:
            scrollView.isHidden = true
            spinner.isAnimating = false
            spinner.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = L10n.string("Release notes could not be loaded.")
        }
    }
}

/// Scroll documents are flipped so the first release note reads from the top.
@MainActor
private final class UpdateFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }

    func install(_ content: NSView, in scrollView: ThemedScrollView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }
}

// MARK: - Progress accessory

/// One gauge for three waits: indeterminate (checking, or a download whose length is not yet
/// known) spins, determinate draws the themed bar. The two swap by visibility so the sheet
/// never shows a bar stuck at zero pretending to be information.
@MainActor
final class UpdateProgressAccessoryView: NSView {

    private let bar = ThemedProgressBar()
    private let spinner = ThemedSpinner()

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        bar.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(spinner)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            bar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor),
            spinner.topAnchor.constraint(equalTo: topAnchor),
            spinner.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Design.Size.chipHeight)
        ])

        show(fraction: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(fraction: Double?) {
        if let fraction {
            spinner.isAnimating = false
            spinner.isHidden = true
            bar.isHidden = false
            bar.progress = fraction
        } else {
            bar.isHidden = true
            spinner.isHidden = false
            spinner.isAnimating = true
        }
    }
}
