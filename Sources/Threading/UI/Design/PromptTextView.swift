import AppKit

// MARK: - Prompt Text View

/// The editable surface inside a `PromptView`, also mounted by platform hosts that
/// supply their own surrounding composer chrome.
///
/// Exists for three behaviours `NSTextView` does not have: a placeholder, Return meaning
/// *submit* rather than *newline*, and files arriving by drag or paste becoming prompt
/// attachments or paths instead of being refused (images) or pasted as attachment cells.
final class PromptTextView: ThemedTextView {

    /// Virtual Return key code; the Linux event shim maps SDL Return to this AppKit code.
    static let returnKeyCode: UInt16 = 36

    /// The same scroll and document wiring used by the production composer. A host can
    /// mount this without rebuilding TextKit setup or changing the editor's key semantics.
    static func scrollingPrompt() -> PromptTextScrollView { PromptTextScrollView() }

    // MARK: - Properties

    var placeholder: String = "" { didSet { needsDisplay = true } }

    /// Return, without a modifier — or ⌘Return, always.
    var onSubmit: ((PromptSubmitIntent) -> Void)?

    /// Gives the owning composer first refusal for navigation/acceptance while a completion
    /// panel is visible. Marked text bypasses this hook so IME candidate selection remains
    /// entirely inside the input method.
    var onCompletionKey: ((NSEvent) -> Bool)?

    /// Whether a bare Return sends, asked at the keystroke. Answering `false` leaves Return to
    /// the editor and keeps ⌘Return as the only way to send from the keyboard.
    ///
    /// A closure rather than a flag because the answer is a user setting as well as a property
    /// of the surface; see `PromptView.submitsOnReturn()`.
    var submitsOnReturn: () -> Bool = { true }

    /// Paths for whatever was dropped or pasted, already written to disk.
    #if !os(Linux)
    var onAttach: (([String]) -> Void)?
    #endif

    /// Lets the owning surface draw focus around the whole composer, not merely blink a caret
    /// inside one descendant.
    var onFocusChange: ((Bool) -> Void)?

    /// Lets the owning surface light as one drop target while a drag the composer can take is
    /// over the editor — the same reason as `onFocusChange`: AppKit routes the drag to the
    /// deepest registered view, so over the text this view is the destination and the box
    /// around it would otherwise never hear about the pointer it is supposed to answer.
    #if !os(Linux)
    var onDropTargetChange: ((Bool) -> Void)?
    #endif

    /// Common plain-text editor configuration for `PromptView` and platform hosts.
    /// The caller still chooses its font surface and submit policy.
    func configureForPromptEditing() {
        isEditable = true
        isSelectable = true
        drawsBackground = false
        isRichText = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        autoresizingMask = [.width]

        // A prompt often contains paths or shell flags, where substituted punctuation
        // changes the meaning of what the user wrote.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // While focused the accent border and insertion caret are the cue. Drawing the
        // placeholder at the selection origin after `super` can cover that caret and make a
        // successfully focused editor appear inert.
        guard window?.firstResponder !== self,
              string.isEmpty,
              !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Design.Typography.body(),
            .foregroundColor: Design.Text.tertiary
        ]

        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            needsDisplay = true
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            needsDisplay = true
            onFocusChange?(false)
        }
        return resigned
    }

    /// A view taken out of its window loses the first responder without ever being *asked* to
    /// resign it, so the two callbacks above do not cover every way the caret leaves. Left
    /// alone the composer keeps drawing its accent ring around a box nothing is typing into,
    /// which is the one state a focus ring may never describe.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // The drag overrides below are inert until AppKit registers the view as a drag
        // destination, and `NSTextView` never registers one built the way this one is:
        // programmatic text network, plain text, hosted in a scroll view. The measured state
        // was `registeredDraggedTypes == []`, which is not "refuses images" — it is the
        // window server never routing the drag here at all, so `acceptableDragTypes` was
        // never read and `readSelection` never called. The composer therefore refused every
        // dropped image while ⌘V of the same image worked, since paste reaches
        // `readSelection` without going near drag registration.
        //
        // **This has to be here rather than in setup.** Registering before the view has a
        // window leaves `registeredDraggedTypes` empty just the same; only a call once the
        // view is in a window sticks.
        #if !os(Linux)
        updateDragTypeRegistration()
        #endif

        onFocusChange?(window?.firstResponder === self)
    }

    // MARK: - Key Handling

    /// Two rules hold whatever the surface and whatever the user has set, so there is always a
    /// key that cannot surprise: **⌘Return sends**, and **Shift- or Option-Return breaks the
    /// line**. What a bare Return does is the only part that varies, and `submitsOnReturn`
    /// answers it — the composer's own default unless `DesignSettings.current.promptReturnKey` overrides.
    ///
    /// ⌘Return is handled here as well as by whatever button names it, because a prompt is
    /// used without one — the chord belongs to the *field*, and only reaches a key equivalent
    /// when someone put one in the same window.
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onCompletionKey?(event) == true {
            return
        }
        guard event.keyCode == Self.returnKeyCode else {
            super.keyDown(with: event)
            return
        }

        // Return belongs to the input method for as long as one has marked text: with a
        // Japanese, Chinese or Korean IME, Return is how a conversion candidate is *accepted*,
        // and it arrives here long before the user has finished the word. Sending on it posts
        // a half-written prompt — and worse, one missing the very characters still uncommitted,
        // since marked text is not yet in `string`. This is the same bug filed against Claude
        // Code, Copilot Chat, Cursor and JetBrains' AI assistant; the fix everywhere is to let
        // the composition have the key. ⌘Return is included deliberately: a send that drops
        // the uncommitted tail is the defect, not the modifier.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) {
            onSubmit?(.immediate)
            return
        }

        let wantsNewline = !submitsOnReturn()
            || modifiers.contains(.shift)
            || modifiers.contains(.option)

        if wantsNewline {
            super.keyDown(with: event)
            return
        }

        onSubmit?(.standard)
    }

    #if !os(Linux)
    // MARK: - Drag and Paste

    /// Both drops and pastes arrive here, so one implementation serves the pointer and the
    /// keyboard alike.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let paths = PromptAttachment.paths(from: pboard)

        if !paths.isEmpty {
            onAttach?(paths)
            return true
        }

        // Promised rather than carried: taken here, attached when the source has written it.
        // Falling through to `super` for one of these would insert the promise's placeholder
        // text into the prompt, which is the shape of "the drop worked" over nothing at all.
        let promised = DroppedFilePromise.receive(from: pboard) { [weak self] delivered in
            self?.onAttach?(delivered)
        }
        if promised { return true }

        return super.readSelection(from: pboard, type: type)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + DroppedFilePromise.readableTypes + super.readablePasteboardTypes
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + DroppedFilePromise.readableTypes + super.acceptableDragTypes
    }

    /// Reported by what the composer would *take*, not by what the editor would accept:
    /// `super` answers yes to a plain-text drag too, and a box that lights its attachment
    /// affordance for text it will simply insert is promising the wrong thing.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        onDropTargetChange?(
            PromptAttachment.canRead(pasteboard) || DroppedFilePromise.canRead(pasteboard)
        )
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChange?(false)
        super.draggingExited(sender)
    }

    /// A drop or a cancel ends the drag without exiting — see `PromptView.draggingEnded`.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargetChange?(false)
        super.draggingEnded(sender)
    }
    #endif
}

/// A prompt editor with its scroll view and text network already connected.
final class PromptTextScrollView: ThemedScrollView {
    let textView: PromptTextView

    init() {
        textView = PromptTextView(frame: .zero, textContainer: nil)
        super.init(frame: .zero)

        textView.configureForPromptEditing()
        documentView = textView
        drawsBackground = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Which of a composer's two affirmatives was asked for.
///
/// ⌘Return has one meaning across this app: **the more committed of two**. `ContextCommentAlert`
/// established it — Return parks the comment beside the prompt, ⌘Return hands it over now — and
/// the composer reuses it rather than inventing a second idea for the same chord.
enum PromptSubmitIntent: Equatable {
    /// A bare Return, or the send glyph.
    case standard

    /// ⌘Return.
    case immediate
}
