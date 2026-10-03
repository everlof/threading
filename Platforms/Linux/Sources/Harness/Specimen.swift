import AppKit
import Foundation

/// Diagnostic assembly using production drawing leaves vendored byte-identically from
/// `Sources/Threading/UI/Design/`. The shim supplies AppKit geometry and raster operations;
/// `./vendor.sh --verify` proves the shared painters have not been adapted for Linux.
@MainActor
enum Specimen {
    static let bodyGround = NSColor(white: 0.87, alpha: 1)
    static let headerGround = NSColor(white: 0.78, alpha: 1)
    static let navigatorRowGeometry = NavigatorRowGeometry(
        leadingInset: 4, iconSlotWidth: 16, contentGap: 6)

    private final class ArrowEvent: NSEvent {
        private let code: UInt16
        init(_ code: UInt16) { self.code = code; super.init() }
        override var keyCode: UInt16 { code }
    }

    private final class KeySink: NSView {
        var deliveredKeys: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            deliveredKeys.append(event.charactersIgnoringModifiers ?? "")
        }
    }

    private final class KeyEquivalentControl: NSControl {
        var activations = 0
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.charactersIgnoringModifiers == "\r" else { return false }
            activations += 1
            return true
        }
    }

    private static func verifyKeyEquivalentDispatch() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        let controlBranch = NSView(frame: root.bounds)
        let equivalent = KeyEquivalentControl(frame: NSRect(x: 0, y: 0, width: 30, height: 20))
        let focused = KeySink(frame: NSRect(x: 40, y: 0, width: 30, height: 20))
        root.addSubview(controlBranch)
        controlBranch.addSubview(equivalent)
        root.addSubview(focused)
        let owner = NSWindow()
        owner.contentView = root
        precondition(owner.makeFirstResponder(focused))

        func key(_ character: String) -> NSEvent {
            NSEvent(type: .keyDown, window: owner, charactersIgnoringModifiers: character)
        }
        _ = owner.dispatchToContent(key("\r"))
        precondition(equivalent.activations == 1 && focused.deliveredKeys.isEmpty,
                     "key equivalent did not consume Return before first-responder delivery")

        _ = owner.dispatchToContent(key("x"))
        precondition(equivalent.activations == 1 && focused.deliveredKeys == ["x"],
                     "unclaimed key bypassed the focused responder")

        controlBranch.isHidden = true
        _ = owner.dispatchToContent(key("\r"))
        precondition(equivalent.activations == 1 && focused.deliveredKeys == ["x", "\r"],
                     "a key equivalent inside a hidden pane answered Return")

        controlBranch.isHidden = false
        root.isHidden = true
        _ = owner.dispatchToContent(key("\r"))
        precondition(equivalent.activations == 1,
                     "a hidden content root still offered its key equivalents")
        root.isHidden = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in nil }
        precondition(monitor != nil)
        _ = owner.dispatchToContent(key("\r"))
        NSEvent.removeMonitor(monitor!)
        precondition(equivalent.activations == 1 && focused.deliveredKeys.count == 3,
                     "a consumed local key event reached content")
        print("PASS window key equivalents precede focused keys and skip hidden or consumed events")
    }

    /// Resolve once for each painted ground, then share the same role values with bitmap,
    /// template-image and native shaped-text consumers. These are fixed diagnostic grounds,
    /// not a theme engine or a fallback for unsupported platform colors.
    struct Ink {
        let label: NSColor
        let secondary: NSColor

        init(on ground: NSColor) {
            guard let resolved = NeutralInk.resolve(
                on: .init(red: ground.redComponent, green: ground.greenComponent,
                          blue: ground.blueComponent, alpha: ground.alphaComponent),
                increasedContrast: false,
                readingRatio: TextLegibilityPolicy.readingRatio,
                glanceRatio: TextLegibilityPolicy.glanceRatio,
                strengthSteps: TextLegibilityPolicy.strengthSteps
            ) else {
                preconditionFailure("Diagnostic ink requires a supported normalized ground")
            }
            let base: CGFloat = resolved.base == .white ? 1 : 0
            label = NSColor(white: base, alpha: resolved.label.alpha)
            secondary = NSColor(white: base, alpha: resolved.secondary.alpha)
        }
    }

    final class Window: NSView {
        static let titleHeight: CGFloat = 26
        var headerHeight: CGFloat = Window.titleHeight
        var hasMountedHeader = false
        var title = "Threading on Linux"
        var separatesScratchpad = false
        let bodyInk = Ink(on: Specimen.bodyGround)
        let headerInk = Ink(on: Specimen.headerGround)
        private let rowLayer = NSView(frame: .zero)
        private let textLayer = NoninteractiveTextLayer(frame: .zero)
        private let menuLayer = MenuRowLayer(frame: .zero)
        private var mountedRows: [Row] = []
        private var mountedMenuRows: [NSView] = []
        private var nextRowSlot = 0
        private var mountedLabels: [NSTextField] = []
        private var activatedRowSlot: Int?
        private var activatedProjectActionID: String?
        private var activatedProjectCreateID: String?
        private var projectControlVisualChanged = false
        private var navigationStep: Int?

        /// Labels are painted over rows but do not take their press; the row owns selection.
        private final class NoninteractiveTextLayer: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        private final class MenuRowLayer: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? {
                let target = super.hitTest(point)
                return target === self ? nil : target
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            rowLayer.frame = bounds
            textLayer.frame = bounds
            menuLayer.frame = bounds
            addSubview(rowLayer)
            addSubview(textLayer)
            addSubview(menuLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The native host retains this root for the SDL window's lifetime. View slots are
        /// bounded by the viewport and reused through selection and resize.
        func prepareNavigatorFrame(_ rect: NSRect) {
            if frame != rect { frame = rect }
            if rowLayer.frame != bounds { rowLayer.frame = bounds }
            if textLayer.frame != bounds { textLayer.frame = bounds }
            if menuLayer.frame != bounds { menuLayer.frame = bounds }
            nextRowSlot = 0
        }

        /// Menu rows come from the production design component. The host supplies only the
        /// bounded visible page and retains command identity in its own presentation model.
        func mountMenuRows(_ rows: [NSView]) {
            for row in mountedMenuRows { row.removeFromSuperview() }
            mountedMenuRows = rows
            for row in rows { menuLayer.addSubview(row) }
        }

        func mountedMenuRow(at slot: Int) -> NSView? {
            guard mountedMenuRows.indices.contains(slot) else { return nil }
            return mountedMenuRows[slot]
        }

        func mountNavigatorRow(frame: NSRect, accent: NSColor, selected: Bool, ink: Ink,
                               image: NSImage? = nil, showsMark: Bool = true,
                               disclosure: DisclosureTriangleDrawing.Direction? = nil,
                               imageSide: CGFloat = 13,
                               projectActionID: String? = nil,
                               revealsProjectAction: Bool = false,
                               projectActionEnabled: Bool = true) {
            if nextRowSlot == mountedRows.count {
                let slot = nextRowSlot
                let row = Row(frame: frame, text: "", accent: accent, selected: selected,
                              ink: ink, image: image, showsMark: showsMark,
                              disclosure: disclosure, imageSide: imageSide)
                row.onPress = { [weak self] in self?.activatedRowSlot = slot }
                row.onNavigation = { [weak self] step in self?.navigationStep = step }
                row.onProjectAction = { [weak self] id in self?.activatedProjectActionID = id }
                row.onProjectCreate = { [weak self] id in self?.activatedProjectCreateID = id }
                row.onProjectControlVisualChange = { [weak self] in
                    self?.projectControlVisualChanged = true
                }
                rowLayer.addSubview(row)
                mountedRows.append(row)
            } else {
                mountedRows[nextRowSlot].configure(frame: frame, accent: accent,
                    selected: selected, ink: ink, image: image, showsMark: showsMark,
                    disclosure: disclosure, imageSide: imageSide)
            }
            mountedRows[nextRowSlot].configureProjectControls(
                id: projectActionID, revealed: revealsProjectAction,
                enabled: projectActionEnabled)
            if mountedRows[nextRowSlot].isHidden { mountedRows[nextRowSlot].isHidden = false }
            nextRowSlot += 1
        }

        #if THREADING_WINDOW_HARNESS
        /// The visible project slot mounts the same native row subtree used by the Mac cell.
        /// Slot identity and actions remain with the host's bounded navigator model.
        func mountProjectContent(
            presentation: NavigatorProjectRowPresentation, icon: NSImage?, count: Int,
            projectID: String?, revealed: Bool, enabled: Bool
        ) {
            guard nextRowSlot > 0 else { return }
            mountedRows[nextRowSlot - 1].configureProductionProject(
                presentation: presentation, icon: icon, count: count,
                projectID: projectID, revealed: revealed, enabled: enabled)
        }

        /// Mount the same default session content that the Mac sidebar places inside its
        /// extension container. The host retains row identity and the adjacent status text.
        func mountSessionContent(title: String, icon: NSImage?, selected: Bool,
                                 trailingInset: CGFloat) {
            guard nextRowSlot > 0 else { return }
            mountedRows[nextRowSlot - 1].configureProductionSession(
                title: title, icon: icon, selected: selected, trailingInset: trailingInset)
        }
        #endif

        func finishNavigatorRows() {
            for index in nextRowSlot..<mountedRows.count { mountedRows[index].isHidden = true }
        }

        func takeActivatedRowSlot() -> Int? {
            defer { activatedRowSlot = nil }
            return activatedRowSlot
        }

        func takeActivatedProjectActionID() -> String? {
            defer { activatedProjectActionID = nil }
            return activatedProjectActionID
        }

        func takeActivatedProjectCreateID() -> String? {
            defer { activatedProjectCreateID = nil }
            return activatedProjectCreateID
        }

        func takeProjectControlVisualChange() -> Bool {
            defer { projectControlVisualChanged = false }
            return projectControlVisualChanged
        }

        func mountedRow(at slot: Int) -> Row? {
            guard slot >= 0, slot < nextRowSlot, !mountedRows[slot].isHidden else { return nil }
            return mountedRows[slot]
        }

        #if THREADING_WINDOW_HARNESS
        func projectControl(at slot: Int, create: Bool) -> NSView? {
            mountedRow(at: slot)?.productionProjectControl(create: create)
        }
        #endif

        func takeNavigationStep() -> Int? {
            defer { navigationStep = nil }
            return navigationStep
        }

        func navigatorLabel(at index: Int) -> NSTextField {
            if index < mountedLabels.count { return mountedLabels[index] }
            precondition(index == mountedLabels.count)
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            // The SDL/AT-SPI list publishes the authoritative row identity and action.
            label.setAccessibilityElement(false)
            textLayer.addSubview(label)
            mountedLabels.append(label)
            return label
        }

        func finishNavigatorLabels(visibleCount: Int) {
            for index in visibleCount..<mountedLabels.count {
                mountedLabels[index].isHidden = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            Specimen.bodyGround.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            if separatesScratchpad {
                // The third Add Project choice owns no project folder. Keep its visual
                // separation in this diagnostic shell, outside all actionable row bounds.
                bodyInk.secondary.setFill()
                NSRect(x: bounds.minX + 8, y: bounds.maxY - headerHeight - 49,
                       width: max(0, bounds.width - 16), height: 0.5).fill()
            }
            // Title bar.
            let bar = NSRect(x: bounds.minX, y: bounds.maxY - headerHeight,
                             width: bounds.width, height: headerHeight)
            Specimen.headerGround.setFill()
            bar.fill()
            NSColor(white: 0.45, alpha: 1).setStroke()
            let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            frame.lineWidth = 1
            frame.stroke()

            // An em-dash is not in the face, and the real file answers that by returning false
            // rather than drawing a blank — which is exactly what it did here on the first run.
            guard !hasMountedHeader else { return }
            PlatinumBitmapFont.draw(
                title,
                penX: bounds.minX + 12,
                baselineFromTop: 18,
                in: bar,
                ink: headerInk.label
            )
        }
    }

    /// Bounded diagnostic prose, using the same measured bitmap face as the specimen rows.
    final class Message: NSView {
        private static let maximumScalars = 1024
        private static let lineHeight: CGFloat = 16
        let text: String
        let ink: NSColor

        init(frame: NSRect, text: String, ink: NSColor) {
            self.ink = ink
            self.text = String(text.unicodeScalars.prefix(Self.maximumScalars))
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            NSBezierPath(rect: bounds).addClip()
            let maximumLines = max(1, Int(bounds.height / Self.lineHeight))
            var lines = [String](), line = "", advance = 0
            for scalar in text.unicodeScalars {
                let glyph = scalar.value >= 32 && scalar.value <= 126 ? String(scalar) : "?"
                let glyphAdvance = PlatinumBitmapFont.advance(of: glyph) ?? 0
                if scalar == "\n" || advance + glyphAdvance > Int(bounds.width) {
                    if scalar != "\n", let space = line.lastIndex(of: " ") {
                        lines.append(String(line[..<space]))
                        line = String(line[line.index(after: space)...])
                        advance = PlatinumBitmapFont.advance(of: line) ?? 0
                    } else {
                        lines.append(line); line = ""; advance = 0
                    }
                    if lines.count == maximumLines { break }
                    if scalar == "\n" { continue }
                }
                if glyph == " " && line.isEmpty { continue }
                line += glyph; advance += glyphAdvance
            }
            if lines.count < maximumLines { lines.append(line) }
            else { lines[maximumLines - 1] = "..." }
            for (index, value) in lines.enumerated() {
                PlatinumBitmapFont.draw(value, penX: 0,
                    baselineFromTop: CGFloat(index + 1) * Self.lineHeight - 2,
                    in: bounds, ink: ink)
            }
        }
    }

    final class Row: NSView {
        private static let selectionRadius: CGFloat = 5
        let text: String
        private(set) var accent: NSColor
        private(set) var selected: Bool
        private(set) var ink: Ink
        private(set) var image: NSImage?
        private(set) var showsMark: Bool
        private(set) var disclosure: DisclosureTriangleDrawing.Direction?
        private var iconView: GlyphView?
        #if THREADING_WINDOW_HARNESS
        private var productionProjectView: ThemedProjectRowView?
        private var productionSessionView: ThemedSessionRowContentView?
        private var productionProjectActionsRevealed = false
        private var projectCreateButton: ThemedIconButton?
        private var projectActionButton: ThemedIconButton?
        #endif
        var onPress: (() -> Void)?
        var onNavigation: ((Int) -> Void)?
        var onProjectAction: ((String) -> Void)?
        var onProjectCreate: ((String) -> Void)?
        var onProjectControlVisualChange: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        init(frame: NSRect, text: String, accent: NSColor, selected: Bool, ink: Ink,
             image: NSImage? = nil, showsMark: Bool = true,
             disclosure: DisclosureTriangleDrawing.Direction? = nil,
             imageSide: CGFloat = 13) {
            self.text = text
            self.accent = accent
            self.selected = selected
            self.ink = ink
            self.image = image
            self.showsMark = showsMark
            self.disclosure = disclosure
            if let image {
                let view = GlyphView()
                // Navigator rows position their marks with measured fixed frames.
                view.translatesAutoresizingMaskIntoConstraints = true
                view.frame = Specimen.navigatorRowGeometry.iconRect(
                    in: NSRect(origin: .zero, size: frame.size), side: imageSide)
                view.image = image
                view.slot = view.frame.size
                view.tint = ink.label
                iconView = view
            } else {
                iconView = nil
            }
            super.init(frame: frame)
            if let iconView { addSubview(iconView) }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) { onPress?() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let target = super.hitTest(point)
            #if THREADING_WINDOW_HARNESS
            if productionSessionView?.isHidden == false { return self }
            guard let productionProjectView, !productionProjectView.isHidden,
                  let target else { return target }
            if !productionProjectActionsRevealed { return self }
            var ancestor: NSView? = target
            while let view = ancestor, view !== self {
                if view === productionProjectView.createButton ||
                   view === productionProjectView.actionButton { return target }
                ancestor = view.superview
            }
            return self
            #else
            return target
            #endif
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: onNavigation?(-1)
            case 125: onNavigation?(1)
            default: super.keyDown(with: event)
            }
        }

        func configure(frame: NSRect, accent: NSColor, selected: Bool, ink: Ink,
                       image: NSImage?, showsMark: Bool,
                       disclosure: DisclosureTriangleDrawing.Direction?, imageSide: CGFloat = 13) {
            if self.frame != frame { self.frame = frame }
            self.accent = accent
            self.selected = selected
            self.ink = ink
            self.image = image
            self.showsMark = showsMark
            self.disclosure = disclosure
            #if THREADING_WINDOW_HARNESS
            productionProjectView?.isHidden = true
            productionSessionView?.isHidden = true
            #endif
            if let image {
                let iconFrame = Specimen.navigatorRowGeometry.iconRect(in: bounds, side: imageSide)
                if iconView == nil {
                    let view = GlyphView()
                    view.translatesAutoresizingMaskIntoConstraints = true
                    view.frame = iconFrame
                    view.slot = iconFrame.size
                    addSubview(view)
                    iconView = view
                }
                if iconView?.frame != iconFrame { iconView?.frame = iconFrame }
                if iconView?.slot != iconFrame.size { iconView?.slot = iconFrame.size }
                if iconView?.image !== image { iconView?.image = image }
                iconView?.tint = ink.label
                iconView?.isHidden = false
            } else {
                iconView?.isHidden = true
            }
            needsDisplay = true
        }

        func configureProjectControls(id: String?, revealed: Bool, enabled: Bool) {
            #if THREADING_WINDOW_HARNESS
            guard let id else {
                projectCreateButton?.onPress = nil
                projectCreateButton?.isHidden = true
                projectActionButton?.onPress = nil
                projectActionButton?.isHidden = true
                return
            }
            if projectCreateButton == nil {
                let button = ThemedIconButton(
                    symbolName: "plus", accessibility: "New chat or terminal", target: .inline,
                    inkSource: .chrome, glyphMaterialization: .deferred)
                button.translatesAutoresizingMaskIntoConstraints = true
                button.presentsMenu = true
                button.surfaceStateDidChange = { [weak self] in
                    self?.onProjectControlVisualChange?()
                }
                projectCreateButton = button
                addSubview(button)
            }
            if projectActionButton == nil {
                let button = ThemedIconButton(
                    symbolName: "ellipsis", accessibility: "Project actions", target: .inline,
                    inkSource: .chrome, glyphMaterialization: .deferred)
                button.translatesAutoresizingMaskIntoConstraints = true
                button.presentsMenu = true
                button.surfaceStateDidChange = { [weak self] in
                    self?.onProjectControlVisualChange?()
                }
                projectActionButton = button
                addSubview(button)
            }
            guard let create = projectCreateButton, let actions = projectActionButton else { return }
            // ProjectRowView keeps two 20-point inline targets with a 2-point gap. The
            // trailing target stays six points from the edge; only visible rows own them.
            let actionX = max(0, bounds.maxX - 26)
            let buttonY = (bounds.height - 20) / 2
            create.frame = NSRect(x: max(0, actionX - 22), y: buttonY,
                                  width: 20, height: 20)
            actions.frame = NSRect(x: actionX, y: buttonY, width: 20, height: 20)
            create.onPress = { [weak self, id] in self?.onProjectCreate?(id) }
            actions.onPress = { [weak self, id] in self?.onProjectAction?(id) }
            for button in [create, actions] {
                button.isEnabled = enabled
                button.alphaValue = revealed ? 1 : 0
                if revealed { button.materializeGlyphIfNeeded() }
                button.isHidden = false
            }
            #endif
        }

        #if THREADING_WINDOW_HARNESS
        func configureProductionSession(title: String, icon: NSImage?, selected: Bool,
                                        trailingInset: CGFloat) {
            let content: ThemedSessionRowContentView
            if let productionSessionView {
                content = productionSessionView
            } else {
                content = ThemedSessionRowContentView(frame: bounds)
                content.translatesAutoresizingMaskIntoConstraints = true
                addSubview(content)
                productionSessionView = content
            }
            let leading = SidebarRowDefaults.leadingInset
            let width = max(0, bounds.width - leading - trailingInset)
            let frame = NSRect(x: leading, y: 0, width: width, height: bounds.height)
            if content.frame != frame { content.frame = frame }
            content.setTitle(title)
            content.setIcon(icon)
            content.setSelection(selected)
            content.isHidden = false
            iconView?.isHidden = true
        }

        func productionProjectControl(create: Bool) -> NSView? {
            guard let productionProjectView, !productionProjectView.isHidden else { return nil }
            return create ? productionProjectView.createButton : productionProjectView.actionButton
        }

        func configureProductionProject(
            presentation: NavigatorProjectRowPresentation, icon: NSImage?, count: Int,
            projectID: String?, revealed: Bool, enabled: Bool
        ) {
            let content: ThemedProjectRowView
            if let productionProjectView {
                content = productionProjectView
            } else {
                content = ThemedProjectRowView(frame: bounds)
                content.translatesAutoresizingMaskIntoConstraints = true
                content.createButton.surfaceStateDidChange = { [weak self] in
                    self?.onProjectControlVisualChange?()
                }
                content.actionButton.surfaceStateDidChange = { [weak self] in
                    self?.onProjectControlVisualChange?()
                }
                addSubview(content)
                productionProjectView = content
            }
            if content.frame != bounds { content.frame = bounds }
            content.isHidden = false
            content.configure(presentation, icon: icon, count: count,
                              moreSymbol: projectID == nil ? nil : SidebarRowDefaults.actionSymbol,
                              showsCreate: projectID != nil)
            content.setSelection(selected)
            content.setHoverControlsVisible(revealed, animated: false)
            productionProjectActionsRevealed = revealed
            content.createButton.isEnabled = enabled
            content.actionButton.isEnabled = enabled
            content.onCreatePress = { [weak self, projectID] _ in
                guard let projectID else { return }
                self?.onProjectCreate?(projectID)
            }
            content.onActionPress = { [weak self, projectID] _ in
                guard let projectID else { return }
                self?.onProjectAction?(projectID)
            }
            iconView?.isHidden = true
        }
        #endif

        override func draw(_ dirtyRect: NSRect) {
            NSBezierPath(rect: bounds).addClip()
            if selected {
                SurfaceDrawing.draw(bounds, fill: accent,
                                    radius: Self.selectionRadius, borderWidth: 0)
            }
            if image == nil && showsMark {
                ink.label.setFill()
                NSBezierPath(ovalIn: Specimen.navigatorRowGeometry.iconRect(in: bounds, side: 8)).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: Specimen.navigatorRowGeometry.titleRect(
                in: bounds, trailingInset: 6)).addClip()
            PlatinumBitmapFont.draw(
                text,
                penX: Specimen.navigatorRowGeometry.titleLeadingOffset,
                baselineFromTop: bounds.height / 2 + 4,
                in: bounds,
                ink: ink.label
            )
            NSGraphicsContext.restoreGraphicsState()
            if let disclosure {
                DisclosureTriangleDrawing.draw(
                    in: NSRect(x: bounds.maxX - 14, y: bounds.midY - 5, width: 10, height: 10),
                    ink: ink.label, direction: disclosure)
            }
        }
    }

    static func run(into directory: String) throws {
        let window = Window(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        let rows = [
            ("AnotherTerminal", true),
            ("ptyd on linux", false),
            ("AppKit shim spike", false),
            ("scaling gate", false)
        ]
        let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        let selectedInk = Ink(on: accent)
        for (index, row) in rows.enumerated() {
            let y = window.frame.height - 26 - 24 - CGFloat(index) * 24
            window.addSubview(Row(
                frame: NSRect(x: 6, y: y, width: window.frame.width - 12, height: 22),
                text: row.0,
                accent: accent,
                selected: row.1,
                ink: row.1 ? selectedInk : window.bodyInk
            ))
        }
        try render(window, scale: 3, background: NSColor(white: 0.55, alpha: 1), to: directory + "/specimen.png")

        // A viewport slot can change from a normal row to shorter chrome and back. Its image
        // child must follow the current row height without replacing the retained view.
        let reusedWindow = Window(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        let mark = NSImage(rgba: Array(repeating: [UInt8(0), 0, 0, 255], count: 13 * 13)
            .flatMap { $0 }, width: 13, height: 13)!
        mark.isTemplate = true
        let firstFrame = NSRect(x: 4, y: 8, width: 120, height: 22)
        reusedWindow.prepareNavigatorFrame(reusedWindow.frame)
        reusedWindow.mountNavigatorRow(frame: firstFrame, accent: accent, selected: true,
                                       ink: selectedInk, image: mark)
        let row = reusedWindow.subviews[0].subviews[0]
        let icon = row.subviews[0] as! GlyphView
        let firstIconFrame = icon.frame
        // The production glyph opts into Auto Layout by default. This fixed-frame row must
        // retain its 13-point mark after the real render walk invokes the layout engine.
        let bitmap = Bitmap(width: 320, height: 160, background: bodyGround.components)
        let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
        reusedWindow.render(in: context)
        precondition(icon.frame == firstIconFrame, "fixed-frame glyph moved during layout")
        let markX = Int((firstFrame.minX + icon.frame.midX) * 2)
        let markY = Int((reusedWindow.frame.height - firstFrame.minY - icon.frame.midY) * 2)
        let markOffset = (markY * bitmap.width + markX) * 4
        let groundOffset = (markY * bitmap.width + markX + 32) * 4
        let colorDifference = (0..<3).reduce(0) { total, channel in
            total + abs(Int(bitmap.pixels[markOffset + channel])
                - Int(bitmap.pixels[groundOffset + channel]))
        }
        precondition(colorDifference > 80, "template glyph did not render in navigator row")

        let tile = NSImage(rgba: Array(repeating: [UInt8(205), 36, 56, 255], count: 16 * 16)
            .flatMap { $0 }, width: 16, height: 16)!
        reusedWindow.prepareNavigatorFrame(reusedWindow.frame)
        reusedWindow.mountNavigatorRow(frame: firstFrame, accent: accent, selected: false,
                                       ink: reusedWindow.bodyInk, image: tile, imageSide: 16)
        precondition(reusedWindow.subviews[0].subviews[0] === row && row.subviews[0] === icon &&
                     icon.frame == navigatorRowGeometry.iconRect(in: row.bounds, side: 16) &&
                     icon.slot == NSSize(width: 16, height: 16),
                     "project tile did not use the full shared identity slot")
        let tileBitmap = Bitmap(width: 320, height: 160, background: bodyGround.components)
        reusedWindow.render(in: NSGraphicsContext(bitmap: tileBitmap, scale: 2))
        let tileX = Int((firstFrame.minX + icon.frame.minX + 1) * 2)
        let tileY = Int((reusedWindow.frame.height - firstFrame.minY - icon.frame.midY) * 2)
        let tileOffset = (tileY * tileBitmap.width + tileX) * 4
        let tileGroundOffset = (tileY * tileBitmap.width + tileX + 64) * 4
        let tileDifference = (0..<3).reduce(0) { total, channel in
            total + abs(Int(tileBitmap.pixels[tileOffset + channel])
                - Int(tileBitmap.pixels[tileGroundOffset + channel]))
        }
        precondition(tileDifference > 80, "16-point project tile did not paint its edge")

        let shorterFrame = NSRect(x: 4, y: 8, width: 120, height: 18)
        reusedWindow.prepareNavigatorFrame(reusedWindow.frame)
        reusedWindow.mountNavigatorRow(frame: shorterFrame, accent: accent, selected: false,
                                       ink: reusedWindow.bodyInk, image: mark)
        precondition(reusedWindow.subviews[0].subviews[0] === row &&
                     row.subviews[0] === icon && icon.frame != firstIconFrame &&
                     icon.frame == navigatorRowGeometry.iconRect(in: row.bounds, side: 13),
                     "retained row icon did not follow its changed slot height")
        let label = reusedWindow.navigatorLabel(at: 0)
        reusedWindow.finishNavigatorRows()
        reusedWindow.finishNavigatorLabels(visibleCount: 0)
        reusedWindow.prepareNavigatorFrame(reusedWindow.frame)
        precondition(reusedWindow.navigatorLabel(at: 0) === label,
                     "navigator label slot was recreated between frames")
        // Native presses enter through the retained tree. The shaped label lies above the row
        // visually but is noninteractive; an icon child forwards its press to the row owner.
        label.frame = shorterFrame
        label.isHidden = false
        let iconPoint = NSPoint(x: shorterFrame.minX + icon.frame.midX,
                                y: shorterFrame.minY + icon.frame.midY)
        precondition(reusedWindow.hitTest(iconPoint) === icon)
        reusedWindow.hitTest(iconPoint)?.mouseDown(with: NSEvent())
        precondition(reusedWindow.takeActivatedRowSlot() == 0,
                     "icon child press did not reach its mounted row")
        let textPoint = NSPoint(x: shorterFrame.maxX - 8, y: shorterFrame.midY)
        reusedWindow.hitTest(textPoint)?.mouseDown(with: NSEvent())
        precondition(reusedWindow.takeActivatedRowSlot() == 0,
                     "overlay label swallowed its mounted row's press")
        let owner = NSWindow()
        owner.contentView = reusedWindow
        precondition(owner.makeFirstResponder(row) && owner.firstResponder === row)
        owner.firstResponder?.keyDown(with: ArrowEvent(125))
        precondition(reusedWindow.takeNavigationStep() == 1,
                     "focused row did not answer Down through the responder path")
        icon.keyDown(with: ArrowEvent(126))
        precondition(reusedWindow.takeNavigationStep() == -1,
                     "icon child did not forward Up to its row")
        reusedWindow.prepareNavigatorFrame(reusedWindow.frame)
        reusedWindow.finishNavigatorRows()
        owner.makeFirstResponder(reusedWindow.mountedRow(at: 0))
        precondition(owner.firstResponder === owner,
                     "a hidden recycled row must not keep navigator focus")
        reusedWindow.hitTest(textPoint)?.mouseDown(with: NSEvent())
        precondition(reusedWindow.takeActivatedRowSlot() == nil,
                     "a hidden recycled row answered a native press")
        verifyKeyEquivalentDispatch()
        print("PASS retained navigator row/icon geometry and label slot identity")

        if let advance = PlatinumBitmapFont.advance(of: "Threading on Linux") {
            print("PlatinumBitmapFont.advance(of:) = \(advance)px — the real file's own metrics")
        }
    }
}
