import SkalmanRemoteKit
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalViewRepresentable: UIViewRepresentable {
    typealias UIViewType = RemoteTerminalView

    @ObservedObject var connection: RemoteSessionConnection
    let theme: RemoteTerminalThemeDTO?

    func makeCoordinator() -> Coordinator {
        Coordinator(connection: connection)
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
        Self.apply(theme, to: view)
        view.accessibilityLabel = "Remote terminal"

        connection.onTerminalOutput = { [weak view] data in
            view?.feed(byteArray: Array(data)[...])
        }
        connection.onTerminalGridChange = { [weak view] cols, rows in
            guard view?.usesLocalViewport == false else { return }
            view?.setAuthoritativeGrid(cols: cols, rows: rows)
        }
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: RemoteTerminalView, context: Context) {
        context.coordinator.connection = connection
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

    final class Coordinator: NSObject, TerminalViewDelegate {
        var connection: RemoteSessionConnection

        init(connection: RemoteSessionConnection) {
            self.connection = connection
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor [weak self] in
                self?.connection.sendTerminalInput(bytes[...])
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor [weak self] in
                self?.connection.updateTerminalViewport(cols: newCols, rows: newRows)
            }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }
        func bell(source: TerminalView) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// SwiftTerm normally derives its grid from this device's pixel size. Remote output was produced
/// for the Mac's PTY grid, though, so cursor addressing and wraps only remain correct when every
/// local layout pass reapplies that authoritative size.
final class RemoteTerminalView: TerminalView {
    private(set) var usesLocalViewport = false
    private var authoritativeColumns = 0
    private var authoritativeRows = 0
    private var isApplyingAuthoritativeGrid = false

    override var bounds: CGRect {
        get { super.bounds }
        set {
            super.bounds = newValue
            applyAuthoritativeGrid()
        }
    }

    override var frame: CGRect {
        get { super.frame }
        set {
            super.frame = newValue
            applyAuthoritativeGrid()
        }
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

    private func applyAuthoritativeGrid() {
        guard !isApplyingAuthoritativeGrid,
              authoritativeColumns > 0,
              authoritativeRows > 0 else {
            return
        }
        let current = getTerminal().getDims()
        guard current.cols != authoritativeColumns || current.rows != authoritativeRows else {
            return
        }
        isApplyingAuthoritativeGrid = true
        resize(cols: authoritativeColumns, rows: authoritativeRows)
        isApplyingAuthoritativeGrid = false
    }
}
