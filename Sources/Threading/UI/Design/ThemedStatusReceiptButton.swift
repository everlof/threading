import AppKit

/// One bounded, clickable status receipt whose complete semantic fragments wrap as units.
///
/// A provider summary can contain more states than the card's 360-point column can hold on one
/// line. Ordinary button truncation would hide precisely the tail states this receipt exists to
/// preserve, so the component flows only between fragments and grows by whole text lines. The
/// host supplies already-localized fragments and a semantic image; this boundary owns drawing,
/// hover/press/focus, keyboard activation, accessibility, and live theme response.
final class ThemedStatusReceiptButton: ThemedControl, OpticalInsetProviding {

    @MainActor
    private enum Layout {
        static let horizontalInset = Design.Spacing.tight
        static let verticalInset = Design.Spacing.tight
        static let imageTitleGap = Design.Spacing.small
        static let lineGap = Design.Spacing.tight
        static let separator = " · "
        static let pressedAlpha: CGFloat = 0.75
        static let disabledAlpha: CGFloat = 0.4
    }

    var fragments: [String] = [] {
        didSet {
            guard fragments != oldValue else { return }
            contentChanged()
        }
    }

    var image: NSImage? {
        didSet { contentChanged() }
    }

    var fontRole: Design.FontRole = .numericControl(weight: .medium) {
        didSet { contentChanged() }
    }

    var contentTintColor: NSColor? {
        didSet { needsDisplay = true }
    }

    var hoverFill: NSColor? {
        didSet { needsDisplay = true }
    }

    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
        }
    }

    private weak var pressedTarget: AnyObject?
    private var pressedAction: Selector?
    private var pressTarget: NSRect = .zero
    private let releaseWatch = LocalEventMonitor()
    private var measuredLineCount = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("themed.status-receipt")
    }

    convenience init(target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var resolvedFont: NSFont { fontRole.resolved() }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        return [
            .font: resolvedFont,
            .foregroundColor: resolvedContentTint,
            .paragraphStyle: paragraph
        ]
    }

    private var lineHeight: CGFloat { Design.Typography.lineHeight(of: resolvedFont) }
    private var imageSize: NSSize { image?.size ?? .zero }
    private var textLeadingInset: CGFloat {
        Layout.horizontalInset + (image == nil ? 0 : imageSize.width + Layout.imageTitleGap)
    }

    private var resolvedContentTint: NSColor {
        let color = contentTintColor ?? Design.Text.label
        let alpha: CGFloat
        if !isEnabled { alpha = Layout.disabledAlpha }
        else if isPressed { alpha = Layout.pressedAlpha }
        else { alpha = 1 }
        return color.withAlphaComponent(color.alphaComponent * alpha)
    }

    private func contentChanged() {
        measuredLineCount = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func width(of value: String) -> CGFloat {
        ceil((value as NSString).size(withAttributes: textAttributes).width)
    }

    private var naturalTextWidth: CGFloat {
        width(of: fragments.joined(separator: Layout.separator))
    }

    private func lineStrings(for containerWidth: CGFloat) -> [String] {
        guard !fragments.isEmpty else { return [""] }
        let available = max(0, containerWidth - textLeadingInset - Layout.horizontalInset)
        var lines: [String] = []
        var current = ""

        for fragment in fragments {
            let candidate = current.isEmpty ? fragment : current + Layout.separator + fragment
            if current.isEmpty || width(of: candidate) <= available {
                current = candidate
            } else {
                lines.append(current)
                current = fragment
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// Exposes the component's semantic breakpoints without making tests infer them from pixels.
    /// The production layout still has one owner: this is a read-only projection of that result.
    func wrappedLinesForTesting(atWidth width: CGFloat) -> [String] {
        lineStrings(for: width)
    }

    private func contentHeight(lineCount: Int) -> CGFloat {
        CGFloat(max(1, lineCount)) * lineHeight
            + CGFloat(max(0, lineCount - 1)) * Layout.lineGap
    }

    override var intrinsicContentSize: NSSize {
        let naturalWidth = textLeadingInset + naturalTextWidth + Layout.horizontalInset
        let measuringWidth = bounds.width > 0 ? bounds.width : naturalWidth
        let count = lineStrings(for: measuringWidth).count
        return NSSize(
            width: naturalWidth,
            height: contentHeight(lineCount: count) + Layout.verticalInset * 2
        )
    }

    override func layout() {
        super.layout()
        let count = lineStrings(for: bounds.width).count
        guard count != measuredLineCount else { return }
        measuredLineCount = count
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let corner = Design.Radius.control(fitting: bounds.size)
        let focusShape: ThemedSurface.Shape
        if isHovered || isPressed {
            focusShape = ThemedSurface.draw(
                bounds,
                fill: hoverFill ?? Design.Surface.controlHover,
                radius: corner
            )
        } else {
            focusShape = ThemedSurface.Shape(rect: bounds, radius: corner)
        }
        drawKeyboardFocus(around: focusShape)

        let lines = lineStrings(for: bounds.width)
        let textHeight = contentHeight(lineCount: lines.count)
        let top = bounds.midY + textHeight / 2
        let availableWidth = max(0, bounds.maxX - Layout.horizontalInset - textLeadingInset)

        for (index, line) in lines.enumerated() {
            let lineTop = top - CGFloat(index) * (lineHeight + Layout.lineGap)
            (line as NSString).draw(
                in: NSRect(
                    x: textLeadingInset,
                    y: lineTop - lineHeight,
                    width: availableWidth,
                    height: lineHeight
                ),
                withAttributes: textAttributes
            )
        }

        if let image {
            let firstLineTop = top
            let rect = NSRect(
                x: Layout.horizontalInset,
                y: firstLineTop - lineHeight / 2 - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: isEnabled ? 1 : Layout.disabledAlpha,
                respectFlipped: true,
                hints: nil
            )
        }
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isPressed = true
        pressedTarget = target
        pressedAction = action
        beginWatchingForRelease()
    }

    private func beginWatchingForRelease() {
        releaseWatch.remove()
        guard let window else { return }
        pressTarget = window.convertToScreen(convert(bounds, to: nil))
        releaseWatch.install(matching: [.leftMouseUp, .leftMouseDragged, .leftMouseDown]) {
            [weak self] event in
            self?.track(event)
            return event
        }
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

    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func completePress(firing shouldFire: Bool) {
        let sentTarget = pressedTarget
        let sentAction = pressedAction
        pressedTarget = nil
        pressedAction = nil
        isPressed = false
        releaseWatch.remove()
        guard shouldFire, isEnabled else { return }
        sendAction(sentAction, to: sentTarget)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        completePress(
            firing: isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        )
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled, action != nil else { return false }
        sendAction(action, to: target)
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? {
        fragments.isEmpty ? nil : fragments.joined(separator: Layout.separator)
    }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    // MARK: - Optical layout

    var opticalHorizontalInset: CGFloat { Layout.horizontalInset }

    func opticalVerticalInset(forFrameHeight frameHeight: CGFloat) -> CGFloat {
        max(0, (frameHeight - contentHeight(lineCount: lineStrings(for: bounds.width).count)) / 2)
    }
}
