import SwiftUI
import SwiftTerm
import ThreadingRemoteKit
import UIKit

/// The latch state shared between the key bar, which shows and toggles it, and the terminal
/// coordinator, which spends it on the next typed keystroke. It also carries the live
/// terminal view so key encoding can honour DECCKM — an unmodified arrow is SS3 while the
/// full-screen TUI has application cursor mode on, which the fixed bar always got wrong.
@MainActor
final class TerminalKeyBridge: ObservableObject {
    @Published private(set) var latch = RemoteTerminalLatchState()
    private(set) var touchHeldModifiers: RemoteTerminalKeyModifiers = []
    private var touchModifiersUsedByAKey: RemoteTerminalKeyModifiers = []
    private(set) weak var terminalView: RemoteTerminalView?
    private var terminalAttachmentGeneration: UInt64 = 0

    /// Whether the person wants the keyboard up in this terminal: raised whenever the terminal
    /// takes the keyboard, lowered only by the bar's own dismiss. A pop, a sheet or the app
    /// going to the background hide the keyboard without changing what was wanted, and what
    /// was wanted is what a reopened chat restores — the keyboard used to come up on every
    /// reopen and stay wherever iOS left it on return, which read as two different rules.
    @Published private(set) var keyboardWantedUp = true
    private var keyboardObserver: NSObjectProtocol?

    init() {
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.terminalView?.isFirstResponder == true else { return }
                self.keyboardWantedUp = true
            }
        }
    }

    /// Attaches the live emulator outside a SwiftUI graph teardown.
    ///
    /// A property observer used to publish `canShowKeyboard` for both attach and detach. SwiftUI
    /// dismantles representables while invalidating that same observation graph, so the detach
    /// publication re-entered AttributeGraph and tripped Swift's exclusivity runtime. Attachment
    /// is an ordinary update and may publish immediately.
    func attachTerminalView(_ view: RemoteTerminalView) {
        terminalAttachmentGeneration &+= 1
        terminalView = view
        refreshKeyboardAvailability()
    }

    /// Clears one exact emulator without publishing from `dismantleUIView`'s call stack.
    ///
    /// The following main-actor turn reconciles the bar if it survived the teardown. A new view
    /// attached in between advances the generation and cannot be overwritten by this stale
    /// detach.
    func detachTerminalView(_ view: RemoteTerminalView) {
        guard terminalView === view else { return }
        terminalAttachmentGeneration &+= 1
        let generation = terminalAttachmentGeneration
        terminalView = nil
        Task { @MainActor [weak self] in
            guard let self,
                  self.terminalAttachmentGeneration == generation,
                  self.terminalView == nil else { return }
            self.refreshKeyboardAvailability()
        }
    }

    deinit {
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
        }
    }

    /// What the chat remembered from last time, applied before the terminal decides whether
    /// to take the keyboard on creation.
    func seedKeyboardWanted(_ wanted: Bool) {
        keyboardWantedUp = wanted
    }

    /// The line composer took the keyboard: writing there is writing in this chat.
    func noteKeyboardWanted() {
        keyboardWantedUp = true
    }

    var applicationCursorActive: Bool {
        terminalView?.terminalStateSnapshot().applicationCursor ?? false
    }

    /// Whether the program on the Mac has asked for bracketed paste, as seeded into this
    /// phone's emulator at attach. Quoted lines go in as one paste when it has.
    var bracketedPasteActive: Bool {
        terminalView?.terminalStateSnapshot().bracketedPasteMode ?? false
    }

    /// Encodes a complete touch-key activation with the live emulator's keyboard contract.
    /// Codex enables kitty event reporting, where a touch has both a press and a release; using
    /// the legacy key table omitted half of the contract it negotiated. Raw sequences and
    /// snippets remain deliberately raw.
    func encodedBytes(for action: RemoteTerminalKeyAction) -> [UInt8]? {
        let latched = modifiersForNextKey
        guard case .named(let key, let ownModifiers) = action,
              let terminalView else {
            return RemoteTerminalKeyEncoder.bytes(
                for: action,
                latched: latched,
                applicationCursor: applicationCursorActive
            )
        }

        let modifiers = ownModifiers.union(latched).kittyModifiers
        guard var bytes = terminalView.encodedFunctionalKey(
            key.kittyFunctionalKey,
            modifiers: modifiers,
            eventType: .press
        ) else { return nil }
        if terminalView.terminalStateSnapshot().keyboardEnhancementFlags.contains(.reportEvents),
           let release = terminalView.encodedFunctionalKey(
               key.kittyFunctionalKey,
               modifiers: modifiers,
               eventType: .release
           ) {
            bytes.append(contentsOf: release)
        }
        return bytes
    }

    func tap(_ modifier: RemoteTerminalLatchingModifier) {
        var next = latch
        next.tap(modifier)
        latch = next
    }

    /// Begins a real two-finger chord. SwiftUI's `Button` action arrives on release, which is too
    /// late for a second key tapped while this finger is still down, so the transient hold lives
    /// beside (and composes with) the tap-to-arm latch.
    func modifierTouchBegan(_ modifier: RemoteTerminalLatchingModifier) {
        let keyModifier = keyModifier(for: modifier)
        touchModifiersUsedByAKey.subtract(keyModifier)
        touchHeldModifiers.formUnion(keyModifier)
    }

    func modifierTouchEnded(_ modifier: RemoteTerminalLatchingModifier) {
        touchHeldModifiers.subtract(keyModifier(for: modifier))
    }

    /// Handles the button activation which follows touch-up. A modifier already used by another
    /// key was a held chord, not a request to arm the next key, so that release is consumed.
    /// Accessibility activation has no touch lifecycle and takes the ordinary latch path.
    @discardableResult
    func activate(_ modifier: RemoteTerminalLatchingModifier) -> Bool {
        let keyModifier = keyModifier(for: modifier)
        if touchModifiersUsedByAKey.contains(keyModifier) {
            touchModifiersUsedByAKey.subtract(keyModifier)
            return false
        }
        tap(modifier)
        return true
    }

    var modifiersForNextKey: RemoteTerminalKeyModifiers {
        latch.heldModifiers.union(touchHeldModifiers)
    }

    func consumeModifiersAfterKey() {
        touchModifiersUsedByAKey.formUnion(touchHeldModifiers)
        guard !latch.isIdle else { return }
        var next = latch
        next.consumeArmed()
        if next != latch { latch = next }
    }

    /// Folds held latches into bytes the system keyboard produced. Only a single byte counts
    /// as the keystroke a latch was armed for: longer runs may be pasted text or the
    /// emulator's own protocol replies (cursor-position reports travel this same delegate),
    /// and a latch must be neither applied to nor spent by bytes nobody typed.
    func applyLatchesToTyped(_ bytes: [UInt8]) -> [UInt8] {
        let held = modifiersForNextKey
        guard !held.isEmpty, bytes.count == 1 else { return bytes }
        let transformed = RemoteTerminalKeyEncoder.applyLatched(held, toTyped: bytes)
        consumeModifiersAfterKey()
        return transformed
    }

    /// Whether the terminal is holding the keyboard open right now.
    ///
    /// The bar's own state is fed by the keyboard notifications, which only say what *changed*.
    /// Arriving at a session that already has the keyboard up produces no notification at all,
    /// so the bar has to be able to ask.
    var isKeyboardShowing: Bool {
        terminalView?.isFirstResponder ?? false
    }

    /// Puts the system keyboard away.
    ///
    /// This used to be `UIApplication.sendAction(#selector(UIResponder.resignFirstResponder),
    /// to: nil, …)`, the broadcast that works for a `UITextField`. It does not reach this
    /// terminal — measured, and `TerminalKeyboardDismissalTests` keeps measuring it — so the
    /// button did nothing whatsoever. The view holding the keyboard is right here on the bridge:
    /// ask it directly, and let the window answer for a composer or anything else that took the
    /// keyboard instead.
    func dismissKeyboard() {
        keyboardWantedUp = false
        dismissKeyboardForModeSwitch()
    }

    /// Puts the keyboard away for an input-mode switch, not for good: what was wanted stands.
    func dismissKeyboardForModeSwitch() {
        if let terminalView, terminalView.isFirstResponder {
            _ = terminalView.resignFirstResponder()
        }
        keyWindow?.endEditing(true)
    }

    /// Whether this terminal will take the keyboard at all.
    ///
    /// A view-only session refuses first responder, and a control that can do nothing should not
    /// be offered — the dismiss half was never shown to a viewer either, because a viewer could
    /// not have the keyboard up to begin with.
    ///
    /// Published rather than computed, because the bar reads it during body evaluation and the
    /// answer changes outside SwiftUI's sight: the terminal attaches only after the bar's first
    /// render, and input mode can flip on a live view. As a computed property over an
    /// unpublished weak reference nothing invalidated the bar, so the show control stayed
    /// missing and only the dismiss half ever appeared.
    @Published private(set) var canShowKeyboard = false

    /// Re-reads what the attached terminal will accept. Attachment refreshes by itself; the
    /// representable calls this after `setAllowsKeyboardInput`, the answer's other input.
    func refreshKeyboardAvailability() {
        let refreshed = terminalView?.canBecomeFirstResponder ?? false
        if canShowKeyboard != refreshed { canShowKeyboard = refreshed }
    }

    /// Brings the system keyboard back.
    ///
    /// Tapping the terminal used to be the only way to ask for it. Over a program that tracks
    /// the mouse a tap is that program's click now — the phone would otherwise have no way to
    /// reach what a TUI draws — so the way back to the keyboard lives on this bar instead.
    func showKeyboard() {
        guard let terminalView, !terminalView.isFirstResponder else { return }
        _ = terminalView.becomeFirstResponder()
    }

    private var keyWindow: UIWindow? {
        terminalView?.window
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
    }

    private func keyModifier(
        for modifier: RemoteTerminalLatchingModifier
    ) -> RemoteTerminalKeyModifiers {
        switch modifier {
        case .control: return .control
        case .alt: return .alt
        }
    }
}

/// Resolves the stock, word-like key captions through the app's localization catalog while
/// leaving user-authored labels and snippet text untouched. A custom label is presentation
/// content, not a localization key, and must never be sent through `NSLocalizedString`.
func terminalKeyDisplayLabel(_ key: RemoteTerminalKeyDefinition) -> String {
    if let customLabel = key.customLabel, !customLabel.isEmpty {
        return customLabel
    }
    guard case .named(let namedKey, let modifiers) = key.action else {
        return key.action.defaultLabel
    }

    var prefix = ""
    if modifiers.contains(.control) { prefix += "⌃" }
    if modifiers.contains(.alt) { prefix += "⌥" }
    if modifiers.contains(.shift) { prefix += "⇧" }

    let label: String
    switch namedKey {
    case .escape: label = MobileL10n.string("esc")
    case .tab: label = MobileL10n.string("tab")
    case .home: label = MobileL10n.string("home")
    case .end: label = MobileL10n.string("end")
    case .pageUp: label = MobileL10n.string("pgup")
    case .pageDown: label = MobileL10n.string("pgdn")
    default: label = namedKey.defaultLabel
    }
    return prefix + label
}

/// Submitting snippets are not ordinary encoded key input. They need the host's atomic terminal
/// submission route so their text and Return reach the PTY as two writes.
func terminalKeySubmissionText(_ action: RemoteTerminalKeyAction) -> String? {
    guard case .snippet(let text, true) = action else { return nil }
    return text
}

/// SF Symbols used by the terminal key bar. Keeping these names testable matters because an
/// unknown symbol produces an empty `Image` while the button continues reserving its full slot.
enum TerminalKeyBarSymbols {
    static let attachments = "paperclip"
    static let showKeyboard = "keyboard"
    static let hideKeyboard = "keyboard.chevron.compact.down"
    static let customizeKeys = "keyboard.badge.ellipsis"
    static let directInput = "terminal"
    static let composeInput = "square.and.pencil"

    static let all = [
        attachments,
        showKeyboard,
        hideKeyboard,
        customizeKeys,
        directInput,
        composeInput,
    ]
}

enum TerminalKeyBarMetrics {
    /// The key row hugs the keyboard, so its caps are deliberately shorter and tighter than a
    /// full-height control: a cap is one of many small targets in a dense strip, and the action
    /// row above carries the bar's full-height utilities. Apple Color Emoji outgrows the text
    /// face's nominal line box, so the compact cap keeps a 34-point ink well. The well is the
    /// cap's height; what a glyph draws inside it is the font's. 🫡's face is cropped at its
    /// right edge in the artwork Apple Color Emoji ships on iOS 26.5 and macOS 26.5 — the PNG in
    /// the font's `sbix` table is cut — so it draws that way in every app on the phone, and in
    /// CoreText, UIKit and SwiftUI alike. No label pipeline here can complete it.
    static let keyHeight: CGFloat = 34
    /// The air inside a cap around its label, and the air the cap run keeps between itself and
    /// whatever fixed thing bounds it: the bar's edge, the divider before the keyboard toggle,
    /// the paperclip's target. It is also the line both rows stand their outermost mark on —
    /// the bottom row a cap's plate, the action row a glyph's ink — so the two rows read as
    /// one bar rather than as a strip under a toolbar.
    static let keyPadding: CGFloat = 8
    /// The tight ink padding would let a lone arrow collapse to a sliver; a cap never gets
    /// narrower than a comfortable square.
    static let minimumKeyWidth: CGFloat = 34
    static let actionHeight: CGFloat = MobileDesign.Size.compactControl
    /// The face the bar's glyph controls draw their symbols in, which is also the face they
    /// are measured at.
    static let glyphFont: Font = .subheadline

    /// The padding that stands a glyph control's *ink* on `keyPadding` at the bar's edge. The
    /// control is the full target with its symbol centred, so between the frame's edge and the
    /// ink lies the control's optical inset on that edge, and the row pulls the frame out over
    /// the edge by that much — the rule the composer's paperclip already keeps. Placed by its
    /// frame, the paperclip's ink stood eleven points inboard of the cap the bottom row starts
    /// with, and the trailing glyphs four points inboard of the keyboard toggle's. The inset is
    /// read off SwiftUI's own render of the symbol in this very frame, per edge
    /// (`MobileDesign.Size.symbolInsets`): the bar's symbols differ by seven points in width
    /// and are not all centred, and the key editor's badge hangs nearly two points past the box
    /// SwiftUI lays out — a pull sized to the face, or to the box, or to the bare symbol's ink,
    /// each stood it one to three points over the line.
    @MainActor
    static func edgeInset(
        for systemName: String,
        weight: Font.Weight = .regular,
        edge: MobileDesign.Size.SymbolInsets.Edge
    ) -> CGFloat {
        keyPadding - MobileDesign.Size.symbolInsets(
            systemName,
            font: glyphFont.weight(weight),
            in: CGSize(width: MobileDesign.Size.minimumTapTarget, height: actionHeight)
        ).inset(at: edge)
    }
}

/// One press treatment for every key cap. The fill and small travel are driven by the actual
/// gesture lifetime, so a held modifier reads as held before a second finger reaches another key.
private struct TerminalKeyCapButtonStyle: ButtonStyle {
    let theme: RemoteThemePalette
    let restingFill: SwiftUI.Color
    var pressChanged: (Bool) -> Void = { _ in }
    var forcePressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed || forcePressed
        return configuration.label
            .background(
                isPressed ? theme.controlHover : restingFill,
                in: RoundedRectangle(cornerRadius: theme.controlRadius)
            )
            .scaleEffect(isPressed ? 0.96 : 1)
            .offset(y: isPressed ? 1 : 0)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: MobileDesign.Motion.controlResponse / 2),
                value: isPressed
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                pressChanged(isPressed)
            }
    }
}

/// The action row's trailing controls. Their composite SF Symbols do not share a bounding
/// box: the customization badge hangs below its keyboard chassis while the Direct-input glyph
/// is a plain chassis, so aligning the buttons by their equal frames puts the two boxes on
/// different rows. SF Symbols expose the common typographic baseline, and it stays the single
/// owner of their optical vertical alignment.
struct TerminalKeyBarActionControls: View {
    let customize: () -> Void
    let showsInputModeControl: Bool
    let inputPreference: MobileTerminalInputPreference
    let effectiveInputMode: MobileTerminalInputMode
    let canChooseInputPreference: Bool
    let toggleInputPreference: () -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Button(action: customize) {
                trailingIcon(TerminalKeyBarSymbols.customizeKeys)
            }
            .accessibilityLabel(MobileL10n.string("Customize keys"))

            if showsInputModeControl {
                Button(action: toggleInputPreference) {
                    trailingIcon(inputModeSymbol)
                }
                .disabled(!canChooseInputPreference)
                .accessibilityLabel(inputModeAccessibilityLabel)
                .accessibilityValue(inputModeAccessibilityValue)
            }
        }
    }

    /// The symbol on the row's trailing edge, which the bar stands on its margin by its ink.
    var trailingSymbol: String {
        showsInputModeControl ? inputModeSymbol : TerminalKeyBarSymbols.customizeKeys
    }

    private var inputModeSymbol: String {
        effectiveInputMode == .independentComposer
            ? TerminalKeyBarSymbols.composeInput
            : TerminalKeyBarSymbols.directInput
    }

    private var inputModeAccessibilityLabel: String {
        guard canChooseInputPreference else {
            return MobileL10n.string("Compose terminal input is required")
        }
        return inputPreference == .direct
            ? MobileL10n.string("Compose terminal input")
            : MobileL10n.string("Use direct terminal input")
    }

    private var inputModeAccessibilityValue: String {
        effectiveInputMode == .independentComposer
            ? MobileL10n.string("Compose")
            : MobileL10n.string("Direct")
    }

    /// The key caps are hit-testable across their whole cap because each carries a filled
    /// background. These two carry none, and an `Image` inside a larger `frame` answers taps
    /// only on the glyph itself — so both trailing controls were a fraction of the tap target
    /// they reserve. `contentShape` is what makes the reserved area the real one.
    private func trailingIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(TerminalKeyBarMetrics.glyphFont)
            .foregroundStyle(theme.secondaryLabel)
            .frame(
                width: MobileDesign.Size.minimumTapTarget,
                height: TerminalKeyBarMetrics.actionHeight
            )
            .contentShape(Rectangle())
    }
}

/// The two-row strip under the remote terminal. The bottom row hugs the keyboard and starts with
/// the stock key run; a person may move any cap to the top row to put it beside attachments,
/// Direct/Compose and the key editor. The way back from the keyboard stays fixed at the bottom
/// row's trailing edge, and latch keys arm or lock the next press from either row.
struct TerminalKeyBar: View {
    @ObservedObject var connection: RemoteSessionConnection
    @ObservedObject var bridge: TerminalKeyBridge
    let agentKind: String
    let customize: () -> Void
    let inputPreference: MobileTerminalInputPreference
    let effectiveInputMode: MobileTerminalInputMode
    let canChooseInputPreference: Bool
    let toggleInputPreference: () -> Void
    let showsAttachmentKey: Bool
    let canAttach: Bool
    /// Asks the owner to open the source chooser: it reads the clipboard once, there, and then
    /// raises `isChoosingAttachmentSource`.
    let chooseAttachmentSource: () -> Void
    /// The chooser is presented *by this key*, because the system anchors an action sheet to the
    /// view its modifier decorates. Held on the owner's root view it pointed its tail at the
    /// middle of the terminal; held here it points at the paperclip that was tapped. Photos and
    /// Files still present from the owner's stable hierarchy once this has dismissed, so the key
    /// going away with the sheet cannot take a picker with it.
    @Binding var isChoosingAttachmentSource: Bool
    let attachmentSourceActions: [ThemedDialogAction]
    @EnvironmentObject private var keyboards: MobileTerminalKeyboardStore
    @Environment(\.remoteTheme) private var theme
    @State private var isKeyboardVisible = false
    @State private var keyFeedback = MobileButtonFeedback.shared
    @State private var modifierFeedback = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            actionRow

            Rectangle().fill(theme.divider).frame(height: theme.borderWidth)

            keyRow
        }
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
        }
        .onAppear {
            isKeyboardVisible = bridge.isKeyboardShowing
            keyFeedback.prepare()
            modifierFeedback.prepare()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )
        ) { _ in isKeyboardVisible = true }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )
        ) { _ in isKeyboardVisible = false }
    }

    private var canSend: Bool {
        connection.capability == .interact
            && connection.phase == .connected
            && connection.inputControl?.canWrite != false
    }

    private var layout: RemoteTerminalKeyboardLayout {
        keyboards.layout(forAgentKind: agentKind)
    }

    /// The bar's full-height utilities and the optional top key run. Fixed controls keep their
    /// slots while the person's keys scroll through whatever width remains between them. The
    /// outermost glyph at each end stands on the bar's margin by its ink, the line the bottom
    /// row's caps stand on by their plates; see `TerminalKeyBarMetrics.edgeInset(for:weight:edge:)`.
    private var actionRow: some View {
        let actionControls = TerminalKeyBarActionControls(
            customize: customize,
            showsInputModeControl: connection.supportsAtomicTerminalSubmission
                && effectiveInputMode != .none,
            inputPreference: inputPreference,
            effectiveInputMode: effectiveInputMode,
            canChooseInputPreference: canChooseInputPreference,
            toggleInputPreference: toggleInputPreference
        )
        return HStack(spacing: 0) {
            if showsAttachmentKey {
                attachmentButton
                    .padding(.leading, TerminalKeyBarMetrics.edgeInset(
                        for: TerminalKeyBarSymbols.attachments,
                        weight: .medium,
                        edge: .leading
                    ))
            }
            if layout.keys(in: .top).isEmpty {
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MobileDesign.Spacing.tight) {
                        ForEach(layout.keys(in: .top)) { key in
                            button(for: key)
                        }
                    }
                    .padding(.horizontal, TerminalKeyBarMetrics.keyPadding)
                    .frame(minHeight: TerminalKeyBarMetrics.actionHeight)
                }
                .disabled(!canSend)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionControls
                .padding(.trailing, TerminalKeyBarMetrics.edgeInset(
                    for: actionControls.trailingSymbol,
                    edge: .trailing
                ))
        }
    }

    /// The tight cap run closest to the keyboard, with the way back from the keyboard at its
    /// trailing edge — on the row nearest the thing it controls.
    private var keyRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileDesign.Spacing.tight) {
                    ForEach(layout.keys(in: .bottom)) { key in
                        button(for: key)
                    }
                }
                .padding(.horizontal, TerminalKeyBarMetrics.keyPadding)
                .padding(.vertical, MobileDesign.Spacing.tight)
            }
            .disabled(!canSend)

            keyboardToggle
        }
    }

    /// Both directions, because the terminal no longer answers a tap by taking the keyboard
    /// while a TUI is tracking the mouse: that tap is the TUI's click. The glyph stands on the
    /// bar's trailing margin by its ink, like the action row's last glyph above it.
    @ViewBuilder
    private var keyboardToggle: some View {
        if isKeyboardVisible || bridge.canShowKeyboard {
            Rectangle()
                .fill(theme.divider)
                .frame(width: theme.borderWidth, height: TerminalKeyBarMetrics.keyHeight)

            Button(action: isKeyboardVisible ? bridge.dismissKeyboard : bridge.showKeyboard) {
                Image(systemName: keyboardToggleSymbol)
                    .font(TerminalKeyBarMetrics.glyphFont)
                    .foregroundStyle(theme.secondaryLabel)
                    .frame(
                        width: MobileDesign.Size.minimumTapTarget,
                        height: TerminalKeyBarMetrics.keyHeight
                    )
                    .contentShape(Rectangle())
            }
            .padding(.trailing, TerminalKeyBarMetrics.edgeInset(
                for: keyboardToggleSymbol,
                edge: .trailing
            ))
            .accessibilityLabel(
                isKeyboardVisible
                    ? MobileL10n.string("Hide keyboard")
                    : MobileL10n.string("Show keyboard")
            )
        }
    }

    private var keyboardToggleSymbol: String {
        isKeyboardVisible
            ? TerminalKeyBarSymbols.hideKeyboard
            : TerminalKeyBarSymbols.showKeyboard
    }

    private var attachmentButton: some View {
        Button(action: chooseAttachmentSource) {
            Image(systemName: TerminalKeyBarSymbols.attachments)
                .font(TerminalKeyBarMetrics.glyphFont.weight(.medium))
                .foregroundStyle(theme.label)
                .frame(
                    width: MobileDesign.Size.minimumTapTarget,
                    height: TerminalKeyBarMetrics.actionHeight
                )
                .contentShape(Rectangle())
        }
        .disabled(!canAttach || !canSend)
        .accessibilityLabel(MobileL10n.string("Attachments"))
        .themedConfirmationDialog(
            "Attachments",
            isPresented: $isChoosingAttachmentSource,
            actions: attachmentSourceActions
        )
    }

    @ViewBuilder
    private func button(for key: RemoteTerminalKeyDefinition) -> some View {
        if case .latch(let modifier) = key.action {
            latchButton(for: key, modifier: modifier)
        } else {
            actionButton(for: key)
        }
    }

    private func actionButton(for key: RemoteTerminalKeyDefinition) -> some View {
        Button {
            press(key)
        } label: {
            keyCap(terminalKeyDisplayLabel(key))
        }
        .buttonStyle(TerminalKeyCapButtonStyle(
            theme: theme,
            restingFill: theme.controlResting
        ))
        .contextMenu {
            if case .snippet(let text, true) = key.action {
                Button {
                    connection.sendTerminalKey(text)
                } label: {
                    Label(
                        MobileL10n.string("Insert without submitting"),
                        systemImage: "text.insert"
                    )
                }
            }
            Button {
                customize()
            } label: {
                Label(
                    MobileL10n.string("Customize keys"),
                    systemImage: TerminalKeyBarSymbols.customizeKeys
                )
            }
        }
    }

    private func latchButton(
        for key: RemoteTerminalKeyDefinition,
        modifier: RemoteTerminalLatchingModifier
    ) -> some View {
        let phase = bridge.latch.phase(of: modifier)
        return Button {
            if bridge.activate(modifier) {
                modifierFeedback.selectionChanged()
                modifierFeedback.prepare()
            }
        } label: {
            keyCap(terminalKeyDisplayLabel(key))
                .foregroundStyle(latchInk(for: phase))
        }
        .buttonStyle(TerminalKeyCapButtonStyle(
            theme: theme,
            restingFill: latchFill(for: phase),
            pressChanged: { isPressed in
                if isPressed {
                    bridge.modifierTouchBegan(modifier)
                } else {
                    bridge.modifierTouchEnded(modifier)
                }
            },
            forcePressed: evidenceForcesPressedState(for: modifier)
        ))
        .accessibilityLabel(MobileL10n.string(
            modifier == .control ? "Control" : "Option"
        ))
        .accessibilityValue(accessibilityValue(for: phase))
    }

    private func press(_ key: RemoteTerminalKeyDefinition) {
        if let text = terminalKeySubmissionText(key.action) {
            // Text and Return must be separate PTY writes. In one write Claude Code and Codex
            // treat the whole chunk as pasted input and leave the line sitting in the composer.
            // The atomic route already owns that split, focused-input admission and retries.
            guard connection.submitTerminalLine(text) != nil else { return }
            keyFeedback.perform()
            bridge.consumeModifiersAfterKey()
            return
        }
        guard let bytes = bridge.encodedBytes(for: key.action) else { return }
        keyFeedback.perform()
        connection.sendTerminalKey(String(decoding: bytes, as: UTF8.self))
        bridge.consumeModifiersAfterKey()
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(.footnote, design: .monospaced).weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, TerminalKeyBarMetrics.keyPadding)
            .frame(minWidth: TerminalKeyBarMetrics.minimumKeyWidth)
            .frame(height: TerminalKeyBarMetrics.keyHeight)
    }

    private func latchInk(for phase: RemoteTerminalLatchState.Phase) -> SwiftUI.Color {
        switch phase {
        case .off: return theme.label
        case .armed: return theme.accent
        case .locked: return theme.ground
        }
    }

    private func latchFill(for phase: RemoteTerminalLatchState.Phase) -> SwiftUI.Color {
        switch phase {
        case .off: return theme.controlResting
        case .armed: return theme.accentMuted
        case .locked: return theme.accent
        }
    }

    private func evidenceForcesPressedState(
        for modifier: RemoteTerminalLatchingModifier
    ) -> Bool {
#if DEBUG
        modifier == .control
            && ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]
                == "terminal-keycap-pressed-custom-dark"
#else
        false
#endif
    }

    private func accessibilityValue(for phase: RemoteTerminalLatchState.Phase) -> String {
        switch phase {
        case .off: return MobileL10n.string("off")
        case .armed: return MobileL10n.string("armed for the next key")
        case .locked: return MobileL10n.string("locked")
        }
    }
}

private extension RemoteTerminalKeyModifiers {
    var kittyModifiers: KittyKeyboardModifiers {
        var result: KittyKeyboardModifiers = []
        if contains(.shift) { result.insert(.shift) }
        if contains(.alt) { result.insert(.alt) }
        if contains(.control) { result.insert(.ctrl) }
        return result
    }
}

private extension RemoteTerminalNamedKey {
    var kittyFunctionalKey: TerminalFunctionalKey {
        switch self {
        case .escape: return .escape
        case .tab: return .tab
        case .enter: return .enter
        case .backspace: return .backspace
        case .forwardDelete: return .delete
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .f1: return .f1
        case .f2: return .f2
        case .f3: return .f3
        case .f4: return .f4
        case .f5: return .f5
        case .f6: return .f6
        case .f7: return .f7
        case .f8: return .f8
        case .f9: return .f9
        case .f10: return .f10
        case .f11: return .f11
        case .f12: return .f12
        }
    }
}
