import SwiftUI
import ThreadingRemoteKit
import UIKit

/// The latch state shared between the key bar, which shows and toggles it, and the terminal
/// coordinator, which spends it on the next typed keystroke. It also carries the live
/// terminal view so key encoding can honour DECCKM — an unmodified arrow is SS3 while the
/// full-screen TUI has application cursor mode on, which the fixed bar always got wrong.
@MainActor
final class TerminalKeyBridge: ObservableObject {
    @Published private(set) var latch = RemoteTerminalLatchState()
    weak var terminalView: RemoteTerminalView?

    var applicationCursorActive: Bool {
        terminalView?.getTerminal().applicationCursor ?? false
    }

    func tap(_ modifier: RemoteTerminalLatchingModifier) {
        var next = latch
        next.tap(modifier)
        latch = next
    }

    func consumeArmed() {
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
        let held = latch.heldModifiers
        guard !held.isEmpty, bytes.count == 1 else { return bytes }
        let transformed = RemoteTerminalKeyEncoder.applyLatched(held, toTyped: bytes)
        consumeArmed()
        return transformed
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

/// The customizable key run under the remote terminal: layout comes from
/// `MobileTerminalKeyboardStore` (stock per agent kind until edited), latch keys arm or lock
/// the next press, and the trailing control opens the editor.
struct TerminalKeyBar: View {
    @ObservedObject var connection: RemoteSessionConnection
    @ObservedObject var bridge: TerminalKeyBridge
    let agentKind: String
    let customize: () -> Void
    @EnvironmentObject private var keyboards: MobileTerminalKeyboardStore
    @Environment(\.remoteTheme) private var theme

    private enum Metrics {
        static let keyHeight: CGFloat = 34
        static let keyPadding: CGFloat = 12
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(keyboards.layout(forAgentKind: agentKind).keys) { key in
                        button(for: key)
                    }
                }
                .padding(.horizontal, Metrics.keyPadding)
                .padding(.vertical, MobileDesign.Spacing.small)
            }
            .disabled(!canSend)

            Rectangle()
                .fill(theme.divider)
                .frame(width: theme.borderWidth, height: Metrics.keyHeight)

            Button(action: customize) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryLabel)
                    .frame(
                        width: MobileDesign.Size.minimumTapTarget,
                        height: Metrics.keyHeight
                    )
            }
            .accessibilityLabel(MobileL10n.string("Customize keys"))
        }
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
        }
    }

    private var canSend: Bool {
        connection.capability == .interact
            && connection.phase == .connected
            && connection.inputControl?.canWrite != false
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
        .background(
            theme.controlResting,
            in: RoundedRectangle(cornerRadius: theme.controlRadius)
        )
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
                    systemImage: "keyboard.badge.ellipsis"
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
            UISelectionFeedbackGenerator().selectionChanged()
            bridge.tap(modifier)
        } label: {
            keyCap(terminalKeyDisplayLabel(key))
                .foregroundStyle(latchInk(for: phase))
        }
        .background(
            latchFill(for: phase),
            in: RoundedRectangle(cornerRadius: theme.controlRadius)
        )
        .accessibilityLabel(MobileL10n.string(
            modifier == .control ? "Control" : "Option"
        ))
        .accessibilityValue(accessibilityValue(for: phase))
    }

    private func press(_ key: RemoteTerminalKeyDefinition) {
        guard let bytes = RemoteTerminalKeyEncoder.bytes(
            for: key.action,
            latched: bridge.latch.heldModifiers,
            applicationCursor: bridge.applicationCursorActive
        ) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        connection.sendTerminalKey(String(decoding: bytes, as: UTF8.self))
        bridge.consumeArmed()
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(.subheadline, design: .monospaced).weight(.medium))
            .padding(.horizontal, Metrics.keyPadding)
            .frame(height: Metrics.keyHeight)
    }

    private func latchInk(for phase: RemoteTerminalLatchState.Phase) -> Color {
        switch phase {
        case .off: return theme.label
        case .armed: return theme.accent
        case .locked: return theme.ground
        }
    }

    private func latchFill(for phase: RemoteTerminalLatchState.Phase) -> Color {
        switch phase {
        case .off: return theme.controlResting
        case .armed: return theme.accentMuted
        case .locked: return theme.accent
        }
    }

    private func accessibilityValue(for phase: RemoteTerminalLatchState.Phase) -> String {
        switch phase {
        case .off: return MobileL10n.string("off")
        case .armed: return MobileL10n.string("armed for the next key")
        case .locked: return MobileL10n.string("locked")
        }
    }
}
