import AppKit

/// A non-key, app-owned completion panel. It lives in the presenting window rather than in a
/// second panel, so the prompt's text view keeps first responder while arrows move the visual
/// selection and IME composition continues to own its keystrokes.
@MainActor
final class PromptCompletionPresenter {
    private weak var source: NSView?
    private weak var root: NSView?
    private var panel: PromptCompletionPanel?
    // These handles are created and mutated on the main actor. `nonisolated(unsafe)` only lets
    // deinit remove them after the presenter becomes uniquely owned, matching ThemedPopover.
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var observations: [NSObjectProtocol] = []
    private var onChoose: ((Int) -> Void)?
    private var onDismiss: (() -> Void)?

    var isVisible: Bool { panel?.superview != nil }

    func present(
        items: [ComposerCapability],
        selectedIndex: Int,
        from source: NSView,
        onChoose: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard !items.isEmpty, let root = source.window?.contentView else {
            dismiss()
            return
        }

        self.source = source
        self.root = root
        self.onChoose = onChoose
        self.onDismiss = onDismiss

        let panel: PromptCompletionPanel
        let wasCreated: Bool
        if let existing = self.panel {
            panel = existing
            wasCreated = false
        } else {
            panel = PromptCompletionPanel()
            self.panel = panel
            root.addSubview(panel, positioned: .above, relativeTo: nil)
            installDismissMonitor()
            installWindowObservers()
            wasCreated = true
        }
        panel.configure(items: items, selectedIndex: selectedIndex) { [weak self] index in
            self?.onChoose?(index)
        }
        reposition()
        panel.scrollSelectionToVisible()
        if wasCreated {
            NSAccessibility.post(element: panel, notification: .created)
        }
    }

    func select(_ index: Int) {
        panel?.selectedIndex = index
        panel?.scrollSelectionToVisible()
    }

    func reposition() {
        guard let panel, let source, let root, source.window != nil else {
            dismiss()
            return
        }
        let anchor = source.convert(source.bounds, to: root)
        let width = min(max(PromptCompletionMetrics.minimumWidth, anchor.width), root.bounds.width)
        let desiredHeight = panel.desiredHeight
        let maximumHeight = min(PromptCompletionMetrics.maximumHeight, root.bounds.height * 0.55)
        let height = min(desiredHeight, maximumHeight)
        let gap = Design.Spacing.tight

        let before = root.isFlipped
            ? anchor.minY - root.bounds.minY
            : root.bounds.maxY - anchor.maxY
        let after = root.isFlipped
            ? root.bounds.maxY - anchor.maxY
            : anchor.minY - root.bounds.minY
        let opensBefore = before >= min(height + gap, maximumHeight) || before >= after

        let y: CGFloat
        if root.isFlipped {
            y = opensBefore ? anchor.minY - gap - height : anchor.maxY + gap
        } else {
            y = opensBefore ? anchor.maxY + gap : anchor.minY - gap - height
        }
        let x = min(max(root.bounds.minX, anchor.minX), root.bounds.maxX - width)
        panel.frame = NSRect(x: x, y: y, width: width, height: height)
        panel.needsLayout = true
    }

    func dismiss() {
        guard let panel else { return }
        panel.removeFromSuperview()
        self.panel = nil
        removeMonitorAndObservers()
        onChoose = nil
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
    }

    private func installDismissMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel, let root = self.root else { return event }
            guard event.window === root.window else {
                self.dismiss()
                return event
            }
            let point = root.convert(event.locationInWindow, from: nil)
            if !panel.frame.contains(point) {
                self.dismiss()
            }
            return event
        }
    }

    private func installWindowObservers() {
        guard let window = source?.window else { return }
        let center = NotificationCenter.default
        observations = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification
        ].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reposition()
                }
            }
        }
        observations.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func removeMonitorAndObservers() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observations.forEach(NotificationCenter.default.removeObserver)
    }
}

private enum PromptCompletionMetrics {
    static let rowHeight: CGFloat = 54
    static let outerInset: CGFloat = 6
    static let minimumWidth: CGFloat = 280
    static let maximumHeight: CGFloat = 330
}

@MainActor
private final class PromptCompletionPanel: NSView {
    private let surface = ThemedSurfaceView()
    private let scrollView = ThemedScrollView()
    private let document = PromptCompletionDocumentView()
    private var rows: [PromptCompletionRow] = []

    var selectedIndex = 0 {
        didSet {
            for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex }
        }
    }

    var desiredHeight: CGFloat {
        CGFloat(rows.count) * PromptCompletionMetrics.rowHeight
            + PromptCompletionMetrics.outerInset * 2
    }

    init() {
        super.init(frame: .zero)
        surface.applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(surface)
        addSubview(scrollView)
        setAccessibilityRole(.menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        items: [ComposerCapability],
        selectedIndex: Int,
        onChoose: @escaping (Int) -> Void
    ) {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = PromptCompletionRow(capability: item)
            row.onChoose = { onChoose(index) }
            document.addSubview(row)
            return row
        }
        document.rows = rows
        self.selectedIndex = min(max(0, selectedIndex), max(0, rows.count - 1))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = PromptCompletionMetrics.outerInset
        surface.frame = bounds
        scrollView.frame = bounds.insetBy(dx: inset, dy: inset)
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: CGFloat(rows.count) * PromptCompletionMetrics.rowHeight
        )
        document.needsLayout = true
    }

    func scrollSelectionToVisible() {
        guard rows.indices.contains(selectedIndex) else { return }
        rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
    }
}

private final class PromptCompletionDocumentView: NSView {
    var rows: [PromptCompletionRow] = []
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: 0,
                y: CGFloat(index) * PromptCompletionMetrics.rowHeight,
                width: bounds.width,
                height: PromptCompletionMetrics.rowHeight
            )
        }
    }
}

private final class PromptCompletionRow: ThemedControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private var isPressed = false {
        didSet { needsDisplay = true }
    }
    private var pressTarget: NSRect = .zero
    nonisolated(unsafe) private var releaseWatch: Any?
    var onChoose: (() -> Void)?
    var isSelected = false {
        didSet {
            setAccessibilitySelected(isSelected)
            needsDisplay = true
        }
    }

    init(capability: ComposerCapability) {
        super.init(frame: .zero)
        isEnabled = capability.isEnabled

        let argument = capability.argumentHint.isEmpty ? "" : "  \(capability.argumentHint)"
        titleLabel.stringValue = capability.invocationText + argument
        titleLabel.applyFont(.body)
        titleLabel.lineBreakMode = .byTruncatingTail

        // The reason *replaces* the description on a refused row, which is why
        // `ComposerCapability.Availability` requires one: this line can no longer fall through
        // to a description that explains what the action does while the row refuses to do it.
        let detail = capability.unavailableReason ?? capability.description
        detailLabel.stringValue = detail
        detailLabel.applyFont(.detail())
        detailLabel.lineBreakMode = .byTruncatingTail

        kindLabel.stringValue = capability.kind == .skill
            ? L10n.string("Skill")
            : L10n.string("Command")
        kindLabel.applyFont(.detail())
        kindLabel.alignment = .right

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(kindLabel)
        setAccessibilityRole(.menuItem)
        let accessibility = [capability.invocationText, capability.displayName, detail]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        setAccessibilityLabel(accessibility)
        if !detail.isEmpty { setAccessibilityHelp(detail) }
    }

    override func layout() {
        super.layout()
        let horizontal = Design.Spacing.medium
        let kindWidth: CGFloat = 68
        titleLabel.frame = NSRect(
            x: horizontal,
            y: bounds.height - 27,
            width: max(0, bounds.width - horizontal * 2 - kindWidth),
            height: 20
        )
        detailLabel.frame = NSRect(
            x: horizontal,
            y: 7,
            width: max(0, bounds.width - horizontal * 2),
            height: 17
        )
        kindLabel.frame = NSRect(
            x: max(horizontal, bounds.width - horizontal - kindWidth),
            y: bounds.height - 26,
            width: kindWidth,
            height: 18
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The row draws its own three labels, so it paints the theme's selection at full strength
        // and takes the ink measured against it — not `Design.Text.selected`, which answers for the
        // opaque accent and was writing white over a 20% wash under the themes that author one.
        let selection = SelectionSurface.stated(over: resolvedGround())
        let fills = isSelected && !isPressed
        if isSelected || isHovered || isPressed {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 2, dy: 2),
                xRadius: Design.Radius.control,
                yRadius: Design.Radius.control
            )
            (fills ? selection.fill : Design.Surface.controlHover).setFill()
            path.fill()
        }
        // Only what the selection is actually *under* takes its ink: a pressed row is filled with
        // the hover colour instead, where the chrome's own tiers are still the ones that read.
        let primary = isEnabled
            ? (fills ? selection.ink.label : Design.Text.label)
            : Design.Text.tertiary
        titleLabel.textColor = primary
        detailLabel.textColor = isEnabled
            ? (fills ? selection.ink.secondary : Design.Text.secondary)
            : Design.Text.tertiary
        kindLabel.textColor = fills ? selection.ink.tertiary : Design.Text.tertiary
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        guard let window else {
            isPressed = false
            return
        }
        pressTarget = window.convertToScreen(convert(bounds, to: nil))
        endWatchingForRelease()
        releaseWatch = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .leftMouseDragged, .leftMouseDown]
        ) { [weak self] event in
            self?.track(event)
            return event
        }
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        completePress(
            firing: isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        )
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onChoose?()
        return true
    }

    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func track(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            isPressed = pressTarget.contains(screenLocation(of: event))
        case .leftMouseUp:
            completePress(firing: isPressed && pressTarget.contains(screenLocation(of: event)))
        default:
            completePress(firing: false)
        }
    }

    private func completePress(firing shouldFire: Bool) {
        isPressed = false
        endWatchingForRelease()
        if shouldFire { _ = performPrimaryAction() }
    }

    private func endWatchingForRelease() {
        guard let releaseWatch else { return }
        NSEvent.removeMonitor(releaseWatch)
        self.releaseWatch = nil
    }

    deinit {
        if let releaseWatch { NSEvent.removeMonitor(releaseWatch) }
    }
}

#if DEBUG
/// Keeps the implementation row private while allowing behavioral tests to exercise the real
/// AppKit event and accessibility paths without constructing the full completion overlay. The
/// latter trips XCTest's object-lifetime checker for never-shown windows on macOS 26.
@MainActor
enum PromptCompletionRowTestingSupport {
    static func makeRow(
        capability: ComposerCapability,
        onChoose: (() -> Void)? = nil
    ) -> ThemedControl {
        let row = PromptCompletionRow(capability: capability)
        row.onChoose = onChoose
        return row
    }
}
#endif
