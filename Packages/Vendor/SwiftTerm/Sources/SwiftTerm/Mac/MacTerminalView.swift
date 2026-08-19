//
//  MacTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
//
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(macOS)
import Foundation
import AppKit
import CoreText
import CoreGraphics

/// The spelling a program used for one colour after terminal rendering semantics such as
/// inverse video and bold-as-bright have been applied.
public enum TerminalRenderedColorSource: Hashable, Sendable {
    case ansi256(index: UInt8)
    case trueColor(red: UInt8, green: UInt8, blue: UInt8)
    case defaultForeground
    case defaultBackground
    case invertedDefaultForeground
    case invertedDefaultBackground
}

/// A colour reduced to the stable sRGB bytes a diagnostic can safely carry out of the renderer.
public struct TerminalRenderedColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// A visible run of meaningful text whose final foreground and background are effectively the
/// same. SwiftTerm still draws the colours exactly as the program requested; this is observation,
/// never correction.
public struct TerminalTextColorConflict: Hashable, Sendable {
    public let foregroundSource: TerminalRenderedColorSource
    public let backgroundSource: TerminalRenderedColorSource
    public let foreground: TerminalRenderedColor
    public let background: TerminalRenderedColor
    public let contrastRatio: Double

    /// What the run actually said, so a diagnostic can quote the text the reader could not see.
    /// Program output is external content: this is already stripped of control characters,
    /// collapsed to single spaces and capped at a few words, and it is empty when nothing
    /// quotable survived that.
    public let sample: String

    public init(
        foregroundSource: TerminalRenderedColorSource,
        backgroundSource: TerminalRenderedColorSource,
        foreground: TerminalRenderedColor,
        background: TerminalRenderedColor,
        contrastRatio: Double,
        sample: String = ""
    ) {
        self.foregroundSource = foregroundSource
        self.backgroundSource = backgroundSource
        self.foreground = foreground
        self.background = background
        self.contrastRatio = contrastRatio
        self.sample = sample
    }
}

/// Bounds on the text a colour conflict is allowed to carry out of the renderer.
public enum TerminalContrastSample {
    /// Scanned scalars, which is what stops a full-width run from being walked twice.
    public static let scanLimit = 64

    /// Kept characters. A few words is enough to point at the place on screen; a whole line
    /// would not fit the band that shows it, and would be truncated there instead — by a
    /// component that cannot say *why* it truncated.
    public static let characterLimit = 24

    /// Appended when either bound cut the run short, so a quoted fragment never claims to be
    /// the whole of what the program printed.
    public static let ellipsis: Character = "…"
}

struct TerminalTextContrastPair: Hashable {
    let foregroundSource: TerminalRenderedColorSource
    let backgroundSource: TerminalRenderedColorSource
    let foreground: TerminalRenderedColor
    let background: TerminalRenderedColor
}

/**
 * TerminalView provides an AppKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 *
 * Developers might want to surface UIs for `optionAsMetaKey` and `allowMouseReporting` in
 * their application.  They both default to true, but this means that Option-Letter is hijacked for
 * terminal purposes to send the sequence ESC-Letter, instead of the macOS specific character and
 * means that when mouse-aware applications are running, they hijack the normal selection process.
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: NSView, NSTextInputClient, NSUserInterfaceValidations, TerminalDelegate {
    struct FontSet {
        public let normal: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont
        
        static var defaultFont: NSFont {
            if #available(macOS 10.15, *)  {
                return NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                return NSFont(name: "Menlo Regular", size: NSFont.systemFontSize) ?? NSFont(name: "Courier", size: NSFont.systemFontSize)!
            }
        }
        
        public init(font baseFont: NSFont, fontSize: CGFloat? = nil) {
            self.normal = baseFont
            self.bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
            self.italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
            self.boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
        }

        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return normal.underlinePosition
        }

        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return normal.underlineThickness
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var terminalDelegate: TerminalViewDelegate?

    /**
     * Gives a subclass a chance to keep the emulator on an explicitly managed grid, one that
     * does not follow this view's pixel size.
     *
     * Called before the emulator is touched, so returning false suppresses the whole of the
     * frame-driven resize: no reflow of the buffer, no soft reset, and no delegate
     * notification. The default preserves SwiftTerm behaviour.
     */
    open func shouldApplyFrameSizeChange(newCols: Int, newRows: Int) -> Bool {
        true
    }

    /**
     * Gives a subclass a chance to keep a programmatic emulator resize local to the renderer.
     * Internal scrolling and accessibility state are still updated; only the host delegate
     * notification is suppressed. The default preserves SwiftTerm behaviour.
     */
    open func shouldReportSizeChange(newCols: Int, newRows: Int) -> Bool {
        true
    }

    /// If true, the caret view will show different shapes depending on the focus
    /// otherwise, it will behave like it is focused
    public var caretViewTracksFocus: Bool {
        get {
            return caretView.tracksFocus
        }
        set {
            caretView.tracksFocus = newValue
        }
    }

    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: TerminalDebugView?
    var pendingDisplay: Bool = false
    
    var cellDimension: CellDimension!
    var caretView: CaretView!
    public var terminal: Terminal!

    var selection: SelectionService!
    /// The scrollback origin when the current selection was last changed. Buffer coordinates
    /// remain stable while normal scrollback grows, but recycling its oldest line shifts every
    /// coordinate and invalidates the range.
    private var selectionLinesTop = 0
    private var scroller: NSScroller!
    
    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    
    
    // Cache for the colors in the 0..255 range
    var colors: [NSColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:NSColor] = [:]

    /// Backgrounds cached *after* `trueColorBackgroundTransform` has run.
    ///
    /// Separate from `trueColors` because that cache is keyed by the colour alone, while the
    /// transform applies to one role only — sharing it would hand a rewritten background back
    /// to a foreground asking for the same 24-bit value.
    var trueColorBackgrounds: [Attribute.Color:NSColor] = [:]

    /// Rewrites a 24-bit **background** colour on its way to the screen.
    ///
    /// A program emitting `48;2;R;G;B` has picked an absolute colour for a generic terminal and
    /// cannot know what palette it landed in, so a themed host has no say in the one place a
    /// large flat area of colour appears. This is that say. Foregrounds are deliberately not
    /// offered: a program's syntax highlighting is its own, and rewriting text colour against a
    /// background the program also chose is how legibility gets broken from the outside.
    ///
    /// Indexed colours (`ansi256`) are already the palette's and never reach this.
    public var trueColorBackgroundTransform: ((NSColor) -> NSColor)? {
        didSet {
            trueColorBackgrounds = [:]
            colorsChanged()
        }
    }

    /// Reports severe final text/background collisions found while building visible rows.
    ///
    /// The renderer performs the qualification and deduplication itself so a host does not get
    /// a callback for every token or frame. Setting this never changes terminal output.
    public var onLowContrastText: ((TerminalTextColorConflict) -> Void)?

    /// Colour pairs already measured for the current palette. Both collections are bounded:
    /// programs can emit arbitrary truecolour values, and a diagnostic cache must not turn that
    /// external cardinality into permanent renderer memory.
    var evaluatedTextContrast: Set<TerminalTextContrastPair> = []
    /// Keyed by the colour pair rather than by the reported conflict: the conflict now carries a
    /// sample of the text that produced it, and a program printing a second unreadable word must
    /// not read as a second collision.
    var reportedTextContrast: Set<TerminalTextContrastPair> = []
    var transparent = TTColor.transparent ()
    var isBigSur = true
    
    /// This flag is automatically set to true after the initializer is called, if running on a system older than BigSur.
    /// Starting with BigSur any screen updates will invoke the draw() method with the whole region, regardless
    /// of how much changed.   Setting this to true, will disable this OS behavior, setting it to false, will keep
    /// the original BigSur behavior to redraw the whole region.
    ///
    /// For more details on this see:
    /// https://gist.github.com/lukaskubanek/9a61ac71dc0db8bb04db2028f2635779
    /// https://developer.apple.com/forums/thread/663256?answerId=646653022#646653022
    public var disableFullRedrawOnAnyChanges = false
    var fontSet: FontSet

    /// The font to use to render the terminal
    public var font: NSFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont()
            selectNone()
        }
    }
    
    public init(frame: CGRect, font: NSFont?) {
        self.fontSet = FontSet (font: font ?? FontSet.defaultFont)

        super.init (frame: frame)
        setup()
    }
    
    public override init (frame: CGRect)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (frame: frame)
        setup()
    }
    
    public required init? (coder: NSCoder)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (coder: coder)
        setup()
    }
    
    private func setup()
    {
        wantsLayer = true
        isBigSur = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0))
        if isBigSur {
            disableFullRedrawOnAnyChanges = true
        }
        if #available(macOS 14, *) {
            self.clipsToBounds = true
        }
        setupScroller()
        setupOptions()
        setupFocusNotification()
        updateLayerContentsScale()
    }

    /// Updates the layer's contentsScale to match the display for crisp HiDPI rendering.
    func updateLayerContentsScale() {
        layer?.contentsScale = backingScaleFactor()
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContentsScale()
        // Trigger redraw at new scale
        needsDisplay = true
    }
    
    func startDisplayUpdates ()
    {
        // Not used on Mac
    }
    
    func suspendDisplayUpdates()
    {
        // Not used on Mac
    }
    
    var becomeMainObserver, resignMainObserver: NSObjectProtocol?
    
    deinit {
        if let becomeMainObserver {
            NotificationCenter.default.removeObserver (becomeMainObserver)
        }
        if let resignMainObserver {
            NotificationCenter.default.removeObserver (resignMainObserver)
        }
    }
    
    func setupFocusNotification() {
        becomeMainObserver = NotificationCenter.default.addObserver(forName: .init("NSWindowDidBecomeMainNotification"), object: nil, queue: nil) { [unowned self] notification in
            self.caretView.updateCursorStyle()
        }
        resignMainObserver = NotificationCenter.default.addObserver(forName: .init("NSWindowDidResignMainNotification"), object: nil, queue: nil) { [unowned self] notification in
            self.caretView.disableAnimations()
            self.caretView.updateView()
        }
    }
    
    func setupOptions ()
    {
        setupOptions (width: getEffectiveWidth (size: bounds.size), height: bounds.height)
        layer?.backgroundColor = nativeBackgroundColor.cgColor
    }

    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    var _nativeBoldFg: NSColor?
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: NSColor {
        get { _nativeFg }
        set {
            if settingFg { return }
            settingFg = true
            _nativeFg = newValue
            terminal.foregroundColor = nativeForegroundColor.getTerminalColor ()
            settingFg = false
            evaluatedTextContrast.removeAll(keepingCapacity: true)
            reportedTextContrast.removeAll(keepingCapacity: true)
        }
    }

    /// **Ours.** The colour bold text drawn with the *default* foreground is rendered in —
    /// Terminal.app's "Bold Text" — or nil to draw it in `nativeForegroundColor`, which is what
    /// SwiftTerm did before this existed.
    ///
    /// Bold text that names an ANSI colour is unaffected: it keeps the 0–7 to 8–15 bright shift.
    /// This is not pushed into the terminal engine, because no escape sequence describes it; it
    /// is a property of the palette the host installed.
    public var nativeBoldForegroundColor: NSColor? {
        get { _nativeBoldFg }
        set {
            guard _nativeBoldFg != newValue else { return }
            _nativeBoldFg = newValue
            // Attributes are cached per `Attribute`, and the bold styles among them resolved
            // through the old answer — so the cache is stale in exactly the cells this moves.
            attributes = [:]
            urlAttributes = [:]
            evaluatedTextContrast = []
            reportedTextContrast = []
            terminal.updateFullScreen ()
            queuePendingDisplay ()
        }
    }

    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeBackgroundColor: NSColor {
        get { _nativeBg }
        set {
            if settingBg { return }
            settingBg = true
            _nativeBg = newValue
            terminal.backgroundColor = nativeBackgroundColor.getTerminalColor ()
            settingBg = false
            evaluatedTextContrast.removeAll(keepingCapacity: true)
            reportedTextContrast.removeAll(keepingCapacity: true)
        }
    }
    
    /// Controls weather to use high ansi colors, if false terminal will use bold text instead of high ansi colors
    public var useBrightColors: Bool = true
    
    /// Controls the color for the caret
    public var caretColor: NSColor {
        get { caretView.caretColor }
        set { caretView.caretColor = newValue }
    }

    /// Controls the color for the text in the caret when using a block cursor, if not set
    /// the cursor will render with the foreground color
    public var caretTextColor: NSColor? {
        get { caretView.caretTextColor }
        set { caretView.caretTextColor = newValue }
    }

    /// Controls the cursor style (block, underline, bar) and whether it blinks
    public var cursorStyle: CursorStyle {
        get { caretView.style }
        set {
            caretView.style = newValue
            terminal.options.cursorStyle = newValue
        }
    }

    var _selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
    /// The color used to render the selection
    public var selectedTextBackgroundColor: NSColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
        }
    }

    func backingScaleFactor () -> CGFloat
    {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
    
    @objc
    func scrollerActivated ()
    {
        switch scroller.hitPart {
        case .decrementPage:
            pageUp()
            scroller.doubleValue =  scrollPosition
        case .incrementPage:
            pageDown()
            scroller.doubleValue =  scrollPosition
        case .knob:
            scroll(toPosition: scroller.doubleValue)
        case .knobSlot, .noPart, .decrementLine, .incrementLine:
            SwiftTermDiagnostics.emit(
                .debug,
                .uiUnhandledAction,
                facts: ["action": Int(scroller.hitPart.rawValue)]
            )
        default:
            SwiftTermDiagnostics.emit(
                .debug,
                .uiUnhandledAction,
                facts: ["action": Int(scroller.hitPart.rawValue)]
            )
        }
    }
    
    
    func setupScroller()
    {
        let style: NSScroller.Style = .legacy
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
        let scrollerFrame = NSRect(x: bounds.maxX - scrollerWidth, y: 0, width: scrollerWidth, height: bounds.height)
        if scroller == nil {
            scroller = NSScroller(frame: scrollerFrame)
        } else {
            scroller?.frame = scrollerFrame
        }
        scroller.autoresizingMask = [.minXMargin, .height]
        scroller.scrollerStyle = style
        scroller.knobProportion = 0.1
        scroller.isEnabled = false
        addSubview (scroller)
        scroller.action = #selector(scrollerActivated)
        scroller.target = self
    }

    /// Replaces the terminal's scrollbar without replacing its scrolling behavior.
    ///
    /// The embedder owns application chrome while SwiftTerm owns scroll position, sizing and
    /// actions. Supplying an `NSScroller` here is the seam between them: setup restates every
    /// behavioral property and subsequent buffer changes continue updating the replacement.
    public func installScroller(_ replacement: NSScroller)
    {
        guard replacement !== scroller else { return }
        scroller.removeFromSuperview()
        scroller = replacement
        setupScroller()
        updateScroller()
    }
    
    /// **Ours.** The colour this attribute's text is drawn in, after inverse, the bold
    /// foreground, bold-as-bright and SGR 2 faintness have all resolved. A seam for the
    /// embedder's tests; the renderer itself uses the same call.
    public func resolvedForegroundColor (for attribute: Attribute) -> NSColor
    {
        resolvedForeground (for: attribute)
    }

    /// This method sents the `nativeForegroundColor` and `nativeBackgroundColor`
    /// to match macOS default colors for text and its background.
    public func configureNativeColors ()
    {
        self.nativeForegroundColor = NSColor.textColor
        self.nativeBackgroundColor = NSColor.textBackgroundColor

    }
    
    open func bufferActivated(source: Terminal) {
        // A selection belongs to one buffer. The normal and alternate buffers reuse the same
        // coordinates for unrelated contents, so carrying a range between them highlights text
        // the user never selected.
        selection.selectNone()
        updateScroller ()
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
        
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    open func getOptimalFrameSize () -> NSRect
    {
        return NSRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols) + scroller.frame.width, height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    func getEffectiveWidth (size: CGSize) -> CGFloat
    {
        return (size.width-scroller.frame.width)
    }
    
    open func scrolled(source terminal: Terminal, yDisp: Int) {
        // Normal-buffer growth appends beneath existing ranges, so selection remains valid.
        // A fixed alternate buffer scrolls its rows in place, while a full normal scrollback
        // recycles from the top; both replace the cells the saved coordinates identified.
        if selection.active,
           !terminal.buffer.hasScrollback || terminal.buffer.linesTop != selectionLinesTop {
            selection.selectNone()
        }
        //selectionView.notifyScrolled(source: terminal)
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
    }
    
    open func linefeed(source: Terminal) {
        // A line feed that does not scroll or trim the buffer leaves an existing range valid.
        // `scrolled(source:yDisp:)` owns the two cases that do invalidate its coordinates.
    }
    
    /// This vaiable controls whether mouse events are sent to the application running under the
    /// terminal if it has requested the data.   This poses a problem for selection, so users
    /// need a way of toggling this behavior.
    public var allowMouseReporting: Bool = true

    /**
     * If set to true, this will call the TerminalViewDelegate's rangeChanged method
     * when there are changes that are being performed on the UI
     */
    public var notifyUpdateChanges = false

    func updateDebugDisplay()
    {
        debug?.update()
    }
    
    func updateScroller ()
    {
        scroller.isEnabled = canScroll
        scroller.doubleValue = scrollPosition
        scroller.knobProportion = scrollThumbsize
    }
    
    var userScrolling = false

    override open func viewWillDraw() {

        // Starting with BigSur, it looks like even sending one pixel to be redrawn will trigger
        // a call to draw() for the whole surface
        if disableFullRedrawOnAnyChanges {
            let layer = self.layer
            layer?.contentsFormat = .RGBA8Uint
            // Ensure proper HiDPI scaling for crisp text rendering
            layer?.contentsScale = backingScaleFactor()
        }
    }
    #if false
    override open func setNeedsDisplay(_ invalidRect: NSRect) {
        print ("setNeeds: \(invalidRect)")
        super.setNeedsDisplay(invalidRect)
    }
    #endif
    
    func getCurrentGraphicsContext () -> CGContext?
    {
        NSGraphicsContext.current?.cgContext
    }
    
    override open func draw (_ dirtyRect: NSRect) {
        guard let currentContext = getCurrentGraphicsContext() else {
            return
        }
        drawTerminalContents (dirtyRect: dirtyRect, context: currentContext, bufferOffset: terminal.buffer.yDisp)
    }
    
    public override func cursorUpdate(with event: NSEvent)
    {
        NSCursor.iBeam.set ()
    }
    
    func makeFirstResponder ()
    {
        window?.makeFirstResponder (self)
    }
    
    open override var frame: NSRect {
        get {
            return super.frame
        }
        set(newValue) {
            super.frame = newValue
            guard cellDimension != nil else { return }
            processSizeChange(newSize: newValue.size)
            needsDisplay = true
            updateCursorPosition()
        }
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setupScroller()
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateScroller()
        selection.active = false
    }
    
    private var _hasFocus = false
    open var hasFocus : Bool {
        get {
            //print ("hasFocus: \(_hasFocus) window=\(window?.isKeyWindow)")
            return _hasFocus && (window?.isKeyWindow ?? true)
        }
        set {
            _hasFocus = newValue
            caretView.focused = newValue
        }
    }

    //
    // NSTextInputClient protocol implementation
    //
    public override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasFocus = true
            caretView.updateCursorStyle()
            terminal.setTerminalFocus(true)
        }
        return response
    }
    
    public override func resignFirstResponder() -> Bool {
        let response = super.resignFirstResponder()
        if response {
            caretView.disableAnimations()
            hasFocus = false
            terminal.setTerminalFocus(false)
        }
        return response
    }
    
    public override var acceptsFirstResponder: Bool {
        get {
            return true
        }
    }
    
    // Tracking object, maintained by `startTracking` and `deregisterTrackingInterest`
    var tracking: NSTrackingArea? = nil
    
    // Turns on AppKit mouse event tracking - used both by the url highlighter and the mouse move,
    // when the client application has set MouseMove.anyEvent
    //
    // Can be invoked multiple times, use the "deregisterTrackingInterest" method to turn it off
    // which will take into account both the url highlighter state (which is bound to the command
    // key being pressed) and the client requirements
    func startTracking ()
    {
        if tracking == nil {
            // `.inVisibleRect` rather than a measured rect: a tracking rect is in the owner's
            // own coordinates, so passing `frame` displaced the region by however far the view
            // sits inside its superview — an embedder that insets the terminal loses a band
            // along two edges where the pointer reports nothing. It also went stale on every
            // resize, since nothing rebuilt it. AppKit keeps an `.inVisibleRect` area aligned
            // on its own and ignores the rect, which is passed only to satisfy the initialiser.
            tracking = NSTrackingArea (rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: [:])
            addTrackingArea(tracking!)
        }
    }
    
    // Can be invoked by both the keyboard handler monitoring the command key, and the
    // mouse tracking system, only when both are off, this is turned off.
    func deregisterTrackingInterest ()
    {
        if commandActive == false && terminal.mouseMode != .anyEvent {
            if tracking != nil {
                removeTrackingArea(tracking!)
                tracking = nil
            }
        }
    }
    
    func turnOffUrlPreview ()
    {
        if commandActive {
            deregisterTrackingInterest()
            removePreviewUrl()
            commandActive = false
        }
    }
    
    // If true, the Command key has been pressed
    var commandActive = false
    
    // We monitor the flags changed to enable URL previews on mouse-hover like iTerm
    // when the Command key is pressed.
    
    public override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.command){
            commandActive = true
            startTracking()
            
            if let payload = getPayload(for: event) as? String {
                previewUrl (payload: payload)
            }
        } else {
            turnOffUrlPreview ()
        }
        super.flagsChanged(with: event)
    }
    
    public override func mouseExited(with event: NSEvent) {
        turnOffUrlPreview()
        // Re-entering on the same cell the pointer left from is a real move, so the suppressed
        // cell cannot outlive the visit it belongs to.
        lastMotionCell = nil
        super.mouseExited(with: event)
    }
    
    /// If set to true, the terminal treats the "Option" key as the Meta key in old terminals,
    /// which has the effect of sending the ESC character before the character that was
    /// entered.  Applications use this to provide bindings for Alt-keys, or in Emacs terms
    /// the Meta key (M-x stands for Meta-x, or pressing the option key and x).
    ///
    /// If this is set to `false`, then the key is passed to the OS, which produces the
    /// OS specific feature.
    public var optionAsMetaKey: Bool = true
    
    //
    // We capture a handful of keydown events and pre-process those, and then let
    // interpretKeyEvents do the rest of the work, that includes text-insertion, and
    // keybinding mapping.
    //
    // That is why we do not handle things like the return key here, instead those are
    // handled by doCommand below.
    //
    // This currently handles the function keys here, but probably should be done in
    // doCommand/noop: - but more research needs to take place to figure out the priority
    // of those keys.
    //
    open override func keyDown(with event: NSEvent) {
        selection.active = false
        let eventFlags = event.modifierFlags
        
        // Handle Option-letter to send the ESC sequence plus the letter as expected by terminals
        if eventFlags.contains ([.option, .command]) {
            if event.charactersIgnoringModifiers == "o" {
                optionAsMetaKey.toggle()
            }
        } else if optionAsMetaKey && eventFlags.contains (.option) {
            if let rawCharacter = event.charactersIgnoringModifiers {
                if let fs = rawCharacter.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.emacsBack)
                        return
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.emacsForward)
                        return
                    default: break
                    }
                }
                send (EscapeSequences.cmdEsc)
                send (txt: rawCharacter)
            }
            return
        } else if eventFlags.contains (.control) {
            // Sends the control sequence
            if let ch = event.charactersIgnoringModifiers {
                if let fs = ch.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.controlLeft)
                        return
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.controlRight)
                        return
                    default:
                        break
                    }
                }
                send (applyControlToEventCharacters (ch))
                return
            }
        } else if eventFlags.contains (.function) {
            if let str = event.charactersIgnoringModifiers {
                if let fs = str.unicodeScalars.first {
                    let c = Int (fs.value)
                    switch c {
                    case NSF1FunctionKey:
                        send (EscapeSequences.cmdF [0])
                    case NSF2FunctionKey:
                        send (EscapeSequences.cmdF [1])
                    case NSF3FunctionKey:
                        send (EscapeSequences.cmdF [2])
                    case NSF4FunctionKey:
                        send (EscapeSequences.cmdF [3])
                    case NSF5FunctionKey:
                        send (EscapeSequences.cmdF [4])
                    case NSF6FunctionKey:
                        send (EscapeSequences.cmdF [5])
                    case NSF7FunctionKey:
                        send (EscapeSequences.cmdF [6])
                    case NSF8FunctionKey:
                        send (EscapeSequences.cmdF [7])
                    case NSF9FunctionKey:
                        send (EscapeSequences.cmdF [8])
                    case NSF10FunctionKey:
                        send (EscapeSequences.cmdF [9])
                    case NSF11FunctionKey:
                        send (EscapeSequences.cmdF [10])
                    case NSF12FunctionKey:
                        send (EscapeSequences.cmdF [11])
                    case NSDeleteFunctionKey:
                        send (EscapeSequences.cmdDelKey)
                        //                    case NSUpArrowFunctionKey:
                        //                        send (EscapeSequences.MoveUpNormal)
                        //                    case NSDownArrowFunctionKey:
                        //                        send (EscapeSequences.MoveDownNormal)
                        //                    case NSLeftArrowFunctionKey:
                        //                        send (EscapeSequences.MoveLeftNormal)
                        //                    case NSRightArrowFunctionKey:
                    //                        send (EscapeSequences.MoveRightNormal)
                    case NSPageUpFunctionKey:
                        pageUp ()
                    case NSPageDownFunctionKey:
                        pageDown()
                    default:
                        interpretKeyEvents([event])
                    }
                }
            }
            return
        }
        
        interpretKeyEvents([event])
    }
    
    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            send (EscapeSequences.cmdRet)
        case #selector(cancelOperation(_:)):
            send (EscapeSequences.cmdEsc)
        case #selector(deleteBackward(_:)):
            send ([backspaceSendsControlH ? 8 : 0x7f])
        case #selector(moveUp(_:)):
            sendKeyUp()
        case #selector(moveDown(_:)):
            sendKeyDown()
        case #selector(moveLeft(_:)):
            sendKeyLeft()
        case #selector(moveRight(_:)):
            sendKeyRight()
        case #selector(insertTab(_:)):
            send (EscapeSequences.cmdTab)
        case #selector(insertBacktab(_:)):
            send (EscapeSequences.cmdBackTab)
        case #selector(moveToBeginningOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(moveToEndOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(scrollPageUp(_:)):
            fallthrough
        case #selector(pageUp(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.cmdPageUp)
            } else {
                pageUp()
            }
        case #selector(scrollPageDown(_:)):
            fallthrough
        case #selector(pageDown(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.cmdPageDown)
            } else {
                pageDown()
            }
        case #selector(pageDownAndModifySelection(_:)):
            if terminal.applicationCursor {
                // TODO: view should scroll one page up.
            } else {
                send (EscapeSequences.cmdPageDown)
            }
        case #selector(moveToLeftEndOfLine(_:)):
            // Apple sends the Emacs back-word commands
            send (EscapeSequences.emacsBack)
        case #selector(moveToRightEndOfLine(_:)):
            send (EscapeSequences.emacsForward)
        // The Option-word keys, for hosts that leave `optionAsMetaKey` off so the Option key can
        // still compose characters (`~`, `|`, `\` on most non-US layouts). The meta branch in
        // `keyDown` special-cases the arrows into these same sequences, but it is all-or-nothing:
        // switching it off to keep composition working also silently dropped word editing,
        // because AppKit resolves these keys to `moveWordLeft:`, `moveWordRight:` and
        // `deleteWordBackward:`, and nothing below claimed them. That is the entire keypress
        // lost — not a sequence the program misreads.
        case #selector(moveWordLeft(_:)):
            send (EscapeSequences.emacsBack)
        case #selector(moveWordRight(_:)):
            send (EscapeSequences.emacsForward)
        case #selector(deleteWordBackward(_:)):
            send (EscapeSequences.emacsBackwardKillWord)
        default:
            SwiftTermDiagnostics.emit(.debug, .uiUnhandledAction)
        }
    }
    
    // NSTextInputClient protocol implementation
    open func insertText(_ string: Any, replacementRange: NSRange) {
        insertText(string, replacementRange: replacementRange, isPaste: false)
    }
    
    func insertText(_ string: Any, replacementRange: NSRange, isPaste: Bool) {
        if let str = string as? NSString {
            if isPaste, terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteStart[0...])
            }
            send (txt: str as String)
            if isPaste, terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteEnd[0...])
            }
        }
        // TODO: I do not think we actually need this needsDisplay, the data fed should bubble this up
        // needsDisplay = true
    }
    
    // NSTextInputClient protocol implementation
    open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // nothing
    }
    
    // NSTextInputClient protocol implementation
    open func unmarkText() {
        // nothing
    }
    
    // NSTextInputClient protocol implementation
    open func selectedRange() -> NSRange {
        guard let selection = self.selection, selection.active else {
            // This means "no selection":
            return NSRange.empty
        }
        
        var startLocation = (selection.start.row * terminal.buffer.rows) + selection.start.col
        var endLocation = (selection.end.row * terminal.buffer.rows) + selection.end.col
        if startLocation > endLocation {
            swap(&startLocation, &endLocation)
        }
        let length = endLocation - startLocation
        if length == 0 {
            return NSRange.empty
        }
        return NSRange(location: startLocation, length: endLocation - startLocation)
    }
    
    // NSTextInputClient protocol implementation
    open func markedRange() -> NSRange {
        SwiftTermDiagnostics.emit(
            .warning,
            .uiTextInputUnsupported,
            facts: ["operation": 1]
        )
        
        // This means "no marked" - when we fix, we should address
        return NSRange.empty
    }
    
    // NSTextInputClient protocol implementation
    open func hasMarkedText() -> Bool {
        // print ("hasMarkedText: This should return the actual range from the selection")
        // TODO
        return false
    }
    
    // NSTextInputClient protocol implementation
    open func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        SwiftTermDiagnostics.emit(
            .warning,
            .uiTextInputUnsupported,
            facts: ["operation": 2]
        )
        return nil
    }
    
    // NSTextInputClient Protocol implementation
    open func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // TODO print ("validAttributesForMarkedText: This should return the actual range from the selection")
        return []
    }
    
    // NSTextInputClient protocol implementation
    open func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        
        if let r = window?.convertToScreen(convert(caretView!.frame, to: nil)) {
            return r
        }
        
        return .zero
    }
    
    // NSTextInputClient protocol implementation
    open func characterIndex(for point: NSPoint) -> Int {
        SwiftTermDiagnostics.emit(
            .warning,
            .uiTextInputUnsupported,
            facts: ["operation": 3]
        )
        return NSNotFound
    }
    
    open func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        //print ("Validating selector: \(item.action)")
        switch item.action {
        case #selector(performTextFinderAction(_:)):
            if let fa = NSTextFinder.Action (rawValue: item.tag) {
                switch fa {
                case .showFindInterface:
                    return true
                case .showReplaceInterface:
                    return true
                case .hideReplaceInterface:
                    return true
                default:
                    return false
                }
            }
            return false
        case #selector(paste(_:)):
            return true
        case #selector(selectAll(_:)):
            return true
        case #selector(copy(_:)):
            return selection.active
        default:
            SwiftTermDiagnostics.emit(.debug, .uiUnhandledAction)
            return false
        }
    }
    
    open func selectionChanged(source: Terminal) {
        if selection.active {
            selectionLinesTop = source.buffer.linesTop
        }
        needsDisplay = true
    }
    
    func cut (sender: Any?) {}
    
    /// The pasteboard `copy` and `paste` read and write.
    ///
    /// Ours, and it exists for the tests. `NSPasteboard.general` is the developer's own
    /// clipboard, so a unit test that exercised copying threw away whatever they had on it —
    /// the same trap as a hosted test writing to `UserDefaults.standard`. Defaulting to
    /// `.general` leaves every shipping path exactly as it was.
    public var pasteboard: NSPasteboard = .general

    @objc
    open func paste(_ sender: Any)
    {
        let text = pasteboard.string(forType: .string)
        insertText(text ?? "", replacementRange: NSRange(location: 0, length: 0), isPaste: true)
    }

    /// Sends `text` the way `paste` sends the clipboard: wrapped in the bracketed-paste markers
    /// when the program has asked for them.
    ///
    /// Ours, and the reason is a drop. A file dragged onto a terminal is a paste that never
    /// went through the clipboard, and the program reading the PTY tells the two apart: with
    /// bracketed paste on, one arriving string is a paste, and the same bytes without the
    /// markers are a burst of typing. The distinction is load-bearing for the agent CLIs — a
    /// pasted image path becomes an attached image, a typed one stays text — and an embedder
    /// had no way to reach it without first writing over the user's clipboard.
    public func pasteText(_ text: String)
    {
        insertText(text, replacementRange: NSRange(location: 0, length: 0), isPaste: true)
    }

    /// The selected text, or nil when nothing is selected and when the selection covers no
    /// characters at all.
    ///
    /// Ours. `SelectionService` is internal, so an embedder had no way to ask what — or
    /// whether — the user had selected; the nil-for-empty half is the load-bearing one, since
    /// `copy` clears the pasteboard before it writes and a caller that cannot tell an empty
    /// selection from a real one wipes the clipboard on an ordinary click.
    public var selectedText: String? {
        guard let selection, selection.active else { return nil }
        let text = selection.getSelectedText()
        return text.isEmpty ? nil : text
    }

    /// Called when a **pointer gesture** has finished settling the selection: a drag released, a
    /// double- or triple-click, a shift-click extension. Does nothing here; a host overrides it
    /// to implement copy-on-select.
    ///
    /// Ours, and deliberately not `selectionChanged(source:)`: `SelectionService` posts that one
    /// on every `dragExtend`, which is every mouse-moved event inside a drag, so a host copying
    /// there would rewrite the pasteboard a hundred times per gesture and hand back a half-made
    /// selection each time. Nothing calls this for `selectAll`, nor for a click whose only
    /// effect is to clear a selection — neither is a user choosing text to take with them.
    open func selectionGestureEnded()
    {
    }

    @objc
    open func copy(_ sender: Any)
    {
        // find the selected range of text in the buffer and put in the clipboard
        //
        // The guard is ours: `clearContents` before an empty write turned a copy with nothing
        // selected into "throw away the user's clipboard". ⌘C never reached it — the menu
        // validation below gates on `selection.active` — but an embedder's own context menu
        // and copy-on-select both call this directly.
        guard let str = selectedText else { return }

        pasteboard.clearContents()
        pasteboard.setString(str, forType: .string)
    }

    public override func selectAll(_ sender: Any?)
    {
        selectAll ()
    }
    
    //func undo (sender: Any) {}
    //func redo (sender: Any) {}
    func zoomIn (sender: Any) {}
    func zoomOut (sender: Any) {}
    func zoomReset (sender: Any) {}
    
    // Returns the vt100 mouseflags
    func encodeMouseEvent (with event: NSEvent, overwriteRelease: Bool = false) -> Int
    {
        let flags = event.modifierFlags
        let isReleaseEvent = overwriteRelease || [NSEvent.EventType.leftMouseUp, .otherMouseUp, .rightMouseUp].contains(event.type)
        
        return terminal.encodeButton(button: event.buttonNumber, release: isReleaseEvent, shift: flags.contains(.shift), meta: flags.contains(.option), control: flags.contains(.control))
    }
    
    func calculateMouseHit (with event: NSEvent) -> (grid: Position, pixels: Position)
    {
        let point = convert(event.locationInWindow, from: nil)
        return calculateMouseHit(at: point)
    }

    func calculateMouseHit (at point: CGPoint) -> (grid: Position, pixels: Position)
    {
        func toInt (_ p: NSPoint) -> Position {

            let x = min (max (p.x, 0), bounds.width)
            let y = min (max (p.y, 0), bounds.height)
            return Position (col: Int (x), row: Int (bounds.height-y))
        }
        let col = Int (point.x / cellDimension.width)
        let row = Int ((frame.height-point.y) / cellDimension.height)
        if row < 0 {
            return (Position(col: 0, row: 0), toInt (point))
        }
        return (Position(col: min (max (0, col), terminal.cols-1), row: row), toInt (point))
    }
    
    private func sharedMouseEvent (with event: NSEvent)
    {
        let hit = calculateMouseHit(with: event)
        let buttonFlags = encodeMouseEvent(with: event)
        terminal.sendEvent(buttonFlags: buttonFlags, x: hit.grid.col, y: hit.grid.row, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
    }
    
    private var autoScrollDelta = 0
    // Callback from when the mouseDown autoscrolling timer goes off
    private func scrollingTimerElapsed (source: Timer)
    {
        if autoScrollDelta == 0 {
            return
        }
        if autoScrollDelta < 0 {
            scrollUp(lines: autoScrollDelta * -1)
        } else {
            scrollUp(lines: autoScrollDelta)
        }
    }
    
    open override func mouseDown(with event: NSEvent) {
        if allowMouseReporting && terminal.mouseMode.sendButtonPress() {
            sharedMouseEvent(with: event)
            return
        }
        
        let hit = calculateMouseHit(with: event).grid

        // Whether this click *made* a selection rather than cleared one. A drag has no say
        // here; it settles on mouseUp.
        var settledSelection = false

        switch event.clickCount {
        case 1:
            if selection.active == true {
                if event.modifierFlags.contains(.shift) {
                    selection.shiftExtend(row: hit.row, col: hit.col)
                    settledSelection = true
                } else {
                    selection.active = false
                }
            }
        case 2:
            selection.selectWordOrExpression(at: Position(col: hit.col, row: hit.row + terminal.buffer.yDisp), in: terminal.buffer)
            settledSelection = true

        default:
            // 3 and higher

            selection.select(row: hit.row + terminal.buffer.yDisp)
            settledSelection = true
        }
        setNeedsDisplay(bounds)
        if settledSelection {
            selectionGestureEnded()
        }
    }
    
    func getPayload (for event: NSEvent) -> Any?
    {
        let hit = calculateMouseHit(with: event).grid
        let cd = terminal.buffer.lines [terminal.buffer.yDisp+hit.row][hit.col]
        return cd.getPayload()
    }
    
    var didSelectionDrag: Bool = false
    
    open override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command){
            if let payload = getPayload(for: event) as? String {
                if let (url, params) = urlAndParamsFrom(payload: payload) {
                    terminalDelegate?.requestOpenLink(source: self, link: url, params: params)
                }
            }
        }
        if allowMouseReporting && terminal.mouseMode.sendButtonRelease() {
            sharedMouseEvent(with: event)
            return
        }
        
        #if DEBUG
        // let hit = calculateMouseHit(with: event)
        //print ("Up at col=\(hit.col) row=\(hit.row) count=\(event.clickCount) selection.active=\(selection.active) didSelectionDrag=\(didSelectionDrag) ")
        #endif

        // The release is where a dragged selection is finally what the user meant, including
        // one the autoscroll timer kept extending past the edge of the view.
        let draggedASelection = didSelectionDrag && selection.active
        didSelectionDrag = false
        if draggedASelection {
            selectionGestureEnded()
        }
    }
    
    open override func mouseDragged(with event: NSEvent) {
        let mouseHit = calculateMouseHit(with: event)
        let hit = mouseHit.grid
        if allowMouseReporting {
            if terminal.mouseMode.sendMotionEvent() {
                let flags = encodeMouseEvent(with: event)
            
                terminal.sendMotion(buttonFlags: flags, x: hit.col, y: hit.row, pixelX: mouseHit.pixels.col, pixelY: mouseHit.pixels.row)
            
                return
            }
            if terminal.mouseMode != .off {
                return
            }
        }
                
        if selection.active {
            selection.dragExtend(row: hit.row, col: hit.col)
        } else {
            selection.startSelection(row: hit.row, col: hit.col)
        }
        didSelectionDrag = true
        autoScrollDelta = 0
        if selection.active {
            if hit.row <= 0 {
                autoScrollDelta = calcScrollingVelocity(delta: hit.row * -1) * -1
            } else if hit.row >= terminal.rows {
                autoScrollDelta = calcScrollingVelocity(delta: hit.row - terminal.rows)
            }
        }
        setNeedsDisplay(bounds)
    }
    
    func tryUrlFont () -> NSFont
    {
        for x in ["Optima", "Helvetica", "Helvetica Neue"] {
            if let font = NSFont (name: x, size: 12) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: 12)
    }
    
    // The payload contains the terminal data which is expected to be of the form
    // params;URL, so we need to extract the second component, but we also assume that
    // the input might be ill-formed, so we might return nil in that case
    func urlAndParamsFrom (payload: String) -> (String, [String:String])?
    {
        let split = payload.split(separator: ";", maxSplits: Int.max, omittingEmptySubsequences: false)
        if split.count > 1 {
            let pairs = split [0].split (separator: ":")
            var params: [String:String] = [:]
            for p in pairs {
                let kv = p.split (separator: "=")
                if kv.count == 2 {
                    params [String (kv [0])] = String (kv[1])
                }
            }
            return (String (split [1]), params)
        }
        return nil
    }
    
    var urlPreview: NSTextField?
    func previewUrl (payload: String)
    {
        if let (url, _) = urlAndParamsFrom(payload: payload) {
            if let up = urlPreview {
                up.stringValue = url
                up.sizeToFit()
            } else {
                let nup: NSTextField
                if #available(macOS 10.12, *) {
                    nup = NSTextField (string: url)
                } else {
                    nup = NSTextField ()
                }
                nup.isBezeled = false
                nup.font = tryUrlFont ()
                nup.backgroundColor = nativeForegroundColor
                nup.textColor = nativeBackgroundColor
                nup.sizeToFit()
                nup.frame = CGRect (x: 0, y: 0, width: nup.frame.width, height: nup.frame.height)
                addSubview(nup)
                urlPreview = nup
            }
        }
    }
    
    func removePreviewUrl ()
    {
        if let urlPreview = self.urlPreview {
            urlPreview.removeFromSuperview()
            self.urlPreview = nil
        }
    }
    
    /// The cell the last motion report named, so an unchanged one is not reported twice.
    var lastMotionCell: Position? = nil

    open override func mouseMoved(with event: NSEvent) {
        let hit = calculateMouseHit(with: event)
        if commandActive {
            if let payload = getPayload(for: event) as? String {
                previewUrl (payload: payload)
            }
        }

        // Motion is reported per *character cell*, not per pixel, which is the contract xterm
        // sets for modes 1002/1003 and what every client assumes. Reporting each AppKit
        // `mouseMoved` instead sent dozens of identical events per cell — trackpad jitter under
        // a resting hand is enough — and a client that recomputes what is under the pointer on
        // every report will do it against a screen its own last report just reflowed.
        guard allowMouseReporting && terminal.mouseMode.sendMotionEvent() else {
            lastMotionCell = nil
            return
        }
        guard hit.grid != lastMotionCell else { return }
        lastMotionCell = hit.grid

        let flags = encodeMouseEvent(with: event, overwriteRelease: true)
        terminal.sendMotion(buttonFlags: flags, x: hit.grid.col, y: hit.grid.row, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
    }
    
    /// Leftover precise-scroll distance not yet worth a whole line.
    private var scrollAccumulator: CGFloat = 0

    open override func scrollWheel(with event: NSEvent) {
        // When the application has enabled mouse reporting, the wheel belongs to it: the
        // event is encoded and written to the PTY — a full-screen program scrolls its own
        // content that way (Claude Code moves its transcript, not the scrollback). Holding
        // option falls back to scrolling the local scrollback, the escape hatch other
        // terminals offer for the same situation.
        if allowMouseReporting && terminal.mouseMode != .off
            && !event.modifierFlags.contains(.option) {
            forwardWheelEvent(event)
            return
        }

        guard let lines = wheelLineDelta(for: event) else { return }

        if lines > 0 {
            scrollUp(lines: lines)
        } else {
            scrollDown(lines: -lines)
        }
    }

    /// The whole lines a wheel event amounts to, or nil while a gesture has not yet
    /// accumulated one.
    ///
    /// Trackpads and Magic Mice report precise deltas, which are fractions of a line.
    /// Truncating those to an Int rounds almost every one of them to zero, so scrolling
    /// collapsed to a single line per event however fast the gesture was. Accumulate the
    /// distance instead and carry the remainder, which keeps fine scrolling and momentum
    /// proportional to the gesture.
    private func wheelLineDelta(for event: NSEvent) -> Int? {
        if event.hasPreciseScrollingDeltas {
            // A new gesture starts fresh, so leftovers cannot accumulate into a jump.
            if event.phase == .began {
                scrollAccumulator = 0
            }

            let lineHeight = cellDimension?.height ?? 0
            guard lineHeight > 0 else { return nil }

            scrollAccumulator += event.scrollingDeltaY

            let lines = Int(scrollAccumulator / lineHeight)
            guard lines != 0 else { return nil }
            scrollAccumulator -= CGFloat(lines) * lineHeight
            return lines
        }

        // A classic wheel reports whole notches, where a velocity curve reads best.
        if event.deltaY == 0 {
            return nil
        }
        let velocity = calcScrollingVelocity(delta: Int (abs (event.deltaY)))
        return event.deltaY > 0 ? velocity : -velocity
    }

    /// The measured rate wheel reports may be written at, shared with the iOS view so the two
    /// cannot drift apart. See `WheelReportBudget` for what a split report costs.
    private var wheelBudget = WheelReportBudget()

    /// The wheel's distance in lines *as reported to the application*.
    ///
    /// The scrollback path multiplies a classic notch by a velocity curve — up to a screenful
    /// for one event — which is a scrolling nicety and the wrong count to report: one notch is
    /// one wheel event, which is what the program expects to be told.
    private func wheelReportLines(for event: NSEvent) -> Int? {
        guard event.hasPreciseScrollingDeltas else {
            guard event.deltaY != 0 else { return nil }
            return event.deltaY > 0 ? 1 : -1
        }
        return wheelLineDelta(for: event)
    }

    /// Reports a wheel event to the application as mouse wheel button presses (64/65),
    /// one per accumulated line, at the pointer's cell — and no faster than the program
    /// on the other end reads them.
    ///
    /// A pty carries no message boundaries and its input queue fills a byte at a time, so a
    /// program that is mid-render when reports arrive resumes reading in the *middle* of one. A
    /// stdin parser that does not carry a partial escape sequence across reads then drops the
    /// orphaned `ESC [ <` and takes the rest for typing: `65;104;33M` landing in Claude Code's
    /// composer while scrolling is this, and nothing else. The reports themselves arrive in
    /// order — that was measured too, and it is not where this breaks.
    ///
    /// Rate is the whole fix, because the split is the reader's backlog draining, not our
    /// framing: writing a burst as one write instead of thirty made it *worse*. This gesture was
    /// worth up to 30 reports on its own, which cleared 1000 a second on any momentum flick.
    /// Reports past the budget are dropped rather than queued — a scroll the application never
    /// saw is a scroll that did not happen, and the next gesture already says where the user
    /// wants to be.
    private func forwardWheelEvent(_ event: NSEvent) {
        guard let lines = wheelReportLines(for: event) else { return }
        let reports = wheelBudget.grant(min(abs(lines), Int(WheelReportBudget.burst)))
        guard reports > 0 else { return }

        let hit = calculateMouseHit(with: event)
        let flags = terminal.encodeButton(
            button: lines > 0 ? 4 : 5,
            release: false,
            shift: event.modifierFlags.contains(.shift),
            meta: false,
            control: event.modifierFlags.contains(.control)
        )

        for _ in 0..<reports {
            terminal.sendEvent(
                buttonFlags: flags,
                x: hit.grid.col,
                y: hit.grid.row,
                pixelX: hit.pixels.col,
                pixelY: hit.pixels.row
            )
        }
    }
    
    private func calcScrollingVelocity (delta: Int) -> Int
    {
        if delta > 9 {
            return max (terminal.rows, 20)
        }
        if delta > 5 {
            return 10
        }
        if delta > 1 {
            return 3
        }
        return 1
    }
    
    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
    
    public func resetFontSize ()
    {
        fontSet = FontSet (font: FontSet.defaultFont)
    }
    
    func getImageScale () -> CGFloat {
        self.window?.backingScaleFactor ?? 1
    }
    
    func scale (image: NSImage, size: CGSize) -> NSImage {
        
        let scaledImg = TTImage (size: CGSize (width: size.width, height: size.height))
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        scaledImg.lockFocus()
        let srcRect = CGRect(origin: CGPoint.zero, size: image.size)
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw(in: dstRect, from: srcRect, operation: .copy, fraction: 1)
        
        scaledImg.unlockFocus()
        return scaledImg
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        guard let bitmapImage = NSBitmapImageRep (
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: NSColorSpaceName.calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        let stripe = NSImage (size: size)
        stripe.addRepresentation (bitmapImage)

        stripe.lockFocus()
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        image.draw(in: destRect, from: srcRect, operation: .copy, fraction: 1.0)
        stripe.unlockFocus()
        return stripe
    }
    
    open func showCursor(source: Terminal) {
        if caretView.superview == nil {
            addSubview(caretView)
        }
    }

    open func hideCursor(source: Terminal) {
        caretView.removeFromSuperview()
    }
    
    open func cursorStyleChanged (source: Terminal, newStyle: CursorStyle) {
        caretView.style = newStyle
        updateCaretView()
    }

    open func bell(source: Terminal) {
        terminalDelegate?.bell (source: self)
    }

    public func isProcessTrusted(source: Terminal) -> Bool {
        true
    }
    
    public func mouseModeChanged(source: Terminal) {
        if source.mouseMode == .anyEvent {
            startTracking()
        } else {
            if terminal != nil {
                deregisterTrackingInterest()
            }
        }
    }
    
    public func setTerminalTitle(source: Terminal, title: String) {
        terminalDelegate?.setTerminalTitle(source: self, title: title)
    }
    
    public func sizeChanged(source: Terminal) {
        if shouldReportSizeChange(newCols: source.cols, newRows: source.rows) {
            terminalDelegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
        }
        updateScroller ()
    }
    
    func ensureCaretIsVisible ()
    {
        let realCaret = terminal.buffer.y + terminal.buffer.yBase
        let viewportEnd = terminal.buffer.yDisp + terminal.rows
        
        if realCaret >= viewportEnd || realCaret < terminal.buffer.yDisp {
            scrollTo (row: terminal.buffer.yBase)
        }
    }
    
    public func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
    
    // Terminal.Delegate method implementation
    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        return nil
    }
    
    public func iTermContent (source: Terminal, content: ArraySlice<UInt8>) {
        terminalDelegate?.iTermContent(source: self, content: content)
    }
}


// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {
    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    NSWorkspace.shared.open(nested)
                }
            }
        }
    }
    
    public func bell (source: TerminalView)
    {
        NSSound.beep()
    }
    
    public func iTermContent (source: TerminalView, content: ArraySlice<UInt8>) {
    }
}
#endif
