#if os(Linux)
import AppKit
import Glibc
import LinuxWindowBridge
@testable import CoreSlice

/// The General destination in the workspace Settings detour. The SDL pane supplies only the
/// viewport; its canvas, card, and adaptive controls use the same constraints as macOS.
@MainActor
final class WorkspaceSettingsPane: WorkspacePane {
    let chrome = WorkspacePaneChrome(pageName: "Settings", pageIdentity: "settings.general",
                                      onReveal: {})
    var title: String { "Threading - Settings" }
    var needsPolling: Bool { false }
    var onDone: (() -> Void)?

    private let owner = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
    private let root = NSView(frame: .zero)
    private let page = NSView(frame: .zero)
    private let scroll = ThemedScrollView(frame: .zero)
    private let document = SettingsDocumentView(frame: .zero)
    private let done = ThemedButton()
    private var toggles: [(ConfirmationPrompt, ThemedToggle)] = []
    private var presentedSize = NSSize.zero
    private var displayRevision: UInt64 = 0
    private var needsPresentation = true

    init() {
        LinuxSymbols.install()
        owner.contentView = root
        buildPage()
        setThemeAppearance()
    }

    func takeInitialViewport() -> (Int, Int)? { nil }

    private func buildPage() {
        let heading = NSTextField(labelWithString: "General")
        heading.font = Design.Typography.heading()
        heading.textColor = Design.Text.label

        done.title = "Done"
        done.emphasis = .secondary
        done.action = { [weak self] in self?.onDone?() }

        let header = NSStackView(views: [heading, NSView(), done])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = Design.Spacing.small
        header.translatesAutoresizingMaskIntoConstraints = false
        let separator = SeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false

        let section = NSTextField(labelWithString: "CONFIRMATIONS")
        section.font = Design.Typography.subheading()
        section.textColor = Design.Text.secondary
        let rows = ConfirmationPrompt.suppressible.compactMap { prompt -> NSView? in
            guard let copy = prompt.suppression else { return nil }
            let toggle = ThemedToggle()
            toggle.state = LinuxConfirmationSettings.asks(before: prompt) ? .on : .off
            toggle.setAccessibilityIdentifier("settings.general.confirmation.\(prompt.rawValue)")
            toggle.action = { [weak self, weak toggle] in
                guard let toggle else { return }
                let asks = toggle.state == .on
                LinuxConfirmationSettings.setAsks(asks, before: prompt)
                print("SETTINGS_CONFIRMATION_CHANGED \(prompt.rawValue) asks=\(asks)")
                fflush(nil)
                self?.needsPresentation = true
            }
            toggles.append((prompt, toggle))
            return makeRow(title: copy.settingsTitle, subtitle: copy.settingsSubtitle,
                           control: toggle)
        }
        let card = SettingsCard(rows: rows)
        let sections = NSStackView(views: [section, card])
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = Design.Spacing.small
        sections.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sections)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(header)
        page.addSubview(separator)
        page.addSubview(scroll)
        SettingsPageCanvasLayout.install(page: page, in: root)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: page.topAnchor, constant: Design.Spacing.large),
            header.leadingAnchor.constraint(equalTo: page.leadingAnchor,
                                            constant: Design.Size.glowGutter),
            header.trailingAnchor.constraint(equalTo: page.trailingAnchor,
                                             constant: -Design.Size.glowGutter),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor,
                                           constant: Design.Spacing.medium),
            separator.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            sections.topAnchor.constraint(equalTo: document.topAnchor,
                                          constant: Design.Spacing.large),
            sections.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                              constant: Design.Size.glowGutter),
            sections.trailingAnchor.constraint(equalTo: document.trailingAnchor,
                                               constant: -Design.Size.glowGutter),
            sections.bottomAnchor.constraint(equalTo: document.bottomAnchor,
                                             constant: -Design.Spacing.large),
            card.widthAnchor.constraint(equalTo: sections.widthAnchor)
        ])

        for index in toggles.indices {
            toggles[index].1.nextKeyView = index + 1 < toggles.count
                ? toggles[index + 1].1 : done
        }
        done.nextKeyView = toggles.first?.1
    }

    private func makeRow(title: String, subtitle: String, control: ThemedToggle) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = Design.Typography.body()
        name.textColor = Design.Text.label
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let explanation = NSTextField(wrappingLabelWithString: subtitle)
        explanation.font = Design.Typography.subheading()
        explanation.textColor = Design.Text.secondary
        explanation.setContentHuggingPriority(.init(1), for: .horizontal)
        let labels = NSStackView(views: [name, explanation])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pin = explanation.widthAnchor.constraint(equalTo: labels.widthAnchor)
        pin.priority = .init(NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        let floor = explanation.widthAnchor.constraint(
            greaterThanOrEqualToConstant: SettingsAdaptiveControlMetrics.minimumTextWidth)
        floor.priority = .defaultHigh
        NSLayoutConstraint.activate([pin, floor])
        control.setContentHuggingPriority(.required, for: .horizontal)
        let adaptive = SettingsAdaptiveControlRow(labels: labels, control: control)
        let container = NSView()
        adaptive.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(adaptive)
        let sides = [
            adaptive.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                              constant: Design.Spacing.inset),
            adaptive.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                               constant: -Design.Spacing.inset)
        ]
        NSLayoutConstraint.activate(sides + [
            adaptive.topAnchor.constraint(equalTo: container.topAnchor,
                                          constant: Design.Spacing.medium),
            adaptive.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                             constant: -Design.Spacing.medium),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        container.holdAtContentInset(sides)
        return container
    }

    func setThemeAppearance() {
        root.appearance = LinuxTheme.appearance
        chrome.setThemeAppearance()
        needsPresentation = true
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        // The pane has focusable controls but no text editor. This bridge mode forwards Space,
        // Tab and Return to their real AppKit responders instead of the terminal key path.
        _ = tw_workspace_composer_mode(window, focused ? 1 : 0)
        chrome.focus(focused, window: window)
        owner.isKeyWindow = focused
        if focused {
            _ = owner.makeFirstResponder(toggles.first?.1 ?? done)
            tw_title(window, title)
        } else {
            owner.cancelPointerGesture()
            _ = owner.makeFirstResponder(nil)
        }
        needsPresentation = true
    }

    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int,
                 focused: Bool) throws {
        try chrome.refresh(window: window, width: width, height: height, originX: originX)
        let contentHeight = max(1, height - WorkspacePaneChrome.headerPixelHeight)
        let scale = WorkspaceDisplay.scale
        let size = NSSize(width: CGFloat(width) / scale,
                          height: CGFloat(contentHeight) / scale)
        guard needsPresentation || size != presentedSize ||
                displayRevision != owner.displayRevision else { return }
        root.frame = NSRect(origin: .zero, size: size)
        owner.layoutIfNeeded()
        let bitmap = Bitmap(width: width, height: contentHeight,
                            background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_pane(window, $0.baseAddress, Int32(width), Int32(contentHeight), 0)
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        if focused { tw_title(window, title) }
        presentedSize = size
        displayRevision = owner.displayRevision
        needsPresentation = false
    }

    func handle(_ input: TWEvent, window: OpaquePointer) {
        if input.kind == 7 || input.kind == 48 {
            guard input.action != 3 else { return }
            let key = WindowHarness.composerKeyEvent(input)
            if key.keyCode == 48 {
                let current = owner.firstResponder as? NSView
                let next = input.modifiers & 1 != 0
                    ? current?.previousValidKeyView : current?.nextValidKeyView
                if let next { _ = owner.makeFirstResponder(next) }
            } else {
                _ = owner.dispatchToContent(key)
            }
            needsPresentation = true
            return
        }
        let type: NSEvent.EventType
        switch input.kind {
        case 15 where input.key == 0:
            type = input.action == 1 ? .leftMouseDown : .leftMouseUp
        case 17: type = .leftMouseDragged
        case 16: type = .scrollWheel
        default: return
        }
        let scale = WorkspaceDisplay.scale
        let pointer = NSEvent(type: type, locationInWindow: NSPoint(
            x: CGFloat(input.x) / scale,
            y: root.bounds.height - CGFloat(input.y) / scale),
            scrollingDeltaY: CGFloat(input.key))
        _ = owner.dispatchToContent(pointer)
        needsPresentation = true
    }
}

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
#endif
