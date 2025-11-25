import Foundation
import AppKit

// MARK: - Terminal Defaults

enum TerminalDefaults {
    static let columns = 80
    static let rows = 24
    static let scrollbackLines = 10_000
    static let defaultShell = "/bin/bash"
    static let defaultFont = "SF Mono"
    static let defaultFontSize: CGFloat = 13
    static let terminalType = "xterm-256color"
}

// MARK: - Window Defaults

enum WindowDefaults {
    static let minWidth: CGFloat = 400
    static let minHeight: CGFloat = 300
    static let defaultWidth: CGFloat = 800
    static let defaultHeight: CGFloat = 600
    static let titleBarHeight: CGFloat = 22
}

// MARK: - Environment Keys

enum EnvironmentKeys {
    static let term = "TERM"
    static let lang = "LANG"
    static let path = "PATH"
    static let home = "HOME"
    static let shell = "SHELL"
    static let columns = "COLUMNS"
    static let lines = "LINES"
}

// MARK: - Menu Identifiers

enum MenuIdentifiers {
    static let mainMenu = "MainMenu"
    static let shellMenu = "Shell"
    static let editMenu = "Edit"
    static let viewMenu = "View"
    static let windowMenu = "Window"
    static let helpMenu = "Help"
}

// MARK: - Notification Names

extension Notification.Name {
    static let terminalSessionDidStart = Notification.Name("terminalSessionDidStart")
    static let terminalSessionDidEnd = Notification.Name("terminalSessionDidEnd")
    static let terminalTitleDidChange = Notification.Name("terminalTitleDidChange")
}
