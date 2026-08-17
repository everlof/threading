import ThreadingRemoteKit
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalViewRepresentable: UIViewRepresentable {
    typealias UIViewType = RemoteTerminalView

    @ObservedObject var connection: RemoteSessionConnection
    let theme: RemoteTerminalThemeDTO?
    let allowsDirectInput: Bool
    let keyBridge: TerminalKeyBridge
    let initialScrollProgress: Double?
    let onScrollProgress: @MainActor (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            connection: connection,
            allowsInput: allowsDirectInput,
            keyBridge: keyBridge,
            initialScrollProgress: initialScrollProgress,
            onScrollProgress: onScrollProgress
        )
    }

    func makeUIView(context: Context) -> RemoteTerminalView {
        let view = RemoteTerminalView(
            frame: UIScreen.main.bounds,
            font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = context.coordinator
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.setAllowsKeyboardInput(allowsDirectInput)
        context.coordinator.attach(to: view)
        Self.apply(theme, to: view)
        view.accessibilityLabel = MobileL10n.string("Remote terminal")

        let coordinator = context.coordinator
        connection.onTerminalOutput = { [weak view] data in
            view?.feed(byteArray: Array(data)[...])
            coordinator.restoreViewportIfPossible()
        }
        connection.onTerminalGridChange = { [weak view] cols, rows in
            guard view?.usesLocalViewport == false else { return }
            view?.setAuthoritativeGrid(cols: cols, rows: rows)
        }
        if allowsDirectInput {
#if DEBUG
            if ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_STATE"
            ] == nil {
                DispatchQueue.main.async {
                    _ = view.becomeFirstResponder()
                }
            }
#else
            DispatchQueue.main.async {
                _ = view.becomeFirstResponder()
            }
#endif
        }
        return view
    }

    func updateUIView(_ uiView: RemoteTerminalView, context: Context) {
        context.coordinator.connection = connection
        context.coordinator.allowsInput = allowsDirectInput
        context.coordinator.initialScrollProgress = initialScrollProgress
        context.coordinator.onScrollProgress = onScrollProgress
        uiView.setAllowsKeyboardInput(allowsDirectInput)
        let ownsViewport = connection.capability == .interact
        uiView.setUsesLocalViewport(ownsViewport)
        if !ownsViewport {
            uiView.setAuthoritativeGrid(
                cols: connection.terminalColumns,
                rows: connection.terminalRows
            )
        }
        Self.apply(theme, to: uiView)
    }

    static func dismantleUIView(_ uiView: RemoteTerminalView, coordinator: Coordinator) {
        coordinator.captureViewport()
        coordinator.detach()
        coordinator.connection.onTerminalOutput = nil
        coordinator.connection.onTerminalGridChange = nil
        coordinator.connection.releaseTerminalViewport()
    }

    private static func apply(_ theme: RemoteTerminalThemeDTO?, to view: TerminalView) {
        guard let theme,
              let foreground = UIColor(remoteHex: theme.foreground),
              let background = UIColor(remoteHex: theme.background) else {
            let fallback = UIColor(red: 0.035, green: 0.039, blue: 0.047, alpha: 1)
            view.nativeForegroundColor = .white
            view.nativeBoldForegroundColor = nil
            view.nativeBackgroundColor = fallback
            view.backgroundColor = fallback
            view.keyboardAppearance = .dark
            return
        }

        let ansi = theme.ansi.compactMap { value -> SwiftTerm.Color? in
            guard let color = UIColor(remoteHex: value) else { return nil }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return nil
            }
            return SwiftTerm.Color(
                red: UInt16(red * 65_535),
                green: UInt16(green * 65_535),
                blue: UInt16(blue * 65_535)
            )
        }
        if ansi.count == 16 { view.installColors(ansi) }

        view.nativeForegroundColor = foreground
        // Absent or unreadable means "the same as the foreground", which is how a host from
        // before the role existed describes itself.
        view.nativeBoldForegroundColor = theme.boldForeground.flatMap(UIColor.init(remoteHex:))
        view.nativeBackgroundColor = background
        view.backgroundColor = background
        if let selection = UIColor(remoteHex: theme.selection) {
            view.selectedTextBackgroundColor = selection
        }
        if let cursor = UIColor(remoteHex: theme.cursor) {
            view.caretColor = cursor
        }

        var white: CGFloat = 0
        let isDark = background.getWhite(&white, alpha: nil) ? white < 0.5 : true
        view.keyboardAppearance = isDark ? .dark : .light
        view.setNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var connection: RemoteSessionConnection
        var allowsInput: Bool
        let keyBridge: TerminalKeyBridge
        var initialScrollProgress: Double?
        var onScrollProgress: @MainActor (Double) -> Void
        private weak var terminalView: RemoteTerminalView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var hasRestoredViewport = false

        init(
            connection: RemoteSessionConnection,
            allowsInput: Bool,
            keyBridge: TerminalKeyBridge,
            initialScrollProgress: Double?,
            onScrollProgress: @escaping @MainActor (Double) -> Void
        ) {
            self.connection = connection
            self.allowsInput = allowsInput
            self.keyBridge = keyBridge
            self.initialScrollProgress = initialScrollProgress
            self.onScrollProgress = onScrollProgress
        }

        @MainActor
        func attach(to view: RemoteTerminalView) {
            terminalView = view
            keyBridge.terminalView = view
            contentOffsetObservation = view.observe(\.contentOffset, options: [.new]) {
                [weak self, weak view] _, _ in
                Task { @MainActor in
                    guard let self, let view,
                          view.isDragging || view.isDecelerating || view.isTracking else { return }
                    self.captureViewport()
                }
            }
        }

        @MainActor
        func detach() {
            contentOffsetObservation?.invalidate()
            contentOffsetObservation = nil
            if keyBridge.terminalView === terminalView {
                keyBridge.terminalView = nil
            }
            terminalView = nil
        }

        func restoreViewportIfPossible() {
            guard !hasRestoredViewport, let view = terminalView,
                  let progress = initialScrollProgress else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.hasRestoredViewport else { return }
                let maximum = max(0, view.contentSize.height - view.bounds.height)
                guard maximum > 0 else { return }
                view.setContentOffset(
                    CGPoint(x: view.contentOffset.x, y: maximum * min(max(progress, 0), 1)),
                    animated: false
                )
                self.hasRestoredViewport = true
            }
        }

        func captureViewport() {
            guard let view = terminalView else { return }
            let maximum = max(0, view.contentSize.height - view.bounds.height)
            let progress = maximum > 0
                ? Double(min(max(view.contentOffset.y / maximum, 0), 1))
                : 1
            onScrollProgress(progress)
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor [weak self] in
                guard let self, self.allowsInput else { return }
                let typed = self.keyBridge.applyLatchesToTyped(bytes)
                self.connection.sendTerminalInput(typed[...])
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [weak self] in
                self?.connection.updateTerminalViewport(cols: newCols, rows: newRows)
            }
        }
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(
            source: TerminalView,
            link: String,
            params: [String: String]
        ) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        nonisolated func bell(source: TerminalView) {
            Task { @MainActor in
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            let string = String(data: content, encoding: .utf8)
            Task { @MainActor in UIPasteboard.general.string = string }
        }
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// SwiftTerm normally derives its grid from this device's pixel size. Remote output was produced
/// for the Mac's PTY grid, though, so cursor addressing and wraps only remain correct when this
/// view holds that authoritative size against its own layout.
final class RemoteTerminalView: TerminalView {
    private(set) var usesLocalViewport = false
    private var allowsKeyboardInput = true
    private var authoritativeColumns = 0
    private var authoritativeRows = 0

    override var canBecomeFirstResponder: Bool {
        allowsKeyboardInput && super.canBecomeFirstResponder
    }

    func setAllowsKeyboardInput(_ allowed: Bool) {
        guard allowsKeyboardInput != allowed else { return }
        allowsKeyboardInput = allowed
        if !allowed, isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    /// Answers before the emulator is touched, so a layout pass cannot reflow the Mac's grid to
    /// this phone's pixel size and back. The round trip also soft-reset the buffer, which threw
    /// away the scrolling region of whatever full-screen program the Mac is showing.
    override func shouldApplyFrameSizeChange(newCols: Int, newRows: Int) -> Bool {
        usesLocalViewport || authoritativeColumns <= 0 || authoritativeRows <= 0
    }

    func setAuthoritativeGrid(cols: Int, rows: Int) {
        guard !usesLocalViewport else { return }
        guard cols > 0, rows > 0 else { return }
        authoritativeColumns = cols
        authoritativeRows = rows
        applyAuthoritativeGrid()
    }

    func setUsesLocalViewport(_ usesLocalViewport: Bool) {
        guard self.usesLocalViewport != usesLocalViewport else { return }
        self.usesLocalViewport = usesLocalViewport
        if usesLocalViewport {
            authoritativeColumns = 0
            authoritativeRows = 0
            // Recomputes the grid from the phone's existing pixel frame and notifies the
            // coordinator even when the frame itself did not change during authentication.
            font = font
        } else {
            applyAuthoritativeGrid()
        }
    }

    /// A repeat of the grid already in force is not a resize: `resize` soft-resets the emulator,
    /// which would discard the scrolling region the Mac's output relies on.
    private func applyAuthoritativeGrid() {
        guard authoritativeColumns > 0, authoritativeRows > 0 else { return }
        let current = getTerminal().getDims()
        guard current.cols != authoritativeColumns || current.rows != authoritativeRows else {
            return
        }
        resize(cols: authoritativeColumns, rows: authoritativeRows)
    }
}
