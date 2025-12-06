import AppKit

/// Window controller for the Preferences window with tabbed interface.
final class PreferencesWindowController: NSWindowController {

    // MARK: - Constants

    private enum TabIdentifiers {
        static let general = "general"
        static let profiles = "profiles"
        static let themes = "themes"
        static let ai = "ai"
    }

    private enum WindowSize {
        static let width: CGFloat = 650
        static let height: CGFloat = 500
    }

    // MARK: - Properties

    private var tabViewController: NSTabViewController!

    // MARK: - Singleton

    private static var shared: PreferencesWindowController?

    static func show() {
        if shared == nil {
            shared = PreferencesWindowController()
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Initialization

    private convenience init() {
        let window = Self.createWindow()
        self.init(window: window)
        setupTabViewController()
    }

    // MARK: - Window Creation

    private static func createWindow() -> NSWindow {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: WindowSize.width,
            height: WindowSize.height
        )

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable
        ]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "Preferences"
        window.center()
        window.isReleasedWhenClosed = false

        return window
    }

    // MARK: - Setup

    private func setupTabViewController() {
        tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar

        // General Tab
        let generalVC = GeneralPreferencesViewController()
        let generalTab = NSTabViewItem(viewController: generalVC)
        generalTab.label = "General"
        generalTab.identifier = TabIdentifiers.general
        generalTab.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")

        // Profiles Tab
        let profilesVC = ProfilePreferencesViewController()
        let profilesTab = NSTabViewItem(viewController: profilesVC)
        profilesTab.label = "Profiles"
        profilesTab.identifier = TabIdentifiers.profiles
        profilesTab.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Profiles")

        // Themes Tab
        let themesVC = ThemePreferencesViewController()
        let themesTab = NSTabViewItem(viewController: themesVC)
        themesTab.label = "Themes"
        themesTab.identifier = TabIdentifiers.themes
        themesTab.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Themes")

        // AI Tab
        let aiVC = AIPreferencesViewController()
        let aiTab = NSTabViewItem(viewController: aiVC)
        aiTab.label = "AI"
        aiTab.identifier = TabIdentifiers.ai
        aiTab.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "AI")

        tabViewController.addTabViewItem(generalTab)
        tabViewController.addTabViewItem(profilesTab)
        tabViewController.addTabViewItem(themesTab)
        tabViewController.addTabViewItem(aiTab)

        window?.contentViewController = tabViewController
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        PreferencesWindowController.shared = nil
    }
}
