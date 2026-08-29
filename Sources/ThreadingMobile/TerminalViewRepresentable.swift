import ThreadingRemoteKit
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalViewRepresentable: UIViewRepresentable {
    typealias UIViewType = RemoteTerminalLayoutView

    @ObservedObject var connection: RemoteSessionConnection
    let theme: RemoteTerminalThemeDTO?
    let chromeTheme: RemoteThemePalette
    let allowsDirectInput: Bool
    let keyBridge: TerminalKeyBridge
    let fontSize: Double
    let onFontSizeChange: @MainActor (Double) -> Void
    let initialScrollProgress: Double?
    let onScrollProgress: @MainActor (Double) -> Void
    /// Receives the selected text when the person chooses to quote it into their message.
    /// `nil` when nothing typed here can reach the Mac, in which case the menu offers no such
    /// action. Defaulted so the view composes without a quote sink while the composer wiring
    /// that supplies one is being assembled.
    var quoteSelection: (@MainActor (String) -> Void)? = nil
    /// Whether the terminal takes the keyboard as soon as it exists. The chat's memory of how
    /// it was left decides; a chat never left before takes it, as an interactive terminal
    /// always did.
    var focusesOnCreation = true

    func makeCoordinator() -> Coordinator {
        Coordinator(
            connection: connection,
            allowsInput: allowsDirectInput,
            keyBridge: keyBridge,
            initialScrollProgress: initialScrollProgress,
            onScrollProgress: onScrollProgress
        )
    }

    func makeUIView(context: Context) -> RemoteTerminalLayoutView {
        let resolvedFontSize = MobileTerminalFontSize.resolvedPreference(fontSize)
        let contentInset = MobileDesign.Spacing.small
        let containerFrame = UIScreen.main.bounds
        let view = RemoteTerminalView(
            frame: containerFrame.insetBy(dx: contentInset, dy: contentInset),
            font: UIFont.monospacedSystemFont(ofSize: CGFloat(resolvedFontSize), weight: .regular)
        )
        let container = RemoteTerminalLayoutView(
            frame: containerFrame,
            terminalView: view,
            contentInset: contentInset,
            theme: chromeTheme
        )
        view.terminalDelegate = context.coordinator
        view.dropBuiltInKeyboardAccessory()
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.setAllowsKeyboardInput(allowsDirectInput)
        // Claim the mouse only when a report would actually reach the Mac. A view-only phone,
        // or one whose keystrokes go to a draft, has its reports dropped on the way out — and a
        // gesture claimed by the emulator and then dropped scrolls nothing at all.
        view.allowMouseReporting = allowsDirectInput
        view.configureFontSizing(onChange: onFontSizeChange)
        view.configureSelectionMenu(quoteSelection: quoteSelection, canPaste: allowsDirectInput)
        context.coordinator.attach(to: view, in: container)
        Self.apply(theme, to: view)
        view.accessibilityLabel = MobileL10n.string("Remote terminal")
#if DEBUG
        MobileTerminalWirePerformanceProbe.terminalViewCreated(connection.session)
#endif

        context.coordinator.bindRenderer(to: connection)
        if allowsDirectInput, focusesOnCreation {
#if DEBUG
            if ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_STATE"
            ] == nil {
                DispatchQueue.main.async {
                    _ = view.becomeFirstResponder()
                }
            }
#else
            DispatchQueue.main.async {
                _ = view.becomeFirstResponder()
            }
#endif
        }
        return container
    }

    func updateUIView(_ uiView: RemoteTerminalLayoutView, context: Context) {
        let terminalView = uiView.terminalView
        context.coordinator.bindRenderer(to: connection)
        context.coordinator.allowsInput = allowsDirectInput
        context.coordinator.initialScrollProgress = initialScrollProgress
        context.coordinator.onScrollProgress = onScrollProgress
        terminalView.setAllowsKeyboardInput(allowsDirectInput)
        // The key bar's show control follows this answer, and nothing else republishes it when
        // input mode flips on a live view.
        keyBridge.refreshKeyboardAvailability()
        terminalView.allowMouseReporting = allowsDirectInput
        uiView.updateTheme(chromeTheme)
        terminalView.configureFontSizing(onChange: onFontSizeChange)
        terminalView.configureSelectionMenu(
            quoteSelection: quoteSelection,
            canPaste: allowsDirectInput
        )
        terminalView.applyPreferredFontSize(MobileTerminalFontSize.resolvedPreference(fontSize))
        let ownsViewport = connection.capability == .interact
        terminalView.setUsesLocalViewport(ownsViewport)
        if !ownsViewport {
            terminalView.setAuthoritativeGrid(
                cols: connection.terminalColumns,
                rows: connection.terminalRows
            )
        }
        Self.apply(theme, to: terminalView)
        context.coordinator.refreshScrollToEndPresence(animated: false)
    }

    static func dismantleUIView(_ uiView: RemoteTerminalLayoutView, coordinator: Coordinator) {
        let terminalView = uiView.terminalView
        uiView.cancelPendingLayout()
        coordinator.captureViewport()
        coordinator.unbindRenderer(from: terminalView)
        coordinator.detach()
        // SwiftTerm 2 keeps a display driver and renderer graph per view. This representable is
        // being permanently dismantled, not merely moved between windows, so close that graph
        // through the dependency's explicit lifecycle seam.
        _ = terminalView.updateUiClosed()
    }

    /// Installs the palette only when it changed. `updateUIView` runs for every published
    /// change on the connection — presence, typing, the grid, canSend — and reinstalling an
    /// identical palette is not free: `installColors` clears the attribute caches and marks the
    /// whole screen dirty, so every status tick was repainting every visible cell cold, and the
    /// smaller the font the more cells that was.
    static func apply(_ theme: RemoteTerminalThemeDTO?, to view: RemoteTerminalView) {
        guard !view.hasAppliedTheme || view.appliedTheme != theme else { return }
        view.noteAppliedTheme(theme)
        guard let theme,
              let foreground = UIColor(remoteHex: theme.foreground),
              let background = UIColor(remoteHex: theme.background) else {
            let fallback = UIColor(red: 0.035, green: 0.039, blue: 0.047, alpha: 1)
            view.nativeForegroundColor = .white
            view.nativeBoldForegroundColor = nil
            view.nativeBackgroundColor = fallback
            view.backgroundColor = fallback
            view.selectionHandleColor = .white
            view.keyboardAppearance = .dark
            return
        }

        let ansi = theme.ansi.compactMap { value -> SwiftTerm.Color? in
            guard let color = UIColor(remoteHex: value) else { return nil }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return nil
            }
            return SwiftTerm.Color(
                red: UInt16(red * 65_535),
                green: UInt16(green * 65_535),
                blue: UInt16(blue * 65_535)
            )
        }
        if ansi.count == 16 { view.installColors(ansi) }

        view.nativeForegroundColor = foreground
        // Absent or unreadable means "the same as the foreground", which is how a host from
        // before the role existed describes itself.
        view.nativeBoldForegroundColor = theme.boldForeground.flatMap(UIColor.init(remoteHex:))
        view.nativeBackgroundColor = background
        view.backgroundColor = background
        if let selection = UIColor(remoteHex: theme.selection) {
            view.selectedTextBackgroundColor = selection
        }
        if let cursor = UIColor(remoteHex: theme.cursor) {
            view.caretColor = cursor
            // The selection plate is usually translucent, so the handles take the theme's
            // other interaction colour, which is always readable over its background.
            view.selectionHandleColor = cursor
        } else {
            view.selectionHandleColor = foreground
        }

        view.keyboardAppearance = MobileKeyboardAppearance.over(background)
        view.setNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private(set) var connection: RemoteSessionConnection
        var allowsInput: Bool
        let keyBridge: TerminalKeyBridge
        var initialScrollProgress: Double?
        var onScrollProgress: @MainActor (Double) -> Void
        private weak var terminalView: RemoteTerminalView?
        private weak var layoutView: RemoteTerminalLayoutView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var hasRestoredViewport = false

        init(
            connection: RemoteSessionConnection,
            allowsInput: Bool,
            keyBridge: TerminalKeyBridge,
            initialScrollProgress: Double?,
            onScrollProgress: @escaping @MainActor (Double) -> Void
        ) {
            self.connection = connection
            self.allowsInput = allowsInput
            self.keyBridge = keyBridge
            self.initialScrollProgress = initialScrollProgress
            self.onScrollProgress = onScrollProgress
        }

        /// Rebinds a reused UIKit view without letting the previous connection retain its
        /// callbacks. The ownership check also repairs a warm connection whose parking step
        /// deliberately removed every renderer callback before this view was updated again.
        func bindRenderer(to nextConnection: RemoteSessionConnection) {
            guard let view = terminalView else {
                connection = nextConnection
                return
            }
            if connection !== nextConnection {
                connection.unmountTerminalRenderer(view)
                connection = nextConnection
            }
            guard !connection.isTerminalRendererOwner(view) else { return }
            let terminalSession = connection.session
            connection.mountTerminalRenderer(
                view,
                output: { [weak self, weak view] data in
                    guard let self, let view else { return }
#if DEBUG
                    MobileTerminalWirePerformanceProbe.feed(data, session: terminalSession) {
                        view.feed(byteArray: Array(data)[...])
                    }
#else
                    view.feed(byteArray: Array(data)[...])
#endif
                    self.restoreViewportIfPossible()
                    self.refreshScrollToEndPresence()
                },
                gridChange: { [weak view] cols, rows in
                    guard view?.usesLocalViewport == false else { return }
                    view?.setAuthoritativeGrid(cols: cols, rows: rows)
                }
            )
        }

        func unbindRenderer(from view: RemoteTerminalView) {
            connection.unmountTerminalRenderer(view)
        }

        @MainActor
        func attach(to view: RemoteTerminalView, in layoutView: RemoteTerminalLayoutView) {
            terminalView = view
            self.layoutView = layoutView
            keyBridge.terminalView = view
            view.scrollOwnershipDidChange = { [weak self] in
                self?.refreshScrollToEndPresence()
            }
            contentOffsetObservation = view.observe(\.contentOffset, options: [.new]) {
                [weak self, weak view] _, _ in
                Task { @MainActor in
                    guard let self, let view else { return }
                    self.refreshScrollToEndPresence()
                    guard view.isDragging || view.isDecelerating || view.isTracking else { return }
#if DEBUG
                    MobileTerminalWirePerformanceProbe.localScrollChanged(self.connection.session)
#endif
                    self.captureViewport()
                }
            }
        }

        @MainActor
        func detach() {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            terminalView?.scrollOwnershipDidChange = nil
            if keyBridge.terminalView === terminalView {
                keyBridge.terminalView = nil
            }
            terminalView = nil
            layoutView = nil
        }

        func restoreViewportIfPossible() {
            guard !hasRestoredViewport, let view = terminalView,
                  let progress = initialScrollProgress else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.hasRestoredViewport else { return }
                let maximum = max(0, view.contentSize.height - view.bounds.height)
                guard maximum > 0 else { return }
                view.setContentOffset(
                    CGPoint(x: view.contentOffset.x, y: maximum * min(max(progress, 0), 1)),
                    animated: false
                )
                self.hasRestoredViewport = true
                self.refreshScrollToEndPresence(animated: false)
            }
        }

        func refreshScrollToEndPresence(animated: Bool = true) {
            guard let view = terminalView else { return }
            let shouldPresent = view.canScroll
                && !view.programOwnsPrimaryScrollGesture
                && !view.isAtScrollbackEnd
            layoutView?.setScrollToEndPresented(shouldPresent, animated: animated)
        }

        func captureViewport() {
            guard let view = terminalView else { return }
            let maximum = max(0, view.contentSize.height - view.bounds.height)
            let progress = maximum > 0
                ? Double(min(max(view.contentOffset.y / maximum, 0), 1))
                : 1
            onScrollProgress(progress)
        }

        /// Only the phone-owned grid is a viewport request. During authentication the Mac's
        /// authoritative grid is briefly installed so buffered ANSI can be interpreted, and
        /// SwiftTerm reports that programmatic resize through this same delegate. Echoing it
        /// back as a lease made every push resize the PTY phone → Mac → phone before settling.
        var reportsTerminalViewportChanges: Bool {
            terminalView?.usesLocalViewport == true
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor [weak self] in
                guard let self, self.allowsInput else { return }
                let typed = self.keyBridge.applyLatchesToTyped(bytes)
#if DEBUG
                MobileTerminalWirePerformanceProbe.terminalInput(
                    typed[...],
                    session: self.connection.session
                )
#endif
                self.connection.sendTerminalInput(typed[...])
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [weak self] in
                guard let self, reportsTerminalViewportChanges else { return }
                connection.updateTerminalViewport(cols: newCols, rows: newRows)
            }
        }
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(
            source: TerminalView,
            link: String,
            params: [String: String]
        ) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        nonisolated func bell(source: TerminalView) {
            Task { @MainActor in
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            let string = String(data: content, encoding: .utf8)
            Task { @MainActor in UIPasteboard.general.string = string }
        }
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Keeps SwiftTerm at one settled width while its SwiftUI navigation destination is travelling.
///
/// `NavigationStack` proposes every intermediate width during a push or an interactive Back.
/// That is ordinary presentation geometry for most views, but a terminal interprets every width
/// as a new grid and can consequently reflow both its local emulator and the Mac's PTY dozens of
/// times during one gesture. The structural host clips the already-laid-out terminal instead.
/// Once a non-navigation width has held still, it commits that one useful width to SwiftTerm.
/// Height remains live so the terminal continues to follow the keyboard and safe area.
final class RemoteTerminalLayoutView: UIView {
    let terminalView: RemoteTerminalView
    let contentInset: CGFloat
    let scrollToEndButton = MobileFloatingScrollToEndButton(
        accessibilityLabel: MobileL10n.string("Jump to bottom"),
        accessibilityIdentifier: "terminal-scroll-to-end"
    )

    private(set) var settledTerminalWidth: CGFloat
    private(set) var pendingTerminalWidth: CGFloat?
#if DEBUG
    private(set) var terminalWidthApplicationCount = 0
#endif
    private var widthSettleTask: Task<Void, Never>?
    private var observesTransitionCompletion = false

    init(
        frame: CGRect,
        terminalView: RemoteTerminalView,
        contentInset: CGFloat,
        theme: RemoteThemePalette = RemoteThemePalette(nil)
    ) {
        self.terminalView = terminalView
        self.contentInset = contentInset
        settledTerminalWidth = max(0, terminalView.bounds.width)
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(terminalView)
        scrollToEndButton.applyTheme(theme)
        scrollToEndButton.addAction(UIAction { [weak terminalView, weak self] _ in
            guard let terminalView else { return }
            MobileScrollMotion.cancel(in: terminalView)
            terminalView.scroll(toPosition: 1)
            self?.setScrollToEndPresented(false)
        }, for: .touchUpInside)
        addSubview(scrollToEndButton)
        NSLayoutConstraint.activate([
            scrollToEndButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(contentInset + MobileDesign.Spacing.inset)
            ),
            scrollToEndButton.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -(contentInset + MobileDesign.Spacing.inset)
            ),
            scrollToEndButton.widthAnchor.constraint(
                equalToConstant: MobileDesign.Size.floatingScrollTarget
            ),
            scrollToEndButton.heightAnchor.constraint(
                equalToConstant: MobileDesign.Size.floatingScrollTarget
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let coordinator = enclosingTransitionCoordinator
        updateTerminalFrame(for: bounds.size, holdsWidth: coordinator != nil)
        observeCompletion(of: coordinator)
        bringSubviewToFront(scrollToEndButton)
    }

    func updateTheme(_ theme: RemoteThemePalette) {
        scrollToEndButton.applyTheme(theme)
    }

    func setScrollToEndPresented(_ presented: Bool, animated: Bool = true) {
        scrollToEndButton.setPresented(presented, animated: animated)
    }

    /// Internal so the high-frequency contract can be exercised without manufacturing a UIKit
    /// navigation controller and an interactive gesture in a unit test.
    func updateTerminalFrame(for containerSize: CGSize, holdsWidth: Bool) {
        let proposedWidth = contentWidth(for: containerSize.width)
        let proposedHeight = max(0, containerSize.height - contentInset * 2)

        if settledTerminalWidth <= 0 {
            applyTerminalWidth(proposedWidth)
        } else if abs(proposedWidth - settledTerminalWidth) <= Self.widthEpsilon {
            pendingTerminalWidth = nil
            widthSettleTask?.cancel()
            widthSettleTask = nil
        } else {
            pendingTerminalWidth = proposedWidth
            if holdsWidth {
                widthSettleTask?.cancel()
                widthSettleTask = nil
            } else {
                scheduleWidthSettle()
            }
        }

        terminalView.frame = CGRect(
            x: contentInset,
            y: contentInset,
            width: settledTerminalWidth,
            height: proposedHeight
        )
    }

    func settlePendingWidth() {
        widthSettleTask?.cancel()
        widthSettleTask = nil
        let finalWidth = pendingTerminalWidth ?? contentWidth(for: bounds.width)
        applyTerminalWidth(finalWidth)
        setNeedsLayout()
    }

    func cancelPendingLayout() {
        widthSettleTask?.cancel()
        widthSettleTask = nil
        pendingTerminalWidth = nil
    }

    /// A completed pop is teardown, not a useful terminal resize. A cancelled pop and a push both
    /// leave this host on screen and therefore commit only the width at which navigation settled.
    func transitionDidComplete(isCancelled: Bool, terminalWasSource: Bool) {
        observesTransitionCompletion = false
        guard isCancelled || !terminalWasSource else {
            cancelPendingLayout()
            return
        }
        pendingTerminalWidth = contentWidth(for: bounds.width)
        settlePendingWidth()
    }

    private static let widthEpsilon: CGFloat = 0.5

    private func contentWidth(for containerWidth: CGFloat) -> CGFloat {
        max(0, containerWidth - contentInset * 2)
    }

    private func applyTerminalWidth(_ width: CGFloat) {
        guard abs(width - settledTerminalWidth) > Self.widthEpsilon else {
            pendingTerminalWidth = nil
            return
        }
        settledTerminalWidth = width
        pendingTerminalWidth = nil
#if DEBUG
        terminalWidthApplicationCount += 1
#endif
    }

    private func scheduleWidthSettle() {
        widthSettleTask?.cancel()
        widthSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RemoteMobileConnectionDefaults.viewportSettleDelay)
            guard !Task.isCancelled else { return }
            self?.settlePendingWidth()
        }
    }

    private var enclosingTransitionCoordinator: UIViewControllerTransitionCoordinator? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               let coordinator = controller.transitionCoordinator {
                return coordinator
            }
            responder = current.next
        }
        return window?.rootViewController?.transitionCoordinator
    }

    private func observeCompletion(
        of coordinator: UIViewControllerTransitionCoordinator?
    ) {
        guard let coordinator, !observesTransitionCompletion else { return }
        observesTransitionCompletion = true
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            let terminalWasSource = context.view(forKey: .from).map {
                $0 === self || self.isDescendant(of: $0)
            } ?? false
            self.transitionDidComplete(
                isCancelled: context.isCancelled,
                terminalWasSource: terminalWasSource
            )
        }
    }
}

/// SwiftTerm normally derives its grid from this device's pixel size. Remote output was produced
/// for the Mac's PTY grid, though, so cursor addressing and wraps only remain correct when this
/// view holds that authoritative size against its own layout.
final class RemoteTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private(set) var usesLocalViewport = false
    private(set) var isAdjustingFontSize = false
    /// The theme `TerminalViewRepresentable.apply` last installed. `hasAppliedTheme` tells the
    /// very first application apart from an applied nil, whose fallback colours count too.
    private(set) var appliedTheme: RemoteTerminalThemeDTO?
    private(set) var hasAppliedTheme = false
#if DEBUG
    private(set) var themeApplicationCount = 0
#endif
    private var allowsKeyboardInput = true
    private var authoritativeColumns = 0
    private var authoritativeRows = 0
    private var fontPinchRecognizer: UIPinchGestureRecognizer?
    private var fontSizeAtPinchStart = MobileTerminalFontSize.defaultValue
    private let fontSizeFeedbackGenerator = UISelectionFeedbackGenerator()
    private var onFontSizeChange: (@MainActor (Double) -> Void)?
    var scrollOwnershipDidChange: (@MainActor () -> Void)?

    nonisolated override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        Task { @MainActor [weak self] in
            self?.scrollOwnershipDidChange?()
        }
    }

    override var canBecomeFirstResponder: Bool {
        allowsKeyboardInput && super.canBecomeFirstResponder
    }

    /// Drops SwiftTerm's own `TerminalAccessory` — esc, ctrl, tab, arrows.
    ///
    /// `TerminalKeyBar` occupies that same strip above the keyboard with the customizable,
    /// per-agent run this app ships, so leaving SwiftTerm's in place stacked two rows of nearly
    /// the same keys over the keyboard. Assignment is SwiftTerm's own documented seam here, and
    /// once is enough: it installs the accessory from its initializer and never again.
    func dropBuiltInKeyboardAccessory() {
        inputAccessoryView = nil
    }

    /// Puts the app's own action beside Copy in the terminal's edit menu.
    ///
    /// Copy keeps the text on the pasteboard; this keeps it in the message, as a chip the
    /// person can still take back. Taking the quote clears the selection the way Copy does:
    /// the chip is the thing that persists, the highlight was only how it was chosen.
    func configureSelectionMenu(
        quoteSelection: (@MainActor (String) -> Void)?,
        canPaste: Bool
    ) {
        allowsPasteFromEditMenu = canPaste
        guard let quoteSelection else {
            extraSelectionMenuActions = nil
            return
        }
        extraSelectionMenuActions = { [weak self] text in
            [
                UIAction(
                    title: MobileL10n.string("Add to message"),
                    image: UIImage(systemName: "text.quote")
                ) { _ in
                    quoteSelection(text)
                    self?.clearSelection()
                },
            ]
        }
    }

    func setAllowsKeyboardInput(_ allowed: Bool) {
        guard allowsKeyboardInput != allowed else { return }
        allowsKeyboardInput = allowed
        if !allowed, isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    func configureFontSizing(onChange: @escaping @MainActor (Double) -> Void) {
        onFontSizeChange = onChange
        if fontPinchRecognizer == nil {
            let recognizer = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handleFontPinch(_:))
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
            fontPinchRecognizer = recognizer
        }
        refreshFontSizeAccessibilityActions()
    }

    func applyPreferredFontSize(_ value: Double) {
        guard !isAdjustingFontSize else { return }
        applyFontSize(value)
    }

    func noteAppliedTheme(_ theme: RemoteTerminalThemeDTO?) {
        appliedTheme = theme
        hasAppliedTheme = true
#if DEBUG
        themeApplicationCount += 1
#endif
    }

    func beginFontPinch() {
        isAdjustingFontSize = true
        fontSizeAtPinchStart = MobileTerminalFontSize.normalized(Double(font.pointSize))
        fontSizeFeedbackGenerator.prepare()
    }

    func updateFontPinch(scale: CGFloat) {
        guard isAdjustingFontSize else { return }
        applyFontSize(
            MobileTerminalFontSize.scaled(from: fontSizeAtPinchStart, by: scale),
            feedback: true
        )
    }

    func endFontPinch() {
        guard isAdjustingFontSize else { return }
        isAdjustingFontSize = false
        persistCurrentFontSize()
    }

    @objc private func handleFontPinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginFontPinch()
        case .changed:
            updateFontPinch(scale: recognizer.scale)
        case .ended, .cancelled, .failed:
            endFontPinch()
        default:
            break
        }
    }

    private func applyFontSize(_ value: Double, feedback: Bool = false) {
        let normalized = MobileTerminalFontSize.normalized(value)
        guard font.pointSize != CGFloat(normalized) else {
            refreshFontSizeAccessibilityActions()
            return
        }
        font = font.withSize(CGFloat(normalized))
        if feedback {
            // This branch runs only after the whole-point guard above, so a continuous pinch
            // produces one tactile tick per visible size step rather than one per touch sample.
            fontSizeFeedbackGenerator.selectionChanged()
            fontSizeFeedbackGenerator.prepare()
        }
        refreshFontSizeAccessibilityActions()
    }

    private func persistCurrentFontSize(announce: Bool = false) {
        let normalized = MobileTerminalFontSize.normalized(Double(font.pointSize))
        onFontSizeChange?(normalized)
        if announce {
            UIAccessibility.post(
                notification: .announcement,
                argument: MobileL10n.string("Terminal font size %lld points", Int64(normalized))
            )
        }
    }

    @objc private func increaseTerminalFontSize() {
        applyFontSize(
            MobileTerminalFontSize.increased(from: Double(font.pointSize)),
            feedback: true
        )
        persistCurrentFontSize(announce: true)
    }

    @objc private func decreaseTerminalFontSize() {
        applyFontSize(
            MobileTerminalFontSize.decreased(from: Double(font.pointSize)),
            feedback: true
        )
        persistCurrentFontSize(announce: true)
    }

    @objc private func accessibilityIncreaseTerminalFontSize(
        _ action: UIAccessibilityCustomAction
    ) -> Bool {
        increaseTerminalFontSize()
        return true
    }

    @objc private func accessibilityDecreaseTerminalFontSize(
        _ action: UIAccessibilityCustomAction
    ) -> Bool {
        decreaseTerminalFontSize()
        return true
    }

    private func refreshFontSizeAccessibilityActions() {
        let size = MobileTerminalFontSize.normalized(Double(font.pointSize))
        var actions: [UIAccessibilityCustomAction] = []
        if size < MobileTerminalFontSize.maximum {
            actions.append(UIAccessibilityCustomAction(
                name: MobileL10n.string("Increase terminal font size"),
                target: self,
                selector: #selector(accessibilityIncreaseTerminalFontSize(_:))
            ))
        }
        if size > MobileTerminalFontSize.minimum {
            actions.append(UIAccessibilityCustomAction(
                name: MobileL10n.string("Decrease terminal font size"),
                target: self,
                selector: #selector(accessibilityDecreaseTerminalFontSize(_:))
            ))
        }
        accessibilityCustomActions = actions
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(
                title: MobileL10n.string("Increase terminal font size"),
                action: #selector(increaseTerminalFontSize),
                input: "+",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: MobileL10n.string("Decrease terminal font size"),
                action: #selector(decreaseTerminalFontSize),
                input: "-",
                modifierFlags: .command
            ),
        ]
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === fontPinchRecognizer || otherGestureRecognizer === fontPinchRecognizer
    }

    /// Answers before the emulator is touched, so a layout pass cannot reflow the Mac's grid to
    /// this phone's pixel size and back. The round trip also soft-reset the buffer, which threw
    /// away the scrolling region of whatever full-screen program the Mac is showing.
    override func shouldApplyFrameSizeChange(newCols: Int, newRows: Int) -> Bool {
        usesLocalViewport || authoritativeColumns <= 0 || authoritativeRows <= 0
    }

    /// Installing the Mac's authoritative grid is renderer state, not a request to resize the
    /// process. SwiftTerm's programmatic `resize` reports through the same delegate as a frame
    /// change, so suppress that report at the point where the resize still knows its owner.
    override func shouldReportSizeChange(newCols: Int, newRows: Int) -> Bool {
        usesLocalViewport
    }

    func setAuthoritativeGrid(cols: Int, rows: Int) {
        guard !usesLocalViewport else { return }
        guard cols > 0, rows > 0 else { return }
        authoritativeColumns = cols
        authoritativeRows = rows
        applyAuthoritativeGrid()
    }

    func setUsesLocalViewport(_ usesLocalViewport: Bool) {
        guard self.usesLocalViewport != usesLocalViewport else { return }
        self.usesLocalViewport = usesLocalViewport
        if usesLocalViewport {
            authoritativeColumns = 0
            authoritativeRows = 0
            // Recomputes the grid from the phone's existing pixel frame and notifies the
            // coordinator even when the frame itself did not change during authentication.
            font = font
        } else {
            applyAuthoritativeGrid()
        }
    }

    /// A repeat of the grid already in force is not a resize: `resize` soft-resets the emulator,
    /// which would discard the scrolling region the Mac's output relies on.
    private func applyAuthoritativeGrid() {
        guard authoritativeColumns > 0, authoritativeRows > 0 else { return }
        let current = terminalDimensions
        guard current.cols != authoritativeColumns || current.rows != authoritativeRows else {
            return
        }
        resize(cols: authoritativeColumns, rows: authoritativeRows)
    }
}
