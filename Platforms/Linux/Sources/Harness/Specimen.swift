import AppKit
import Foundation

/// Diagnostic assembly using production drawing leaves vendored byte-identically from
/// `Sources/Threading/UI/Design/`. The shim supplies AppKit geometry and raster operations;
/// `./vendor.sh --verify` proves the shared painters have not been adapted for Linux.
@MainActor
enum Specimen {
    #if THREADING_WINDOW_HARNESS
    static var bodyGround: NSColor { LinuxTheme.color("surface") }
    static var headerGround: NSColor { LinuxTheme.color("panel") }

    private static func resolvedGround(_ role: String) -> NSColor {
        let (red, green, blue, alpha) = LinuxTheme.components(role)
        return NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #else
    static let bodyGround = NSColor(white: 0.87, alpha: 1)
    static let headerGround = NSColor(white: 0.78, alpha: 1)
    #endif
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
        let tertiary: NSColor
        let quaternary: NSColor

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
            tertiary = NSColor(white: base, alpha: resolved.tertiary.alpha)
            quaternary = NSColor(white: base, alpha: resolved.quaternary.alpha)
        }
    }

    final class Window: NSView {
        static let titleHeight: CGFloat = 26
        var headerHeight: CGFloat = Window.titleHeight
        var hasMountedHeader = false
        var title = "Threading on Linux"
        var separatesScratchpad = false
        #if THREADING_WINDOW_HARNESS
        private(set) var bodyInk = Ink(on: Specimen.resolvedGround("surface"))
        private(set) var headerInk = Ink(on: Specimen.resolvedGround("panel"))
        private var workspaceBackdrop: SidebarBackdropView?
        private var workspaceBackdropClip: NSView?
        private var workspaceWell: NSView?
        private var workspaceContent: SidebarNavigatorContentView?
        private var workspaceFooter: NSView?
        private var mountedMenuDocument: ThemedMenuDocumentView?
        private var mountedMenuHeights: [CGFloat] = []
        #else
        let bodyInk = Ink(on: Specimen.bodyGround)
        let headerInk = Ink(on: Specimen.headerGround)
        #endif
        private let rowLayer = NSView(frame: .zero)
        private let textLayer = NoninteractiveTextLayer(frame: .zero)
        private let menuLayer = MenuRowLayer(frame: .zero)
        private var mountedRows: [Row] = []
        private var mountedMenuRows: [NSView] = []
        private var mountedFloatingMenu: NSView?
        private var nextRowSlot = 0
        private var mountedLabels: [NSTextField] = []
        private var activatedRowSlot: Int?
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
            for layer in [rowLayer, textLayer, menuLayer] {
                layer.translatesAutoresizingMaskIntoConstraints = false
                addSubview(layer)
                NSLayoutConstraint.activate([
                    layer.leadingAnchor.constraint(equalTo: leadingAnchor),
                    layer.trailingAnchor.constraint(equalTo: trailingAnchor),
                    layer.topAnchor.constraint(equalTo: topAnchor),
                    layer.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        #if THREADING_WINDOW_HARNESS
        /// The ordinary workspace uses the production sidebar region recipe. Diagnostic
        /// pickers keep their specimen ground until a workspace explicitly installs it.
        func installWorkspaceBackdrop() {
            precondition(workspaceBackdrop == nil)
            let backdrop = SidebarBackdropView()
            let backdropClip = NSView(frame: .zero)
            let well = NSView(frame: .zero)
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            backdropClip.translatesAutoresizingMaskIntoConstraints = false
            well.translatesAutoresizingMaskIntoConstraints = false
            backdropClip.addSubview(backdrop)
            addSubview(backdropClip, positioned: .below, relativeTo: rowLayer)
            addSubview(well, positioned: .above, relativeTo: backdropClip)
            let content = SidebarNavigatorContentView(frame: .zero)
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content, positioned: .above, relativeTo: rowLayer)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
            workspaceBackdrop = backdrop
            workspaceBackdropClip = backdropClip
            workspaceWell = well
            workspaceContent = content
        }

        func mountNavigatorHeader(_ header: NSView) {
            guard let workspaceContent else {
                preconditionFailure("install the workspace sidebar before its header")
            }
            workspaceContent.mountHeader(header, top: workspaceContent.topAnchor)
        }

        func mountNavigatorFooter(_ footer: NSView) {
            guard let workspaceContent else {
                preconditionFailure("install the workspace sidebar before its footer")
            }
            workspaceContent.mountFooter(footer)
            workspaceFooter = footer
        }

        func mountNavigatorEmptyState(_ emptyState: NSView, over outline: NSView,
                                      inset: CGFloat) {
            guard let workspaceContent else {
                preconditionFailure("install the workspace sidebar before its empty state")
            }
            workspaceContent.mountEmptyState(emptyState, over: outline, inset: inset)
        }

        /// The SDL host keeps this tree mounted across mode changes. Re-resolve the neutral
        /// ink outside drawing and let the appearance hook invalidate every descendant.
        func setThemeAppearance() {
            let hasBackdrop = workspaceBackdrop != nil
            bodyInk = Ink(on: Specimen.resolvedGround(hasBackdrop ? "sidebar.navigatorWell" : "surface"))
            headerInk = Ink(on: Specimen.resolvedGround(hasBackdrop ? "sidebar.gradientStart" : "panel"))
            if let workspaceWell {
                workspaceWell.setAppliedSurface(fill: SidebarAppearance.navigatorFill, radius: 0)
            }
            appearance = LinuxTheme.appearance
            needsDisplay = true
        }
        #endif

        /// The native host retains this root for the SDL window's lifetime. View slots are
        /// bounded by the viewport and reused through selection and resize.
        func prepareNavigatorFrame(_ rect: NSRect) {
            if frame != rect { frame = rect }
            nextRowSlot = 0
        }

        /// The outline owns the project viewport. The fixed slots remain for the bounded
        /// saved-runtime picker, and never sit behind an active outline.
        func setNavigatorOutline(_ scrollView: NSScrollView, below header: NSView, visible: Bool) {
            if scrollView.superview == nil {
                #if THREADING_WINDOW_HARNESS
                guard let workspaceContent else {
                    preconditionFailure("install the workspace sidebar before its outline")
                }
                workspaceContent.mountOutline(
                    scrollView, below: header,
                    bottom: workspaceFooter?.topAnchor ?? workspaceContent.bottomAnchor)
                #else
                addSubview(scrollView, positioned: .below, relativeTo: menuLayer)
                scrollView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
                    scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                    scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
                #endif
                #if THREADING_WINDOW_HARNESS
                if let clip = workspaceBackdropClip,
                   let backdrop = workspaceBackdrop,
                   let well = workspaceWell {
                    // Keep the gradient in full-column coordinates, but clip drawing to the
                    // band above the opaque navigator well.
                    NSLayoutConstraint.activate([
                        clip.topAnchor.constraint(equalTo: topAnchor),
                        clip.bottomAnchor.constraint(equalTo: header.bottomAnchor),
                        clip.leadingAnchor.constraint(equalTo: leadingAnchor),
                        clip.trailingAnchor.constraint(equalTo: trailingAnchor),
                        backdrop.topAnchor.constraint(equalTo: topAnchor),
                        backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
                        backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
                        backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
                        well.topAnchor.constraint(equalTo: header.bottomAnchor),
                        well.bottomAnchor.constraint(equalTo: bottomAnchor),
                        well.leadingAnchor.constraint(equalTo: leadingAnchor),
                        well.trailingAnchor.constraint(equalTo: trailingAnchor)
                    ])
                }
                #endif
            }
            scrollView.isHidden = !visible
            rowLayer.isHidden = visible
            textLayer.isHidden = visible
        }

        /// Menu rows come from the production design component. The host supplies only the
        /// bounded visible page and retains command identity in its own presentation model.
        /// Rows that stay visible stay mounted: detaching a row mid-press would end the
        /// gesture its release is meant to complete.
        #if THREADING_WINDOW_HARNESS
        func mountMenuRows(_ rows: [NSView], heights: [CGFloat], topInset: CGFloat) {
            precondition(rows.count == heights.count)
            if subviews.last !== menuLayer {
                addSubview(menuLayer, positioned: .above, relativeTo: nil)
            }
            mountedFloatingMenu?.removeFromSuperview()
            mountedFloatingMenu = nil
            let keepsDocument = rows.count == mountedMenuRows.count &&
                zip(rows, mountedMenuRows).allSatisfy { $0 === $1 } &&
                heights == mountedMenuHeights
            if !keepsDocument {
                mountedMenuDocument?.removeFromSuperview()
                mountedMenuDocument = nil
                if !rows.isEmpty {
                    let document = ThemedMenuDocumentView(views: rows, heights: heights)
                    menuLayer.addSubview(document)
                    mountedMenuDocument = document
                }
            }
            mountedMenuRows = rows
            mountedMenuHeights = heights
            let documentHeight = heights.reduce(0, +)
            mountedMenuDocument?.frame = NSRect(
                x: 6, y: bounds.height - topInset - documentHeight,
                width: max(1, bounds.width - 12), height: documentHeight
            )
        }
        #endif

        /// Keep an anchored menu over the standing outline, with the same production menu rows
        /// used by the navigator's older full-column menus. Retain row identity through a press.
        func mountFloatingMenu(_ surface: NSView, frame: NSRect, rows: [NSView]) {
            if subviews.last !== menuLayer {
                addSubview(menuLayer, positioned: .above, relativeTo: nil)
            }
            #if THREADING_WINDOW_HARNESS
            mountedMenuDocument?.removeFromSuperview()
            mountedMenuDocument = nil
            mountedMenuHeights.removeAll(keepingCapacity: true)
            #endif
            if mountedFloatingMenu !== surface {
                mountedFloatingMenu?.removeFromSuperview()
                mountedFloatingMenu = surface
            }
            if surface.superview !== menuLayer { menuLayer.addSubview(surface) }
            surface.frame = frame
            let kept = Set(rows.map(ObjectIdentifier.init))
            for row in mountedMenuRows where !kept.contains(ObjectIdentifier(row)) {
                row.removeFromSuperview()
            }
            mountedMenuRows = rows
            for row in rows where row.superview == nil { surface.addSubview(row) }
        }

        func mountedMenuRow(at slot: Int) -> NSView? {
            guard mountedMenuRows.indices.contains(slot) else { return nil }
            return mountedMenuRows[slot]
        }

        func mountNavigatorRow(frame: NSRect, accent: NSColor, selected: Bool, ink: Ink,
                               image: NSImage? = nil, showsMark: Bool = true,
                               disclosure: DisclosureTriangleDrawing.Direction? = nil,
                               imageSide: CGFloat = 13) {
            if nextRowSlot == mountedRows.count {
                let slot = nextRowSlot
                let row = Row(frame: frame, text: "", accent: accent, selected: selected,
                              ink: ink, image: image, showsMark: showsMark,
                              disclosure: disclosure, imageSide: imageSide)
                row.onPress = { [weak self] in self?.activatedRowSlot = slot }
                row.onNavigation = { [weak self] step in self?.navigationStep = step }
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
                                 dormant: Bool = false) {
            guard nextRowSlot > 0 else { return }
            mountedRows[nextRowSlot - 1].configureProductionSession(
                title: title, icon: icon, selected: selected, dormant: dormant)
        }

        func mountSessionStatus(_ status: String?, color: NSColor) {
            guard nextRowSlot > 0 else { return }
            mountedRows[nextRowSlot - 1].configureProductionStatus(status, color: color)
        }

        func mountSessionActivity(_ activity: NativeSessionActivity) {
            guard nextRowSlot > 0 else { return }
            mountedRows[nextRowSlot - 1].configureProductionActivity(activity)
        }

        func mountTerminalContent(title: String, icon: NSImage, selected: Bool,
                                  running: Bool) {
            guard nextRowSlot > 0 else { return }
            mountedRows[nextRowSlot - 1].configureProductionTerminal(
                title: title, icon: icon, selected: selected, running: running)
        }
        #endif

        func finishNavigatorRows() {
            for index in nextRowSlot..<mountedRows.count { mountedRows[index].isHidden = true }
        }

        func takeActivatedRowSlot() -> Int? {
            defer { activatedRowSlot = nil }
            return activatedRowSlot
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
            #if THREADING_WINDOW_HARNESS
            if workspaceBackdrop != nil { return }
            #endif
            Specimen.bodyGround.setFill()
            #if THREADING_WINDOW_HARNESS
            // This root is a pane in the native workspace. The specimen's surrounding frame
            // belongs only to the standalone drawing laboratory; the host owns the split rule.
            bounds.fill()
            #else
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            #endif
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
            #if !THREADING_WINDOW_HARNESS
            NSColor(white: 0.45, alpha: 1).setStroke()
            let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            frame.lineWidth = 1
            frame.stroke()
            #endif

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

    final class Row: NSTableCellView {
        private static let selectionRadius: CGFloat = 5
        #if THREADING_WINDOW_HARNESS
        /// The outline's production SidebarHoverRowView owns its own selection capsule.
        var drawsSelectionBackground = true { didSet { needsDisplay = true } }
        #endif
        let text: String
        private(set) var accent: NSColor
        private(set) var selected: Bool
        private(set) var ink: Ink
        private(set) var image: NSImage?
        private(set) var showsMark: Bool
        private(set) var disclosure: DisclosureTriangleDrawing.Direction?
        private var iconView: GlyphView?
        #if THREADING_WINDOW_HARNESS
        // AppKit's inset outline owns this band outside the cell. The Linux host supplies
        // its measured width; standalone specimens retain their explicit full-width layout.
        var productionTrailingInset: CGFloat = 0
        var productionLeadingInset: CGFloat = 0
        private var productionDisclosureView: GlyphView?
        private var productionDisclosureLeading: NSLayoutConstraint?
        private var productionDisclosureExpanded: Bool?
        private var productionProjectView: ThemedProjectRowView?
        private var productionProjectLeading: NSLayoutConstraint?
        private var productionProjectTrailing: NSLayoutConstraint?
        private var productionUnavailableMark: GlyphView?
        private struct ProductionContentMount {
            let slot: NSView
            let leading: NSLayoutConstraint
            let trailing: NSLayoutConstraint
            let width: NSLayoutConstraint?
        }
        private var productionSessionAssembly: SidebarSessionRowAssembly?
        private var productionSessionView: ThemedSessionRowContentView? {
            productionSessionAssembly?.visuals
        }
        private var productionSessionStack: NSStackView? {
            productionSessionAssembly?.contentStack
        }
        private var productionSessionMount: ProductionContentMount?
        private var productionSessionTrailingSlot: SidebarSessionTrailingSlot? {
            productionSessionAssembly?.trailingSlot
        }
        private var productionSessionStatusSlot: NSView? { productionSessionTrailingSlot?.statusSlot }
        private var productionSessionActivityMark: SessionStatusIndicator?
        private var productionActivityIsWorking = false
        private var productionSessionHoverControls: NSStackView? { productionSessionTrailingSlot?.hoverControls }
        private var productionSessionActionButton: ThemedIconButton? { productionSessionTrailingSlot?.actionButton }
        private var productionSessionArchiveButton: ThemedIconButton? { productionSessionTrailingSlot?.archiveButton }
        private var productionSessionPinnedIndicator: GlyphView?
        private var productionSessionActionsRevealed = false
        /// Saved-runtime picker cells draw their own selection; outline rows have an outer
        /// SidebarHoverRowView that draws the same silhouette for them.
        private var productionSidebarSelectionInset: CGFloat?
        var productionWorkingMark: SessionStatusIndicator? {
            guard let mark = productionSessionActivityMark,
                  !mark.isHidden, productionActivityIsWorking,
                  productionSessionStack?.isHidden == false else { return nil }
            return mark
        }
        private var productionTerminalAssembly: SidebarTerminalRowAssembly?
        private var productionTerminalView: ThemedTerminalRowContentView? {
            productionTerminalAssembly?.visuals
        }
        private var productionTerminalMount: ProductionContentMount?
        private var productionAttentionLabel: NSTextField?
        private var productionProjectActionsRevealed = false

        /// The production row paints selection and hover independently of recorded layer fills.
        /// Standalone specimens still paint their own explicit selection background.
        private var contentGround: NSColor {
            if selected && drawsSelectionBackground {
                return accent.composited(over: Specimen.bodyGround)
            }
            return SidebarHoverRowView.contentGround(for: self)
        }

        /// Resolve the painted face separately in each appearance before deriving live ink.
        private lazy var inkGround = NSColor(name: NSColor.Name("threading.linux.row-ground")) { [weak self] _ in
            self?.contentGround ?? Specimen.bodyGround
        }
        #endif
        var onPress: (() -> Void)?
        var onNavigation: ((Int) -> Void)?
        var onProjectAction: ((String) -> Void)?
        var onProjectCreate: ((String) -> Void)?
        var onProjectControlVisualChange: (() -> Void)?
        var onSessionAction: ((String) -> Void)?
        var onSessionArchive: ((String) -> Void)?
        var onSessionControlVisualChange: (() -> Void)?

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
            guard let target = super.hitTest(point) else { return nil }
            #if THREADING_WINDOW_HARNESS
            if productionSessionStack?.isHidden == false {
                guard productionSessionActionsRevealed else { return self }
                var ancestor: NSView? = target
                while let view = ancestor, view !== self {
                    if view === productionSessionActionButton ||
                       view === productionSessionArchiveButton { return target }
                    ancestor = view.superview
                }
                return self
            }
            if productionTerminalView?.isHidden == false { return self }
            guard let productionProjectView, !productionProjectView.isHidden else { return target }
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
                       disclosure: DisclosureTriangleDrawing.Direction?, imageSide: CGFloat = 13,
                       preserveProductionContent: Bool = false) {
            // The outline supplies its document-space row rectangle. Once AppKit has placed
            // this cell inside an NSTableRowView, its frame is local to that row shell. A
            // visible-row refresh must not move the cell out of the row's viewport geometry.
            let mountedFrame = superview is NSTableRowView
                ? NSRect(origin: .zero, size: frame.size) : frame
            if self.frame != mountedFrame { self.frame = mountedFrame }
            self.accent = accent
            self.selected = selected
            self.ink = ink
            self.image = image
            self.showsMark = showsMark
            self.disclosure = disclosure
            #if THREADING_WINDOW_HARNESS
            productionSidebarSelectionInset = nil
            if !preserveProductionContent {
                productionProjectView?.isHidden = true
                productionSessionStack?.isHidden = true
                productionTerminalView?.isHidden = true
                productionSessionMount?.slot.isHidden = true
                productionTerminalMount?.slot.isHidden = true
            }
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

        #if THREADING_WINDOW_HARNESS
        /// The platform outline gutter belongs outside the row's native content. The cell
        /// keeps the full row hit target while the shared content and marker occupy their
        /// measured AppKit slots. Only mounted, expandable rows materialize a marker.
        func configureProductionOutline(density: SidebarDensity, level: Int, expanded: Bool?) {
            let depth = CGFloat(level) * density.indentationPerLevel
            productionLeadingInset = SidebarDefaults.insetCellLeadingMargin + depth
            productionTrailingInset = SidebarDefaults.insetCellTrailingMargin - density.trailingCellReclaim
            guard let expanded else {
                productionDisclosureView?.isHidden = true
                return
            }
            let marker: GlyphView
            if let productionDisclosureView {
                marker = productionDisclosureView
            } else {
                marker = GlyphView()
                marker.translatesAutoresizingMaskIntoConstraints = false
                addSubview(marker)
                let leading = marker.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: SidebarDefaults.insetDisclosureLeading + depth)
                productionDisclosureLeading = leading
                NSLayoutConstraint.activate([
                    leading,
                    marker.centerYAnchor.constraint(equalTo: centerYAnchor),
                    marker.widthAnchor.constraint(equalToConstant: 13),
                    marker.heightAnchor.constraint(equalToConstant: 13)
                ])
                productionDisclosureView = marker
            }
            if productionDisclosureExpanded != expanded {
                marker.setSymbol(expanded ? "chevron.down" : "chevron.right",
                                 role: .chevron, weight: .semibold)
                productionDisclosureExpanded = expanded
            }
            // Match SidebarHoverRowView's marker contract: quiet chrome at rest, the
            // selected ground's label tier when the project itself is selected.
            marker.tint = selected ? ink.label : Design.Text.tertiary
            let leading = SidebarDefaults.insetDisclosureLeading + depth
            if productionDisclosureLeading?.constant != leading {
                productionDisclosureLeading?.constant = leading
            }
            marker.isHidden = false
        }

        func productionDisclosureContains(_ point: NSPoint) -> Bool {
            guard let marker = productionDisclosureView, !marker.isHidden else { return false }
            return bounds.contains(point) && point.x >= marker.frame.minX && point.x < marker.frame.maxX
        }

        private func updateProductionContent(_ mount: ProductionContentMount,
                                             leadingInset: CGFloat,
                                             trailingInset: CGFloat? = nil) {
            if mount.leading.constant != leadingInset { mount.leading.constant = leadingInset }
            let inset = trailingInset ?? productionTrailingInset + SidebarRowDefaults.trailingInset
            if mount.trailing.constant != -inset {
                mount.trailing.constant = -inset
            }
        }

        func configureProductionSession(title: String, icon: NSImage?, selected: Bool,
                                        dormant: Bool = false,
                                        isPinned: Bool = false,
                                        leadingIndent: CGFloat = 0,
                                        sessionID: String? = nil,
                                        revealsActions: Bool = false,
                                        actionSelected: Bool = false,
                                        archiveEnabled: Bool = true) {
            configureSidebarSelectionSilhouette()
            productionProjectView?.isHidden = true
            productionTerminalView?.isHidden = true
            productionTerminalMount?.slot.isHidden = true
            let content: ThemedSessionRowContentView
            if let productionSessionView {
                content = productionSessionView
            } else {
                let assembly = SidebarSessionRowAssembly()
                content = assembly.visuals
                let leading = productionLeadingInset + leadingIndent + SidebarRowDefaults.leadingInset
                let trailing = assembly.trailingSlot
                let edges = assembly.mount(in: self, leadingInset: leading,
                    trailingInset: productionTrailingInset + SidebarRowDefaults.trailingInset)
                let mount = ProductionContentMount(slot: trailing, leading: edges.leading,
                    trailing: edges.trailing, width: edges.slotWidth)
                trailing.hoverControls.isHidden = true
                trailing.actionButton.surfaceStateDidChange = { [weak self] in
                    self?.onSessionControlVisualChange?()
                }
                trailing.archiveButton.surfaceStateDidChange = { [weak self] in
                    self?.onSessionControlVisualChange?()
                }
                productionSessionMount = mount
                productionSessionAssembly = assembly
            }
            let leading = productionLeadingInset + leadingIndent + SidebarRowDefaults.leadingInset
            if let productionSessionMount {
                updateProductionContent(productionSessionMount, leadingInset: leading)
                productionSessionMount.slot.isHidden = false
            }
            productionSessionStack?.isHidden = false
            content.setTitle(title)
            content.setIcon(icon)
            content.iconView.contrastGround = { [weak self] in self?.contentGround ?? Specimen.bodyGround }
            content.setSelection(selected, dormant: dormant, on: inkGround)
            if isPinned && productionSessionPinnedIndicator == nil,
               let stack = productionSessionStack {
                let indicator = GlyphView()
                indicator.translatesAutoresizingMaskIntoConstraints = false
                indicator.setSymbol(SidebarRowDefaults.pinnedSymbol,
                                    slot: Design.Size.inlineButtonGlyph)
                indicator.setAccessibilityRole(.image)
                indicator.setAccessibilityLabel(SidebarRowDefaults.pinnedAccessibilityLabel)
                indicator.setAccessibilityIdentifier("sidebar.session.pinned")
                stack.insertArrangedSubview(indicator, at: 1)
                NSLayoutConstraint.activate([
                    indicator.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),
                    indicator.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph)
                ])
                productionSessionPinnedIndicator = indicator
            }
            productionSessionPinnedIndicator?.isHidden = !isPinned
            productionSessionPinnedIndicator?.tint = selected
                ? Design.Ink.selection.label : Design.Surface.accent
            let revealsActions = revealsActions && sessionID != nil
            productionSessionActionsRevealed = revealsActions
            let width = revealsActions ? SidebarRowDefaults.sessionTrailingSlotWidth
                : SidebarRowDefaults.trailingSlotSize
            if productionSessionMount?.width?.constant != width {
                productionSessionMount?.width?.constant = width
            }
            productionSessionHoverControls?.isHidden = !revealsActions
            productionSessionHoverControls?.alphaValue = revealsActions ? 1 : 0
            productionSessionStatusSlot?.alphaValue = revealsActions ? 0 : 1
            productionSessionActionButton?.isEnabled = archiveEnabled
            productionSessionActionButton?.isSelected = actionSelected
            productionSessionActionButton?.onPress = sessionID.map { id in
                { [weak self] in self?.onSessionAction?(id) }
            }
            productionSessionArchiveButton?.isEnabled = archiveEnabled
            productionSessionArchiveButton?.onPress = sessionID.map { id in
                { [weak self] in self?.onSessionArchive?(id) }
            }
            if revealsActions {
                productionSessionActionButton?.materializeGlyphIfNeeded()
                productionSessionArchiveButton?.materializeGlyphIfNeeded()
            }
            iconView?.isHidden = true
        }

        func sessionActionAnchor(in root: NSView) -> NSRect? {
            guard let button = productionSessionActionButton,
                  productionSessionActionsRevealed else { return nil }
            return button.convert(button.bounds, to: root)
        }

        func configureProductionTerminal(title: String, icon: NSImage, selected: Bool,
                                         running: Bool, leadingIndent: CGFloat = 0) {
            configureSidebarSelectionSilhouette()
            productionProjectView?.isHidden = true
            productionSessionStack?.isHidden = true
            productionSessionMount?.slot.isHidden = true
            let assembly: SidebarTerminalRowAssembly
            if let productionTerminalAssembly {
                assembly = productionTerminalAssembly
            } else {
                assembly = SidebarTerminalRowAssembly()
                // The Linux host has no standalone-terminal menu route yet. Keep the shared
                // control's layout, but do not expose an inert command to keyboard or AT-SPI.
                assembly.actionButton.isEnabled = false
                assembly.actionButton.setAccessibilityElement(false)
                let leading = productionLeadingInset + leadingIndent + SidebarRowDefaults.leadingInset
                let edges = assembly.mount(in: self, leadingInset: leading,
                    trailingInset: productionTrailingInset + SidebarRowDefaults.trailingInset)
                productionTerminalMount = ProductionContentMount(
                    slot: assembly.actionButton, leading: edges.leading,
                    trailing: edges.trailing, width: nil)
                productionTerminalAssembly = assembly
            }
            let leading = productionLeadingInset + leadingIndent + SidebarRowDefaults.leadingInset
            if let productionTerminalMount {
                let gutter = productionTrailingInset + SidebarRowDefaults.trailingInset
                updateProductionContent(productionTerminalMount, leadingInset: leading,
                    trailingInset: assembly.trailingSlotInset(for: gutter))
                productionTerminalMount.slot.isHidden = false
            }
            let content = assembly.visuals
            content.setTitle(title)
            content.setIcon(icon)
            content.iconView.contrastGround = { [weak self] in self?.contentGround ?? Specimen.bodyGround }
            content.setInk(selected: selected, running: running, on: inkGround)
            content.isHidden = false
            iconView?.isHidden = true
        }

        private func configureSidebarSelectionSilhouette() {
            let columnWidth = superview?.bounds.width ?? bounds.width
            let density = SidebarDensity(width: columnWidth,
                floor: min(SidebarDefaults.tightDensityWidth, columnWidth))
            // The picker cell starts six points into its bitmap viewport; the Mac outline
            // row spans the column. Inset from the column edge so both capsules land alike.
            productionSidebarSelectionInset = max(0, density.selectionInsetX - frame.minX)
            needsDisplay = true
        }

        func configureProductionStatus(_ status: String?, color: NSColor) {
            guard let stack = productionSessionStack,
                  stack.isHidden == false else {
                return
            }
            guard let status else {
                productionAttentionLabel?.stringValue = ""
                productionAttentionLabel?.isHidden = true
                return
            }
            let label: NSTextField
            if let productionAttentionLabel {
                label = productionAttentionLabel
            } else {
                label = NSTextField(labelWithString: "")
                SidebarRowDefaults.configureAttentionLabel(label)
                stack.addArrangedSubview(label)
                productionAttentionLabel = label
            }
            if label.stringValue != status { label.stringValue = status }
            label.textColor = color
            label.isHidden = false
        }

        func configureProductionActivity(_ activity: NativeSessionActivity) {
            guard let statusSlot = productionSessionStatusSlot,
                  productionSessionStack?.isHidden == false else { return }
            productionActivityIsWorking = activity.showsWorkingMark
            guard activity != .idle else {
                productionSessionActivityMark?.update(for: .idle)
                productionSessionActivityMark?.isHidden = true
                return
            }
            let mark: SessionStatusIndicator
            if let productionSessionActivityMark {
                mark = productionSessionActivityMark
            } else {
                mark = SessionStatusIndicator()
                mark.translatesAutoresizingMaskIntoConstraints = false
                mark.setAccessibilityIdentifier("sidebar.session.activity")
                statusSlot.addSubview(mark)
                SidebarRowDefaults.constrainSessionStatusContent(mark, in: statusSlot)
                productionSessionActivityMark = mark
            }
            let state: SessionActivity = switch activity {
            case .idle, .loading: .idle
            case .working: .working
            case .readyWithBackgroundWork: .readyWithBackgroundWork
            case .awaitingUser: .awaitingUser
            }
            mark.hostGround = selected ? .selection : nil
            mark.update(for: state, isLoading: activity == .loading)
            mark.isHidden = false
        }

        func productionProjectControl(create: Bool) -> NSView? {
            guard let productionProjectView, !productionProjectView.isHidden else { return nil }
            return create ? productionProjectView.createButton : productionProjectView.actionButton
        }

        func configureProductionProject(
            presentation: NavigatorProjectRowPresentation, icon: NSImage?, count: Int,
            projectID: String?, revealed: Bool, enabled: Bool, path: String? = nil,
            unavailable: Bool = false
        ) {
            productionSessionStack?.isHidden = true
            productionTerminalView?.isHidden = true
            productionSessionMount?.slot.isHidden = true
            productionTerminalMount?.slot.isHidden = true
            let content: ThemedProjectRowView
            if let productionProjectView {
                content = productionProjectView
            } else {
                content = ThemedProjectRowView(frame: bounds)
                content.translatesAutoresizingMaskIntoConstraints = false
                content.createButton.surfaceStateDidChange = { [weak self] in
                    self?.onProjectControlVisualChange?()
                }
                content.actionButton.surfaceStateDidChange = { [weak self] in
                    self?.onProjectControlVisualChange?()
                }
                addSubview(content)
                let edges = content.pin(to: self, leadingInset: productionLeadingInset,
                    trailingInset: productionTrailingInset)
                productionProjectLeading = edges.leading
                productionProjectTrailing = edges.trailing
                productionProjectView = content
            }
            if productionProjectLeading?.constant != productionLeadingInset {
                productionProjectLeading?.constant = productionLeadingInset
            }
            if productionProjectTrailing?.constant != -productionTrailingInset {
                productionProjectTrailing?.constant = -productionTrailingInset
            }
            content.isHidden = false
            content.configure(presentation, path: path, icon: icon, count: count,
                              moreSymbol: projectID == nil ? nil : SidebarRowDefaults.actionSymbol,
                              showsCreate: projectID != nil)
            if unavailable {
                let mark: GlyphView
                if let productionUnavailableMark {
                    mark = productionUnavailableMark
                } else {
                    mark = GlyphView()
                    mark.setSymbol("exclamationmark.triangle", slot: Design.Size.inlineButtonGlyph)
                    mark.contrastGround = { [weak self] in self?.contentGround ?? Specimen.bodyGround }
                    mark.setAccessibilityElement(true)
                    mark.setAccessibilityRole(.image)
                    mark.setAccessibilityLabel("Checkout unavailable at this path")
                    mark.setAccessibilityIdentifier("sidebar.project.checkout-unavailable")
                    content.insertHostStatusMark(mark)
                    NSLayoutConstraint.activate([
                        mark.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),
                        mark.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph)
                    ])
                    productionUnavailableMark = mark
                }
                mark.isHidden = false
                mark.tint = selected ? Design.Ink.selection.secondary : Design.Text.secondary
            } else {
                productionUnavailableMark?.isHidden = true
            }
            content.iconView.contrastGround = { [weak self] in self?.contentGround ?? Specimen.bodyGround }
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
            let paintsSelection: Bool
            #if THREADING_WINDOW_HARNESS
            paintsSelection = selected && drawsSelectionBackground
            #else
            paintsSelection = selected
            #endif
            if paintsSelection {
                #if THREADING_WINDOW_HARNESS
                if let inset = productionSidebarSelectionInset {
                    let shape = bounds.insetBy(dx: inset,
                        dy: SidebarRowDefaults.hoverHighlightInsetY)
                    let radius = AppThemeLibrary.current.isSystem
                        ? SidebarRowDefaults.systemHoverHighlightRadius
                        : Design.Radius.control(fitting: shape.size)
                    SurfaceDrawing.draw(shape, fill: accent, radius: radius, borderWidth: 0)
                } else {
                    SurfaceDrawing.draw(bounds, fill: accent,
                                        radius: Self.selectionRadius, borderWidth: 0)
                }
                #else
                SurfaceDrawing.draw(bounds, fill: accent,
                                    radius: Self.selectionRadius, borderWidth: 0)
                #endif
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
        let outlineChrome = NSTableRowView(frame: NSRect(x: 0, y: 48, width: 120, height: 22))
        let outlineCell = Row(frame: .zero, text: "", accent: accent, selected: false,
                              ink: reusedWindow.bodyInk, showsMark: false)
        outlineChrome.addSubview(outlineCell)
        outlineCell.configure(frame: outlineChrome.frame, accent: accent, selected: false,
                              ink: reusedWindow.bodyInk, image: nil, showsMark: false,
                              disclosure: nil)
        precondition(outlineCell.frame == outlineChrome.bounds,
                     "outline refresh moved cell out of its row-local geometry")
        verifyKeyEquivalentDispatch()
        print("PASS retained navigator row/icon geometry and label slot identity")

        if let advance = PlatinumBitmapFont.advance(of: "Threading on Linux") {
            print("PlatinumBitmapFont.advance(of:) = \(advance)px — the real file's own metrics")
        }
    }
}
