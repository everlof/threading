//
//  iOSTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
//
//  The indicator "//X" means that this code was commented out from the Mac version for the sake of
//  porting and need to be audited.
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(iOS) || os(visionOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics

/**
 * TerminalView provides an AppKit/UIKit front-end to the `Terminal` terminal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 *
 * Developers might want to surface UIs for `optionAsMetaKey` which defaults to
 * true.  This means that Option-Letter is hijacked for terminal purposes
 * to send the sequence ESC-Letter.   Users can toggle this with command-option-o
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: UIScrollView, UITextInputTraits, UIKeyInput, UIScrollViewDelegate, TerminalDelegate {
    struct FontSet {
        public let normal: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
        
        static var defaultFont: UIFont {
            UIFont.monospacedSystemFont (ofSize: 12, weight: .regular)
        }
        
        public init(font baseFont: UIFont) {
            self.normal = baseFont
            if let boldDescriptor = baseFont.fontDescriptor.withSymbolicTraits ([.traitBold]) {
                self.bold = UIFont (descriptor: boldDescriptor, size: 0)
            } else {
                self.bold = baseFont
            }
            
            if let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic]) {
                self.italic = UIFont (descriptor: italicDescriptor, size: 0)
            } else {
                self.italic = baseFont
            }
            
            if let boldItalicDescriptor = baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic, .traitBold]) {
                self.boldItalic = UIFont (descriptor: boldItalicDescriptor, size: 0)
            } else {
                if self.italic != baseFont {
                    self.boldItalic = self.italic
                } else if self.bold != baseFont {
                    self.boldItalic = self.bold
                } else {
                    self.boldItalic = baseFont
                }
            }
        }
        
        public init (normal: UIFont, bold: UIFont, italic: UIFont, boldItalic: UIFont) {
            self.normal = normal
            self.bold = bold
            self.italic = italic
            self.boldItalic = boldItalic
        }
        
        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return -1.2
        }
        
        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return 0.63
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

    /**
     * If set, and the the client application has requested mouse events to be sent, this will
     * send the events.   If this value if false, then a secondary codepath is enabled that will
     * always allow the selection or the scrolling/panning to take place, regardless of the
     * request from the client application.
     *
     * Additionally, during a pan operation if allowMouseReporting is false, then this turns
     * panning operations into sending cursor key commands.
     *
     * If a client application has not indicated any use for mouse events, then this setting
     * does not do anything, and selection and panning are still processed.
     */
    public var allowMouseReporting: Bool = true {
        didSet {
            guard allowMouseReporting != oldValue else { return }
            // The touch mapping is part of this answer: with a tracking program the one-finger
            // pan belongs to it and the scroll view is left the two-finger one. A host that
            // will not forward reports has to get its finger back, or the gesture is claimed
            // and then dropped and nothing scrolls at all.
            mouseModeChanged (source: terminal)
        }
    }
    
    /**
     * If set, this turns Option-letter keystrokes into an escape + keystroke combination
     * which is convenient when you are an Emacs user for example.   But this means that
     * international input using the option key is not easy to enter.
     */
    public var optionAsMetaKey = true
    
    /**
     * If set to true, this will call the TerminalViewDelegate's rangeChanged method
     * when there are changes that are being performed on the UI
     */
    public var notifyUpdateChanges = false

    /// If true, the caret view will show different shapes depending on the focus
    /// otherwise, it will behave like it is focused
    public var caretViewTracksFocus: Bool {
        get {
            return caretView?.tracksFocus ?? false
        }
        set {
            caretView?.tracksFocus = newValue
        }
    }
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: UIView?
    var pendingDisplay: Bool = false
    var cellDimension: CellDimension!
    var caretView: CaretView?
    var terminal: Terminal!
    
    var selection: SelectionService!
    var attrStrBuffer: CircularList<ViewLineInfo>!
    var images:[(image: TerminalImage, col: Int, row: Int)] = []

    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]

    // Timer to display the terminal buffer
    var link: CADisplayLink!
    // Cache for the colors in the 0..255 range
    var colors: [UIColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:UIColor] = [:]
    var transparent = TTColor.transparent ()
    
    // UITextInput support starts
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer (textInput: self) // TerminalInputTokenizer()
    
    // We use this as temporary storage for UITextInput, which we send to the terminal on demand
    var textInputStorage: String = ""

    // This tracks the marked text, part of the UITextInput protocol, which is used to flag temporary data entry, that might
    // be removed afterwards by the input system (input methods will insert approximiations, mark and change on demand)
    var _markedTextRange: TextRange?

    // The input delegate is part of UITextInput, and we notify it of changes.
    public weak var inputDelegate: UITextInputDelegate?

    // This tracks the selection in the textInputStorage, it is not the same as our global selection, it is temporary
    var _selectedTextRange: TextRange = TextRange(from: TextPosition(offset: 0), to: TextPosition(offset: 0))

    var _markedTextStyle: [NSAttributedString.Key: Any]?

    // Used for the keyboard long-press gesture that works as a cursor
    var lastFloatingCursorLocation: CGPoint?
    
    var fontSet: FontSet
    
    /// The font to use to render the terminal, this attempts to derive the bold, italic and italic/bold variants from
    /// the original font, using the iOS UIFontDescriptor APIs.   For full control use the `setFonts(normal:bold:italic:boldItalic)`
    /// API instead
    public var font: UIFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont()
            selectNone()
        }
    }
    
    /// Sets the various fonts to be used by the terminal to render text, their size is ignored
    /// - Parameters:
    ///  - normal: The font used by default for most text
    ///  - bold: The font used for bold text
    ///  - italic: The font used for italic text
    ///  - boldItalic: The font used for text that is both bold and italic.
    public func setFonts (normal: UIFont, bold: UIFont, italic: UIFont, boldItalic: UIFont) {
        fontSet = FontSet (normal: normal, bold: bold, italic: italic, boldItalic: boldItalic)
        resetFont ()
        selectNone ()
    }
    
    public init(frame: CGRect, font: UIFont?) {
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
          
    func setup()
    {
        showsHorizontalScrollIndicator = true
        indicatorStyle = .white
        
        setupKeyboardButtonColors()
        setupDisplayUpdates ();
        setupOptions ()
        setupGestures ()
        setupAccessoryView ()
    }

    func setupDisplayUpdates ()
    {
        link = CADisplayLink(target: self, selector: #selector(step))
            
        link.add(to: .current, forMode: .default)
        suspendDisplayUpdates()
    }
    
    @objc
    func step(displaylink: CADisplayLink) {
        updateDisplay()
    }

    func startDisplayUpdates()
    {
        link.isPaused = false
    }
    
    func suspendDisplayUpdates()
    {
        link.isPaused = true
    }
    
    public func updateUiClosed() {
        self.link.invalidate()
    }
    
    @objc open override func paste (_ sender: Any?) {
        disableSelectionPanGesture()
        if let start = UIPasteboard.general.string {
            if terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteStart[0...])
            }
            send(txt: start)
            if terminal.bracketedPasteMode {
                send(data: EscapeSequences.bracketedPasteEnd[0...])
            }
            queuePendingDisplay()
        }
    }

    @objc open override func copy(_ sender: Any?) {
        UIPasteboard.general.string = selection.getSelectedText()
        selection.selectNone()
        disableSelectionPanGesture()
    }
        
    @objc open override func selectAll(_ sender: Any?) {
        selection.selectAll()
        enableSelectionPanGesture()
    }
    
    /// Invoked when the user has long-pressed and then clicked "Select"
    @objc public override func select (_ sender: Any?)  {
        if let loc = lastLongSelect {
            selection.selectWordOrExpression(at: Position (col: loc.col, row: loc.row), in: terminal.buffer)
            enableSelectionPanGesture()
            DispatchQueue.main.async {
                self.showContextMenu(forRegion:  self.makeContextMenuRegionForSelection(), pos: loc)
            }
            
        }
        lastLongSelect = nil
    }
    
    @objc func resetCmd(_ sender: Any?) {
        terminal.cmdReset()
        selection.selectNone()
        disableSelectionPanGesture()
        queuePendingDisplay()
    }

    @objc
    public override func canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return selection.active
        case #selector(paste(_:)):
            return true
        case #selector(select(_:)):
            return !selection.active
        case #selector(selectAll(_:)):
            return true
        case #selector(resetCmd(_:)):
            return true
        default:
            //print ("canPerformAction invoked for \(action)")
            return false
        }
    }
    
    /// Shows the context menu for the terminal, the arguments play a key role:
    /// - Parameters:
    ///  - region: This is the location that we want to avoid having the menu being shown
    ///  - pos: the location where this was triggered in the buffer, it used at a later point
    ///  to auto-select a word
    func showContextMenu (forRegion: CGRect, pos: Position) {
        var items: [UIMenuItem] = []
        
        lastLongSelect = pos
        lastLongSelectRegion = forRegion

        //GAR: Declutter context menu
        //items.append (UIMenuItem(title: "Reset", action: #selector(resetCmd)))
        
        // Configure the shared menu controller
        let menuController = UIMenuController.shared
        menuController.menuItems = items
        
        // Set the location of the menu in the view.
        //let menuLocation = CGRect (origin: at, size: CGSize (width: cellDimension.width, height: cellDimension.height))
        menuController.showMenu(from: self, rect: forRegion)
    }
    
    // This is a position relative to the buffer
    var lastLongSelect: Position?
    var lastLongSelectRegion = CGRect.zero
    
    /// Creates a region suitable to be passed to the showContextMenu that wants a
    /// region for the menu to avoid.
    func makeContextMenuRegionForTap (point: CGPoint) -> CGRect {
        CGRect (origin: point, size: CGSize (width: cellDimension.width, height: cellDimension.height))
    }
                    
    func makeContextMenuRegionForSelection () -> CGRect {
        let width = selection.isMultiLine ? frame.width : CGFloat(selection.end.col-selection.start.col)*cellDimension.width
        
        return CGRect (x: CGFloat (selection.start.col)*cellDimension.width,
                       y: CGFloat (selection.start.row)*cellDimension.height,
                       width: width,
                       height: CGFloat (selection.end.row-selection.start.row+1)*cellDimension.height)
    }
    
    @objc func longPress (_ gestureRecognizer: UILongPressGestureRecognizer)
    {
         if gestureRecognizer.state == .began {
             let _ = self.becomeFirstResponder()
             let tapLocation = gestureRecognizer.location(in: gestureRecognizer.view)
             let tapRegion = makeContextMenuRegionForTap (point: tapLocation)
             
             showContextMenu (forRegion: tapRegion,
                              pos: calculateTapHit (gesture: gestureRecognizer).grid)
          }
    }
    
    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false
    
    /// Returns a buffer-relative position, instead of a screen position.
    /// - Parameters:
    ///   - gesture: the location of where the event took place
    /// - Returns: both the position where the event took place (either in screen resolution, or buffer relative) and the pixel position to construct the menu location
    func calculateTapHit (gesture: UIGestureRecognizer) -> (grid: Position, pixels: Position)
    {
        calculateTapHit (point: gesture.location(in: self))
    }

    /// The same answer for a point this view already holds, so a host that routes a tap itself
    /// does not have to manufacture a gesture recognizer to ask.
    func calculateTapHit (point: CGPoint) -> (grid: Position, pixels: Position)
    {
        func toInt (_ p: CGPoint) -> Position {
            
            let x = min (max (p.x, 0), bounds.width)
            let y = min (max (p.y, 0), bounds.height)
            return Position (col: Int (x), row: Int (y))
        }

        let col = Int (point.x / cellDimension.width)
        let row = Int (point.y / cellDimension.height)
        if row < 0 {
            return (Position(col: 0, row: 0), toInt (point))
        }
        return (Position(col: min (max (0, col), terminal.cols-1), row: row), toInt (point))
    }

    func encodeFlags (release: Bool) -> Int
    {
        let encodedFlags = terminal.encodeButton(
            // Button zero, the left one. `encodeButton` takes xterm's own numbering, where 1 is
            // the *middle* button — the Mac passes `NSEvent.buttonNumber`, which is 0 for a
            // left click, and this passed 1. So every tap reached the program as a middle
            // click, which a TUI that offers something to click on ignores: the phone was
            // reporting a button nobody listens for.
            button: 0,
            release: release,
            shift: false,
            meta: false,
            control: terminalAccessory?.controlModifier ?? false)
        terminalAccessory?.controlModifier = false
        return encodedFlags
    }
    
    func sharedMouseEvent (gestureRecognizer: UIGestureRecognizer, release: Bool)
    {
        sharedMouseEvent (at: gestureRecognizer.location(in: self), release: release)
    }

    func sharedMouseEvent (at point: CGPoint, release: Bool)
    {
        let hit = calculateTapHit(point: point)
        if let grid = hit.grid.toScreenCoordinate(from: terminal.buffer) {
            terminal.sendEvent(buttonFlags: encodeFlags (release: release), x: grid.col, y: grid.row, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
        }
    }

    /// The size one character cell occupies, which is what turns a point into a cell.
    ///
    /// Public because `forwardTap(at:)` is: a host that routes its own taps has to be able to
    /// say where one landed, and the grid it lands on may be the size of another machine's.
    public var cellSize: CGSize {
        CGSize (width: cellDimension.width, height: cellDimension.height)
    }

    /// Reports the click a tap at `point` stands for, and says whether anything wanted it.
    ///
    /// The press and its release travel together: a tap has no dwell, and a program told only
    /// that a button went down waits for a release that a finger never sends. `false` means no
    /// program is tracking the mouse, so the caller still owns the gesture.
    @discardableResult
    public func forwardTap (at point: CGPoint) -> Bool {
        guard allowMouseReporting && terminal.mouseMode.sendButtonPress() else { return false }

        sharedMouseEvent (at: point, release: false)
        if terminal.mouseMode.sendButtonRelease() {
            sharedMouseEvent (at: point, release: true)
        }
        queuePendingDisplay()
        return true
    }
    
    // Returns the offsets into getTerminal().buffer.lines for the first visible and last visible lines
    func getVisibleLineRange () -> ClosedRange<Int> {
        let topVisibleLine = contentOffset.y/cellDimension.height
        let bottomVisibleLine = (topVisibleLine+frame.height/cellDimension.height)-1

        return Int(topVisibleLine)...Int(bottomVisibleLine)
    }
    
    public func repositionVisibleFrame () {
        let topVisibleLine = contentOffset.y/cellDimension.height
        let bottomVisibleLine = (topVisibleLine+frame.height/cellDimension.height)-1
        let lines = self.terminal.buffer.lines.count
        contentOffset.y = max(0, CGFloat(lines) - bottomVisibleLine) * cellDimension.height
    }
    
    /// A tap over a program that tracks the mouse is that program's click, whether or not this
    /// view is holding the keyboard.
    ///
    /// Gating the whole gesture on first responder spent the first tap after the keyboard was
    /// put away on taking it back, so a phone reading a full-screen TUI could never reach the
    /// affordances the TUI draws — Claude Code's "click to go to bottom" among them. Taking the
    /// keyboard here instead would cover the thing just clicked, so the click is reported and
    /// focus is left where the person put it; the host offers its own control for asking the
    /// keyboard back.
    @objc func singleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }

        if gestureRecognizer.state != .ended {
            return
        }

        if forwardTap (at: gestureRecognizer.location(in: self)) {
            return
        }

        guard isFirstResponder else {
            let _ = becomeFirstResponder ()
            return
        }

        if selection.active {
            selection.selectNone()
            disableSelectionPanGesture()
        }
        if UIMenuController.shared.isMenuVisible {
            UIMenuController.shared.hideMenu()
        } else {
            let location = gestureRecognizer.location(in: gestureRecognizer.view)
            let tapLoc = calculateTapHit(gesture: gestureRecognizer).grid
            // The cursor's absolute row is fixed to the live screen, so it is `yBase`
            // it is measured from — `yDisp` is wherever the viewport has been scrolled.
            let cursorRow = terminal.buffer.y+terminal.buffer.yBase
            if abs (tapLoc.col-terminal.buffer.x) < 4 && abs (tapLoc.row - cursorRow) < 2 {
                showContextMenu (forRegion: makeContextMenuRegionForTap (point: location), pos: tapLoc)
            }
        }
        queuePendingDisplay()
    }
    
    @objc func doubleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }

        if gestureRecognizer.state != .ended {
            return
        }

        // Over a tracking program a single tap is that program's click, so a double tap is the
        // finger's deliberate ask for the keyboard. The pair's first tap already reached the
        // program through the single-tap recognizer — repeating the same click cannot be what
        // a second tap in the same spot meant.
        if !isFirstResponder && allowMouseReporting && terminal.mouseMode.sendButtonPress() {
            let _ = becomeFirstResponder ()
            return
        }

        if forwardTap (at: gestureRecognizer.location(in: self)) {
            return
        }

        let hit = calculateTapHit(gesture: gestureRecognizer).grid
        selection.selectWordOrExpression(at: hit, in: terminal.buffer)
        enableSelectionPanGesture()
        showContextMenu (forRegion: makeContextMenuRegionForSelection(), pos: hit)
        queuePendingDisplay()
    }
    
    var directionView: UIView?
    var directionCount: Int = 0
    var lastCursorImage: String? = nil
    func createDirectionView () -> UIView {
        let timeout = 0.5
        if directionView == nil {
            let w = 80
            let h = 80
            let f = frame
            directionView = UIView (
                frame: CGRect (x: (Int (f.width)-w)/2,
                               y: (Int(f.height)-w)/2,
                               width: w,
                               height: h))
            addSubview(directionView!)
        }
        let dv = directionView!
        dv.backgroundColor = UIColor.gray
        dv.alpha = 0.5
        
        directionCount += 1
        DispatchQueue.main.asyncAfter (deadline: .now() + timeout) {
            self.directionCount -= 1
            if self.directionCount == 0 {
                if let dv = self.directionView {
                    self.directionView = nil
                    UIView.animate(withDuration: 0.3, animations: {
                        dv.alpha = 0
                    }, completion: { x in
                        dv.removeFromSuperview()
                    })
                }
            }
        }
        return dv
    }
    
    func sendKey (deltaCol: Int, deltaRow: Int) {
        if deltaCol == 0 && deltaRow == 0 { return }
        let host = createDirectionView()
        var imgName: String? = nil
        if deltaRow > 0 {
            imgName = "arrow.up.square.fill"
            sendKeyUp()
        } else if deltaRow < 0 {
            imgName = "arrow.down.square.fill"
            sendKeyDown()
        }
        if deltaCol > 0 {
            imgName = "arrow.left.square.fill"
            sendKeyLeft()
        } else if deltaCol < 0 {
            imgName = "arrow.right.square.fill"
            sendKeyRight()
        }
        if imgName == nil {
            SwiftTermDiagnostics.emit(.fault, .uiDirectionKeyInvariant)
        }
        guard let name = imgName else { return }

        if lastCursorImage == name { return }
        guard let img = UIImage(systemName: name) else { return }
        lastCursorImage = name
        if let child = host.subviews.first {
            child.removeFromSuperview()
        }

        let imgView = UIImageView (image: img)
        host.addSubview (imgView)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.center = host.center
        imgView.topAnchor.constraint(equalTo: host.topAnchor, constant: 0).isActive = true
        imgView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 0).isActive = true
        imgView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: 0).isActive = true
        imgView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: 0).isActive = true
        imgView.tintColor = .white
    }
    
    /// Leftover drag distance not yet worth a whole line to report.
    var wheelDragAccumulator: CGFloat = 0

    /// The measured rate wheel reports may be written at, shared with the Mac view.
    var wheelBudget = WheelReportBudget()

    /// A one-finger drag over a program that tracks the mouse.
    ///
    /// It reports the drag as **wheel** buttons rather than as a press and motion. A finger is
    /// this device's wheel: a full-screen program scrolls its own content when it is told the
    /// wheel turned — Claude Code moves its transcript that way, which is the only way to reach
    /// history it has already scrolled past — whereas the press-and-drag this used to send is a
    /// selection gesture that leaves the content exactly where it was. That is why scrolling a
    /// mirrored agent TUI from the phone did nothing at all. The Mac has reported the wheel
    /// since `MacTerminalView.scrollWheel`; this is the same routing with a finger for a wheel,
    /// and two fingers left over for the local scrollback the same way option-wheel is on the Mac.
    @objc func panMouseHandler (_ gestureRecognizer: UIPanGestureRecognizer){
        guard gestureRecognizer.view != nil else { return }
        guard allowMouseReporting && terminal.mouseMode != .off else { return }
        switch gestureRecognizer.state {
        case .began:
            // A new gesture starts fresh, so leftovers cannot accumulate into a jump.
            wheelDragAccumulator = 0
        case .changed:
            let travelled = gestureRecognizer.translation(in: self).y
            gestureRecognizer.setTranslation(.zero, in: self)
            forwardWheelDrag (distance: travelled, gestureRecognizer: gestureRecognizer)
        default:
            break
        }
    }

    /// Reports `distance` points of drag to the application as wheel presses (64/65), one per
    /// whole line travelled and no faster than the program on the other end reads them. Reports
    /// past the budget are dropped rather than queued: a scroll the application never saw is a
    /// scroll that did not happen, and the rest of the gesture already says where to be.
    public func forwardWheelDrag (distance: CGFloat, gestureRecognizer: UIGestureRecognizer) {
        let cellHeight = cellDimension.height
        guard cellHeight > 0 else { return }

        wheelDragAccumulator += distance
        let lines = Int (wheelDragAccumulator / cellHeight)
        guard lines != 0 else { return }
        wheelDragAccumulator -= CGFloat (lines) * cellHeight

        let reports = wheelBudget.grant (min (abs (lines), Int (WheelReportBudget.burst)))
        guard reports > 0 else { return }

        let hit = calculateTapHit (gesture: gestureRecognizer)
        guard let grid = hit.grid.toScreenCoordinate (from: terminal.buffer) else { return }
        // Dragging the content down asks for what is above it, which is the wheel turning up.
        let flags = terminal.encodeButton (
            button: lines > 0 ? 4 : 5,
            release: false,
            shift: false,
            meta: false,
            control: false
        )
        for _ in 0..<reports {
            terminal.sendEvent (
                buttonFlags: flags,
                x: grid.col,
                y: grid.row,
                pixelX: hit.pixels.col,
                pixelY: hit.pixels.row
            )
        }
    }
   
    func startSelectionTimer (_ callback: @MainActor @escaping ()->()) {
        panTask = Task {
            while !Task.isCancelled {
                callback ()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    
    func stopSelectionTimer () {
        panTask?.cancel()
        panTask = nil
    }
    
    // The start of the pan operation, for the case where we are not sending the input to the client
    var panStart: Position?
    var panTask: Task<(),Never>?
    
    @objc func panSelectionHandler (_ gestureRecognizer: UIPanGestureRecognizer) {
        func near (_ pos1: Position, _ pos2: Position) -> Bool {
            return abs (pos1.col-pos2.col) < 3 && abs (pos1.row-pos2.row) < 2
        }
        
        switch gestureRecognizer.state {
        case .began:
            let hit = calculateTapHit(gesture: gestureRecognizer).grid
            if selection.active {
                var extend = false
                if near (selection.start, hit) {
                    selection.pivot = selection.end
                    extend = true
                } else if near (selection.end, hit) {
                    selection.pivot = selection.start
                    extend = true
                }
                if extend {
                    selection.pivotExtend(bufferPosition: hit)
                    setNeedsDisplay()
                    break
                }
            }
            panStart = hit
        case .changed:
            let absoluteY = gestureRecognizer.location (in: self).y - contentOffset.y
            let hit = calculateTapHit(gesture: gestureRecognizer).grid
            if selection.active {
                stopSelectionTimer()
                selection.pivotExtend(bufferPosition: hit)
                gestureRecognizer.setTranslation(CGPoint.zero, in: self)
                if absoluteY < 0 || absoluteY > bounds.height {
                    startSelectionTimer {
                        let newPlace = CGRect (x: 0, y: max (0, self.contentOffset.y+absoluteY), width: self.bounds.width, height: self.bounds.height)
                        self.scrollRectToVisible(newPlace, animated: true)
                    }
                }
                setNeedsDisplay()
            } else {
                if let ps = panStart {
                    let deltaRow = ps.row - hit.row
                    if allowMouseReporting {
                        // TODO: what scenario would have this?
                        scrollDown (lines: deltaRow)
                    } else {
                        let deltaCol = ps.col - hit.col
                        
                        sendKey (deltaCol: deltaCol, deltaRow: deltaRow)
                    }
                }
            }
        case .ended:
            stopSelectionTimer()
            if selection.active {
                showContextMenu (forRegion: makeContextMenuRegionForSelection(), pos: calculateTapHit(gesture: gestureRecognizer).grid)
            }
            break
        case .cancelled:
            stopSelectionTimer()
            selection.active = false
        default:
            break
        }
    }
    
    public private(set) var panMouseGesture: UIPanGestureRecognizer?

    /// Hands one finger to the application and keeps two for the local scrollback.
    ///
    /// Both gestures live on this same scroll view, and two pan recognizers on one view do not
    /// both get to recognise: without the touch count telling them apart, whichever won took the
    /// drag and the other behaviour became unreachable. Two fingers is this device's option-wheel.
    func enableMousePanGesture () {
        guard panMouseGesture == nil else {
            return
        }
        let gesture = UIPanGestureRecognizer (target: self, action: #selector(panMouseHandler))
        gesture.maximumNumberOfTouches = 1
        addGestureRecognizer(gesture)
        panMouseGesture = gesture
        panGestureRecognizer.minimumNumberOfTouches = 2
    }
    
    func disableMousePanGesture () {
        guard let gesture = panMouseGesture else {
            return
        }
        removeGestureRecognizer(gesture)
        panMouseGesture = nil
        panGestureRecognizer.minimumNumberOfTouches = 1
    }
    
    var panSelectionGesture: UIPanGestureRecognizer?
    func enableSelectionPanGesture () {
        guard panSelectionGesture == nil else {
            return
        }
        let gesture = UIPanGestureRecognizer (target: self, action: #selector(panSelectionHandler))
        addGestureRecognizer(gesture)
        self.panSelectionGesture = gesture
    }
    
    func disableSelectionPanGesture() {
        guard let gesture = panSelectionGesture else {
            return
        }
        removeGestureRecognizer(gesture)
        panSelectionGesture = nil
    }
    
    func setupGestures ()
    {
        let longPress = UILongPressGestureRecognizer (target: self, action: #selector(longPress(_:)))
        longPress.minimumPressDuration = 0.7
        addGestureRecognizer(longPress)
        
        let singleTap = UITapGestureRecognizer (target: self, action: #selector(singleTap(_:)))
        addGestureRecognizer(singleTap)
        
        let doubleTap = UITapGestureRecognizer (target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    
    var _inputAccessory: UIView?
    var _inputView: UIView?
    
    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    #if os(visionOS)
    public var inputAccessoryView: UIView? {
        get { _inputAccessory }
        set {
            _inputAccessory = newValue
        }
    }
    #else
    public override var inputAccessoryView: UIView? {
        get { _inputAccessory }
        set {
            _inputAccessory = newValue
        }
    }
    #endif

    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    public override var inputView: UIView? {
        get { _inputView }
        set {
            _inputView = newValue
        }
    }

    /// Returns the inputaccessory in case it is a TerminalAccessory and we can use it
    var terminalAccessory: TerminalAccessory? {
        get {
            _inputAccessory as? TerminalAccessory
        }
    }

    func setupAccessoryView ()
    {
        let short = UIDevice.current.userInterfaceIdiom == .phone
        let ta = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: frame.width, height: short ? 36 : 48),
                                   inputViewStyle: .keyboard, container: self)
        #if !os(visionOS)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        #endif
        ta.sizeToFit()
        inputAccessoryView = ta
        
        //inputAccessoryView?.autAoresizingMask = .flexibleHeight
    }
    
    func setupOptions ()
    {
        setupOptions(width: bounds.width, height: bounds.height)
        layer.backgroundColor = nativeBackgroundColor.cgColor
        nativeBackgroundColor = UIColor.clear
    }
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    var _nativeBoldFg: UIColor?
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: UIColor {
        get { _nativeFg }
        set {
            if settingFg { return }
            settingFg = true
            _nativeFg = newValue
            terminal.foregroundColor = nativeForegroundColor.getTerminalColor ()
            settingFg = false
        }
    }
    
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeBackgroundColor: UIColor {
        get { _nativeBg }
        set {
            if settingBg { return }
            settingBg = true
            _nativeBg = newValue
            terminal.backgroundColor = nativeBackgroundColor.getTerminalColor ()
            colorsChanged()
            settingBg = false
        }
    }

    /// **Ours.** The colour bold text drawn with the *default* foreground is rendered in —
    /// Terminal.app's "Bold Text" — or nil to draw it in `nativeForegroundColor`, which is what
    /// SwiftTerm did before this existed.
    ///
    /// Bold text that names an ANSI colour is unaffected: it keeps the 0–7 to 8–15 bright shift.
    public var nativeBoldForegroundColor: UIColor? {
        get { _nativeBoldFg }
        set {
            guard _nativeBoldFg != newValue else { return }
            _nativeBoldFg = newValue
            // The attribute caches resolved the bold styles through the old answer.
            attributes = [:]
            urlAttributes = [:]
            terminal.updateFullScreen ()
            queuePendingDisplay ()
        }
    }

    /// **Ours.** The colour this attribute's text is drawn in, after inverse, the bold
    /// foreground, bold-as-bright and SGR 2 faintness have all resolved. A seam for the
    /// embedder's tests; the renderer itself uses the same call.
    public func resolvedForegroundColor (for attribute: Attribute) -> UIColor
    {
        resolvedForeground (for: attribute)
    }

    /// Controls the color for the caret
    public var caretColor: UIColor {
        get { caretView?.caretColor ?? UIColor.black }
        set { caretView?.caretColor = newValue }
    }
    
    /// Controls the color for the text in the caret when using a block cursor, if not set
    /// the cursor will render with the foreground color
    public var caretTextColor: UIColor? {
        get { caretView?.caretTextColor }
        set { caretView?.caretTextColor = newValue }
    }
    
    /// Controls weather to use high ansi colors, if false terminal will use bold text instead of high ansi colors
    public var useBrightColors: Bool = true

    var _selectedTextBackgroundColor = UIColor (red: 204.0/255.0, green: 221.0/255.0, blue: 237.0/255.0, alpha: 1.0)
    /// The color used to render the selection
    public var selectedTextBackgroundColor: UIColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
        }
    }
    
    var _selectionHandleColor: UIColor = UIColor.systemBlue
    /// The color used to render the selection handles
    public var selectionHandleColor: UIColor {
        get {
            return _selectionHandleColor
        }
        set {
            _selectionHandleColor = newValue
        }
    }

    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    var lineLeading: CGFloat = 0
    
    open func bufferActivated(source: Terminal) {
        // A buffer switch has no scroll position worth keeping: the alternate buffer has no
        // scrollback at all, and coming back from one lands on the live tail.
        source.userScrolling = false
        updateScroller ()
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
    
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    open func getOptimalFrameSize () -> CGRect
    {
        return CGRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols), height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    func getImageScale () -> CGFloat {
        self.window?.contentScaleFactor ?? 1
    }
    
    func getEffectiveWidth (size: CGSize) -> CGFloat
    {
        return size.width
    }
    
    func updateDebugDisplay ()
    {
    }
    
    func scale (image: UIImage, size: CGSize) -> UIImage {
        UIGraphicsBeginImageContext(size)
        
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw (in: dstRect)
        
        let ret = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return ret
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        guard let cropCG = image.cgImage?.cropping(to: srcRect) else {
            return nil
        }
        let uicrop = UIImage (cgImage: cropCG)
        
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return nil
        }
        ctx.translateBy(x: 0, y: dstHeight)
        ctx.scaleBy(x: 1, y: -1)

        uicrop.draw(in: destRect)
        
        let stripe = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return stripe
    }

    open func scrolled(source terminal: Terminal, yDisp: Int) {
        //XselectionView.notifyScrolled(source: terminal)
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
    }
    
    open func linefeed(source: Terminal) {
        selection.selectNone()
        disableSelectionPanGesture()
    }
    
    /// The offset this view last put there itself, so a later one that differs can only have
    /// come from the person dragging.
    var appliedOffsetY: CGFloat = 0

    /// `buffer.linesTop` as of the last `updateScroller`. It counts the lines the emulator has
    /// dropped off the top of its scrollback, which is how far the text under a held viewport
    /// has moved since.
    var reportedLinesTop = 0

    func updateScroller ()
    {
        let cellHeight = cellDimension.height
        contentSize = CGSize (width: CGFloat (terminal.buffer.cols) * cellDimension.width,
                              height: CGFloat (terminal.buffer.lines.count) * cellHeight)

        let trimmed = terminal.buffer.linesTop - reportedLinesTop
        reportedLinesTop = terminal.buffer.linesTop

        // A drag and the momentum after it own the offset outright: assigning to
        // `contentOffset` under a live gesture stops deceleration dead. The text still slides
        // up as the emulator trims its scrollback, so the offset follows it by that many lines
        // and the line being read stays under the finger.
        if isTracking || isDragging || isDecelerating {
            if trimmed > 0 {
                setContentOffsetY (max (0, contentOffset.y - CGFloat (trimmed) * cellHeight))
            }
            return
        }

        // `yDisp` is the first visible row, and the emulator holds it above the live tail for
        // as long as `terminal.userScrolling` is set. Following it here is what lets a scroll
        // back survive output. Pinning to `lines.count - rows` instead — which is where the
        // bottom is, unconditionally — is what made a streaming agent impossible to read back
        // through on iOS: every line written yanked the viewport down again, faster than a
        // finger can drag it up. The Mac side has had the `userScrolling` seam all along.
        setContentOffsetY (CGFloat (terminal.buffer.yDisp) * cellHeight)
    }

    /// Moves the viewport and records that this view, rather than the person holding it, is
    /// what moved it.
    func setContentOffsetY (_ y: CGFloat)
    {
        appliedOffsetY = y
        contentOffset = CGPoint (x: 0, y: y)
    }

    open override func layoutSubviews ()
    {
        super.layoutSubviews ()
        trackScrollPosition ()
    }

    /// Mirrors an offset this view did not set back into the emulator. `yDisp` is what
    /// selection, mouse reporting and the caret read as the first visible row, and
    /// `terminal.userScrolling` is what keeps `Terminal.scroll` from resetting it to the live
    /// tail on the very next write.
    ///
    /// UIScrollView calls `layoutSubviews` on every offset change, so this is the one place
    /// that sees a drag, its momentum, and a host restoring a saved position alike. It is O(1)
    /// on purpose: it runs once per scrolled frame.
    func trackScrollPosition ()
    {
        guard terminal != nil else { return }
        let cellHeight = cellDimension.height
        guard cellHeight > 0 else { return }
        guard abs (contentOffset.y - appliedOffsetY) > 0.5 else { return }
        appliedOffsetY = contentOffset.y
        guard !terminal.isCurrentBufferAlternate else { return }
        let row = min (max (Int ((contentOffset.y / cellHeight).rounded ()), 0), terminal.buffer.yBase)
        if row != terminal.buffer.yDisp {
            terminal.buffer.yDisp = row
        }
        terminal.userScrolling = row < terminal.buffer.yBase
    }
    
    var userScrolling = false

    func getCurrentGraphicsContext () -> CGContext?
    {
        UIGraphicsGetCurrentContext ()
    }

    func backingScaleFactor () -> CGFloat
    {
        #if os(visionOS)
        1.0
        #else
        UIScreen.main.scale
        #endif
    }
    
    override public func draw (_ dirtyRect: CGRect) {
        guard let context = getCurrentGraphicsContext() else {
            return
        }

        // Without these two lines, on font changes, some junk is being displayed
        // Once we test the font change, we could disable these two lines, and
        // enable the #if false in drawterminalContents that should be coping with this now
        nativeBackgroundColor.set ()
        context.fill ([dirtyRect])

        // drawTerminalContents and CoreText expect the AppKit coordinate system
        context.scaleBy (x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)

        drawTerminalContents (dirtyRect: dirtyRect, context: context, bufferOffset: 0)
    }
    
    open override var bounds: CGRect {
        get {
            return super.bounds
        }
        set {
            super.bounds = newValue
            if cellDimension == nil {
                return
            }
            processSizeChange(newSize: newValue.size)
            setNeedsDisplay (bounds)
        }
    }

    open override var frame: CGRect {
        get {
            return super.frame
        }
        set {
            super.frame = newValue
            if cellDimension == nil {
                return
            }
            processSizeChange(newSize: newValue.size)
            setNeedsDisplay (bounds)
            updateCursorPosition()
        }
    }

    // iOS Keyboard input
    
    // UITextInputTraits
    public var keyboardType: UIKeyboardType {
        get {
            .`default`
        }
    }
    
    public var keyboardAppearance: UIKeyboardAppearance = .`default`
    public var returnKeyType: UIReturnKeyType = .`default`
    
    // This is wrong, but I can not find another good one
    public var textContentType: UITextContentType! = .none
    
    public var isSecureTextEntry: Bool = false
    public var enablesReturnKeyAutomatically: Bool = false
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    
    open override var canBecomeFirstResponder: Bool {
        true
    }
    
    open override var canBecomeFocused: Bool {
        true
    }
    
    public var hasText: Bool {
        return true
    }

    /*
        Soft keyboard input. Hardware keyboard input is handled in pressesBegan.
    */
    open func insertText(_ text: String) {
        uitiLog("insertText(\"\(text)\") textInputStorage:\"\(textInputStorage)\"")

        let rangeToReplace = _markedTextRange ?? _selectedTextRange
        let rangeStartIndex = rangeToReplace.startPosition.offset
        textInputStorage.replaceSubrange(rangeToReplace.fullRange(in: textInputStorage), with: text)
        _markedTextRange = nil
        let insertedPosition = TextPosition(offset: rangeStartIndex + text.count)
        _selectedTextRange = TextRange(from: insertedPosition, to: insertedPosition)

        if terminalAccessory?.controlModifier ?? false {
            self.send(applyControlToEventCharacters(text))
            terminalAccessory?.controlModifier = false
        } else {
            if text == "\n" {
                resetInputBuffer()
                self.send(data: returnByteSequence [0...])
            } else {
                self.send(txt: text)
            }
        }
        
        queuePendingDisplay()
    }

    func ensureCaretIsVisible ()
    {
        // Typing rejoins the live tail. The emulator has to be told to stop holding `yDisp`
        // above it as well, or the next line of output pulls the viewport straight back up to
        // wherever the user had scrolled to.
        terminal.userScrolling = false
        terminal.buffer.yDisp = terminal.buffer.yBase
        setContentOffsetY (CGFloat (terminal.buffer.lines.count-terminal.rows)*cellDimension.height)
    }
    
    public func deleteBackward() {
        uitiLog("deleteBackward() textInputStorage:\"\(textInputStorage)\" markedTextRange:\"\(_markedTextRange)\" selectedTextRange:\"\(_selectedTextRange)\"")
        inputDelegate?.selectionWillChange(self)

        // after backward deletion, marked range is always cleared, and length of selected range is always zero
        let rangeToDelete = _markedTextRange ?? _selectedTextRange
        var rangeStartPosition = rangeToDelete.startPosition
        var rangeStartIndex = rangeStartPosition.offset
        if rangeToDelete.isEmpty {
            // If there is no selected text, delete the character before the cursor

            if rangeStartIndex == 0 {
                // This is the case when the user hits backspace, but there is no text in the
                // text input buffer.  This happens for example when text has been pasted.
                // In that scenario, we should just send the backspace character to the terminal
                self.send ([backspaceSendsControlH ? 8 : 0x7f])
                uitiLog("deleteBackward() no text to delete, sending backspace")
                return
            }

            rangeStartIndex -= 1
            textInputStorage.remove(at: textInputStorage.index(textInputStorage.startIndex, offsetBy: rangeStartIndex))
            rangeStartPosition = TextPosition(offset: rangeStartIndex)

            self.send ([backspaceSendsControlH ? 8 : 0x7f])
        } else {
            // Send as many backspaces that are in the range to delete. When on auto-repeat, after a some time
            // pressing the backspace, it will delete chunks of text at a time.
            let oldText = textInputStorage[rangeToDelete.fullRange(in: textInputStorage)]
            let backspaces = oldText.count
            for _ in 0..<backspaces {
                self.send ([backspaceSendsControlH ? 8 : 0x7f])
            }

            textInputStorage.removeSubrange(rangeToDelete.fullRange(in: textInputStorage))
        }
        
        _markedTextRange = nil
        _selectedTextRange = TextRange(from: rangeStartPosition, to: rangeStartPosition)

        inputDelegate?.selectionDidChange(self)
    }

    enum SendData {
        case text(String)
        case bytes([UInt8])
    }
    
    func sendData (data: SendData?)
    {
        switch data {
        case .bytes(let b):
            self.send (b)
        case .text(let txt):
            self.send (txt: txt)
        default:
            break
        }
    }
 
    open override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            caretView?.updateCursorStyle()
            terminal.setTerminalFocus(true)
        }
        return response
    }
    
    open override func resignFirstResponder() -> Bool {
        let code = super.resignFirstResponder()
        
        if code {
            terminal.setTerminalFocus(false)
            caretView?.disableAnimations()
            caretView?.updateView()
            keyRepeat?.invalidate()
            keyRepeat = nil
            
            terminalAccessory?.cancelTimer()
        }
        return code
    }
    var keyRepeat: Timer?
    
    /// It looks like sending carriage return works on Unix and Windows remote hosts, so add that, but keeping a public
    /// property in case someone needs the return key to send different sequences.
    public var returnByteSequence: [UInt8] = [13]
    
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var didHandleEvent = false
        
        for press in presses {
            guard let key = press.key else { continue }
                
            var data: SendData? = nil

            switch key.keyCode {
            case .keyboardCapsLock:
                break // ignored
            case .keyboardLeftAlt:
                break // ignored
            case .keyboardLeftControl:
                break // ignored
            case .keyboardLeftShift:
                break // ignored
            case .keyboardLockingCapsLock:
                break // ignored
            case .keyboardLockingNumLock:
                break // ignored
            case .keyboardLockingScrollLock:
                break // ignored
            case .keyboardRightAlt:
                break // ignored
            case .keyboardRightControl:
                break // ignored
            case .keyboardRightShift:
                break // ignored
            case .keyboardScrollLock:
                break // ignored
            case .keyboardUpArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
            case .keyboardDownArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            case .keyboardLeftArrow:
                if key.modifierFlags.contains ([.alternate]) {
                    data = .bytes (EscapeSequences.emacsBack)
                } else if key.modifierFlags.contains ([.control]) {
                    data = .bytes (EscapeSequences.controlLeft)
                } else {
                    data = .bytes (terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
                }
            case .keyboardRightArrow:
                if key.modifierFlags.contains ([.alternate]) {
                    data = .bytes (EscapeSequences.emacsForward)
                } else if key.modifierFlags.contains ([.control]) {
                    data = .bytes (EscapeSequences.controlRight)
                } else {
                    data = .bytes (terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
                }
            case .keyboardPageUp:
                if terminal.applicationCursor {
                    data = .bytes (EscapeSequences.cmdPageUp)
                } else {
                    pageUp()
                }

            case .keyboardPageDown:
                if terminal.applicationCursor {
                    data = .bytes (EscapeSequences.cmdPageDown)
                } else {
                    pageDown()
                }
            case .keyboardHome:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
                
            case .keyboardEnd:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
            case .keyboardDeleteForward:
                data = .bytes (EscapeSequences.cmdDelKey)
                
            case .keyboardDeleteOrBackspace:
                data = .bytes ([backspaceSendsControlH ? 8 : 0x7f])
                
            case .keyboardEscape:
                data = .bytes ([0x1b])
                
            case .keyboardInsert:
                SwiftTermDiagnostics.emit(.debug, .uiKeyboardInsertUnsupported)
                break
                
            case .keyboardReturn:
                data = .bytes (returnByteSequence)
                
            case .keyboardTab:
                data = .bytes ([9])

            case .keyboardF1:
                data = .bytes (EscapeSequences.cmdF [1])
            case .keyboardF2:
                data = .bytes (EscapeSequences.cmdF [2])
            case .keyboardF3:
                data = .bytes (EscapeSequences.cmdF [3])
            case .keyboardF4:
                data = .bytes (EscapeSequences.cmdF [4])
            case .keyboardF5:
                data = .bytes (EscapeSequences.cmdF [5])
            case .keyboardF6:
                data = .bytes (EscapeSequences.cmdF [6])
            case .keyboardF7:
                data = .bytes (EscapeSequences.cmdF [7])
            case .keyboardF8:
                data = .bytes (EscapeSequences.cmdF [8])
            case .keyboardF9:
                data = .bytes (EscapeSequences.cmdF [9])
            case .keyboardF10:
                data = .bytes (EscapeSequences.cmdF [10])
            case .keyboardF11:
                data = .bytes (EscapeSequences.cmdF [11])
            case .keyboardF12, .keyboardF13, .keyboardF14, .keyboardF15, .keyboardF16,
                 .keyboardF17, .keyboardF18, .keyboardF19, .keyboardF20, .keyboardF21,
                 .keyboardF22, .keyboardF23, .keyboardF24:
                break
            case .keyboardPause, .keyboardStop, .keyboardMute, .keyboardVolumeUp, .keyboardVolumeDown:
                break
                
            default:
                if key.modifierFlags.contains ([.alternate, .command]) && key.charactersIgnoringModifiers == "o" {
                    optionAsMetaKey.toggle()
                } else if key.modifierFlags.contains (.alternate) && optionAsMetaKey {
                    data = .text("\u{1b}\(key.charactersIgnoringModifiers)")
                } else if !key.modifierFlags.contains (.command){
                    if key.characters.count > 0 {
                        data = .text (key.characters)
                    }
                }
            }
            if let sendableData = data {
                didHandleEvent = true
                keyRepeat?.invalidate()
                keyRepeat = Timer (fire: Date(timeInterval: 0.4, since: Date()),
                                   interval: 0.1,
                                   repeats: true) { timer in
                    self.sendData(data: sendableData)
                }
                RunLoop.current.add(keyRepeat!, forMode: .default)
                sendData (data: sendableData)
            }
        }
        if didHandleEvent == false {
            super.pressesBegan(presses, with: event)
        }
    }
    
    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keyRepeat?.invalidate()
        keyRepeat = nil
        super.pressesEnded(presses, with: event)
    }
    
    var pendingSelectionChanged = false
    
    var buttonBackgroundColor: UIColor = .white
    var buttonShadowColor: UIColor = .black
    var buttonColor: UIColor = .black
    var buttonDarkBackgroundColor: UIColor = .systemGray
    func setupKeyboardButtonColors ()
    {
        func getColor (_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            return UIColor (red: r/255.0, green: g/255.0, blue: b/255.0, alpha: 1.0)
        }
        if traitCollection.userInterfaceStyle == .dark {
            buttonBackgroundColor = UIColor (red: 150/255.0, green: 150/255.0, blue: 150/255.0, alpha: 1)
            buttonShadowColor = UIColor (red: 26/255.0, green: 26/255.0, blue: 26/255.0, alpha: 1)
            buttonColor = .white
            buttonDarkBackgroundColor = getColor (117, 117, 117)
        } else {
            buttonBackgroundColor = UIColor (red: 1, green: 1, blue: 1, alpha: 1)
            buttonShadowColor = UIColor (red: 139/255.0, green: 141/255.0, blue: 144/255.0, alpha: 1)
            buttonColor = .black
            buttonDarkBackgroundColor = getColor (180, 184, 193)
        }
    }
    
    open func showCursor(source: Terminal) {
        guard let caretView else { return }
        if caretView.superview == nil {
            addSubview(caretView)
        }
    }

    open func hideCursor(source: Terminal) {
        caretView?.removeFromSuperview()
    }
    
    open func cursorStyleChanged (source: Terminal, newStyle: CursorStyle) {
        caretView?.style = newStyle
        updateCaretView()
    }

    open func bell(source: Terminal) {
        terminalDelegate?.bell (source: self)
    }

    open func selectionChanged(source: Terminal) {
        if pendingSelectionChanged {
            return
        }
        pendingSelectionChanged = true
        DispatchQueue.main.async {
            self.pendingSelectionChanged = false
            
            self.inputDelegate?.selectionWillChange (self)
            self.inputDelegate?.selectionDidChange(self)
 
            self.setNeedsDisplay (self.bounds)
            
            if !self.selection.active {
                UIMenuController.shared.hideMenu()
                self.selection.selectNone()
                self.disableSelectionPanGesture()
            }
        }
    }

    open func isProcessTrusted(source: Terminal) -> Bool {
        true
    }
    
    open func mouseModeChanged(source: Terminal) {
        if allowMouseReporting && source.mouseMode != .off {
            enableMousePanGesture()
        } else {
            disableMousePanGesture()
        }
    }
    
    open func setTerminalTitle(source: Terminal, title: String) {
        DispatchQueue.main.async {
            self.terminalDelegate?.setTerminalTitle(source: self, title: title)
        }
    }
  
    open func sizeChanged(source: Terminal) {
        let reportsSizeChange = shouldReportSizeChange(
            newCols: source.cols,
            newRows: source.rows
        )
        DispatchQueue.main.async {
            if reportsSizeChange {
                self.terminalDelegate?.sizeChanged(
                    source: self,
                    newCols: source.cols,
                    newRows: source.rows
                )
            }
            self.updateScroller()
        }
    }
  
    open func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
  
    // Terminal.Delegate method implementation
    open func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        return nil
    }
    
    public func clipboardCopy(source: Terminal, content: Data) {
        terminalDelegate?.clipboardCopy(source: self, content: content)
    }

    public func iTermContent (source: Terminal, content: ArraySlice<UInt8>) {
        terminalDelegate?.iTermContent(source: self, content: content)
    }
}

// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {    
    public func bell (source: TerminalView)
    {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
        #endif
    }
    
    public func iTermContent (source: TerminalView, content: ArraySlice<UInt8>) {
    }
}

#endif
