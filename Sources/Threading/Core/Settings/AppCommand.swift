import AppKit
import ThreadingExtensionKit

// MARK: - App Command

/// One thing the app can be told to do from the menu bar, named once.
///
/// The menu used to state every shortcut as a literal at the point the item was built, which
/// made the shortcuts unlistable and unchangeable: nothing could enumerate them, so the Settings
/// page had nothing to draw and the user had nothing to override. The table below is the single
/// place a chord is decided, and both the menu bar and the Keyboard page read from it.
struct AppCommand {

    /// Which section of the shortcuts page it belongs to. Deliberately not the menu it lives in
    /// — Find sits in the Edit menu but belongs beside the other things the app does.
    enum Group: String, CaseIterable {
        case session = "Session"
        case view = "View"
        case inspect = "Inspect"
        case extensions = "Extensions"
        case system = "System"
    }

    enum Origin: Equatable {
        case builtIn
        case extensionCommand(identifier: String, name: String, localID: String)

        var extensionIdentifier: String? {
            guard case .extensionCommand(let identifier, _, _) = self else { return nil }
            return identifier
        }

        var extensionName: String? {
            guard case .extensionCommand(_, let name, _) = self else { return nil }
            return name
        }

        var localCommandID: String? {
            guard case .extensionCommand(_, _, let localID) = self else { return nil }
            return localID
        }
    }

    /// Stable across releases and across renames: this is what an override is stored under, so
    /// changing it silently drops the user's binding.
    let id: String

    let group: Group
    let title: String
    let detail: String?
    let defaultShortcut: KeyboardShortcut?

    /// Whether the user may rebind it.
    ///
    /// The system commands are listed but fixed. Rebinding ⌘C or ⌘Q is not a preference anyone
    /// wants and breaking either is worse than any flexibility it buys — they appear so the page
    /// answers "what is this key doing", which is most of why a shortcuts list is opened.
    let isEditable: Bool

    let origin: Origin
    let scope: ExtensionCommandScope
    let risk: ExtensionCommandRisk
    let menuPlacements: [ExtensionMenuPlacement]

    init(
        id: String,
        group: Group,
        title: String,
        detail: String? = nil,
        defaultShortcut: KeyboardShortcut?,
        isEditable: Bool,
        origin: Origin = .builtIn,
        scope: ExtensionCommandScope = .application,
        risk: ExtensionCommandRisk = .ordinary,
        menuPlacements: [ExtensionMenuPlacement] = []
    ) {
        self.id = id
        self.group = group
        switch origin {
        case .builtIn:
            self.title = L10n.string(title)
            self.detail = detail.map { L10n.string($0) }
        case .extensionCommand:
            self.title = title
            self.detail = detail
        }
        self.defaultShortcut = defaultShortcut
        self.isEditable = isEditable
        self.origin = origin
        self.scope = scope
        self.risk = risk
        self.menuPlacements = menuPlacements
    }
}

// MARK: - The Table

enum AppCommands {

    // MARK: Identifiers

    /// Referenced where the menu is built, so a typo is a compile error rather than an item that
    /// silently never picks up its override.
    enum ID {
        static let newSession = "session.new"
        static let newProject = "project.new"
        static let addProject = "project.add"
        static let closeSession = "session.close"
        static let closeTab = "tab.close"
        static let find = "edit.find"
        static let openIn = "session.openIn"

        static let toggleSidebar = "view.sidebar"
        static let groupByBranch = "view.groupByBranch"
        static let loneBranchHeadings = "view.loneBranchHeadings"
        static let newTerminalTab = "view.terminal"
        static let browser = "view.browser"
        static let files = "view.files"
        static let review = "view.review"
        static let sessionInfo = "view.info"
        static let shell = "view.shell"
        static let displayPanel = "view.displayPanel"
        static let statusCard = "view.statusCard"
        static let currentTheme = "view.currentTheme"
        static let componentGallery = "view.componentGallery"
        static let biggerText = "view.biggerText"
        static let smallerText = "view.smallerText"

        static let previousTab = "tab.previous"
        static let nextTab = "tab.next"

        static let navigateBack = "nav.back"
        static let navigateForward = "nav.forward"

        /// `tab.select.1` … `tab.select.9` — one id per ⌘-digit, stable like every other.
        static func selectTab(_ number: Int) -> String { "tab.select.\(number)" }
        static let selectTabNumbers = 1...9

        /// Still `inspect.element` after the two commands merged, because an id is what a
        /// stored shortcut override keys on — renaming it would silently drop the binding of
        /// anyone who had rebound the one command that survived.
        static let inspectElement = "inspect.element"
    }

    // MARK: Editable

    /// Threading's own commands, in the order the page lists them.
    static let editable: [AppCommand] = [
        AppCommand(id: ID.newSession, group: .session, title: "New Session",
                   defaultShortcut: KeyboardShortcut(key: "n", modifiers: .command), isEditable: true),
        AppCommand(id: ID.newProject, group: .session, title: "New Project…",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.addProject, group: .session, title: "Add Existing Project…",
                   defaultShortcut: KeyboardShortcut(key: "n", modifiers: [.command, .shift]), isEditable: true),
        // ⌘W closes the *tab*, as every tabbed app spells it; stopping the agent is a bigger
        // decision than a reflex chord, so Close Session keeps its menu item and lost only
        // the default binding — stored overrides survive, they key on the id.
        AppCommand(id: ID.closeTab, group: .session, title: "Close Tab",
                   defaultShortcut: KeyboardShortcut(key: "w", modifiers: .command), isEditable: true),
        AppCommand(id: ID.closeSession, group: .session, title: "Close Session",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.find, group: .session, title: "Find…",
                   defaultShortcut: KeyboardShortcut(key: "f", modifiers: .command), isEditable: true),
        // ⌘O is the platform's Open, and this is the only opening this app does: it has no
        // documents of its own, and a checkout is what "open" means here. The app it opens in
        // is the one used last, which is why the title cannot name one.
        AppCommand(id: ID.openIn, group: .session, title: "Open in External App",
                   detail: "Opens the checkout in the editor, terminal or Finder you last chose.",
                   defaultShortcut: KeyboardShortcut(key: "o", modifiers: .command), isEditable: true),

        AppCommand(id: ID.toggleSidebar, group: .view, title: "Toggle Sidebar",
                   defaultShortcut: KeyboardShortcut(key: "s", modifiers: [.command, .control]), isEditable: true),
        // Xcode's Go Back chords, for Xcode's gesture: retrace the window's page selection.
        // The ⌃⌘ layer is already this app's window-structure layer (⌃⌘S, ⌃⌘B, ⌃⌘F) — and the
        // bare ⌃-arrow belongs to Spaces, while ⌃←/→ *in the terminal* stays xterm word motion.
        AppCommand(id: ID.navigateBack, group: .view, title: "Go Back",
                   defaultShortcut: KeyboardShortcut(key: "\u{F702}", modifiers: [.command, .control]), isEditable: true),
        AppCommand(id: ID.navigateForward, group: .view, title: "Go Forward",
                   defaultShortcut: KeyboardShortcut(key: "\u{F703}", modifiers: [.command, .control]), isEditable: true),
        // B for branch, on the sidebar-toggle's own ⌃⌘ layer — ⇧⌘B is the browser's. The
        // lone-branch refinement takes the ⌥⌘ layer of the same key, so the pair reads as
        // one idea at two depths.
        AppCommand(id: ID.groupByBranch, group: .view, title: "Group Sessions by Branch",
                   defaultShortcut: KeyboardShortcut(key: "b", modifiers: [.command, .control]), isEditable: true),
        AppCommand(id: ID.loneBranchHeadings, group: .view, title: "Headings for Lone Branches",
                   defaultShortcut: KeyboardShortcut(key: "b", modifiers: [.command, .option]), isEditable: true),
        // ⌘T for the terminal, which is what T means everywhere else. The browser keeps ⇧⌘B
        // rather than taking ⌘T from it.
        AppCommand(id: ID.newTerminalTab, group: .view, title: "Terminal",
                   defaultShortcut: KeyboardShortcut(key: "t", modifiers: .command), isEditable: true),
        AppCommand(id: ID.browser, group: .view, title: "Browser",
                   defaultShortcut: KeyboardShortcut(key: "b", modifiers: [.command, .shift]), isEditable: true),
        AppCommand(id: ID.files, group: .view, title: "Files",
                   defaultShortcut: KeyboardShortcut(key: "p", modifiers: .command), isEditable: true),
        AppCommand(id: ID.review, group: .view, title: "Git Review",
                   defaultShortcut: KeyboardShortcut(key: "r", modifiers: [.command, .shift]), isEditable: true),
        AppCommand(id: ID.sessionInfo, group: .view, title: "Session Info",
                   defaultShortcut: KeyboardShortcut(key: "i", modifiers: [.command, .shift]), isEditable: true),
        AppCommand(id: ID.shell, group: .view, title: "Shell",
                   defaultShortcut: KeyboardShortcut(key: "`", modifiers: .control), isEditable: true),
        AppCommand(id: ID.displayPanel, group: .view, title: "Display Panel",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.statusCard, group: .view, title: "Status Card",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.currentTheme, group: .view, title: "Current Theme",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.componentGallery, group: .view, title: "Component Gallery",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.biggerText, group: .view, title: "Bigger",
                   defaultShortcut: KeyboardShortcut(key: "+", modifiers: .command), isEditable: true),
        AppCommand(id: ID.smallerText, group: .view, title: "Smaller",
                   defaultShortcut: KeyboardShortcut(key: "-", modifiers: .command), isEditable: true),
        // ⇧⌘[ and ⇧⌘] are what every tabbed mac app answers to; ⌃Tab is deliberately not the
        // default — an NSMenu key equivalent on ⌃Tab is swallowed often enough to feel broken.
        AppCommand(id: ID.previousTab, group: .view, title: "Previous Tab",
                   defaultShortcut: KeyboardShortcut(key: "[", modifiers: [.command, .shift]), isEditable: true),
        AppCommand(id: ID.nextTab, group: .view, title: "Next Tab",
                   defaultShortcut: KeyboardShortcut(key: "]", modifiers: [.command, .shift]), isEditable: true),

        // One command, not two. Element and freeflow are read from the modifiers held while
        // pointing, so the old ⌥⇧⌘I still opens freeflow — it arrives with ⇧ already down.
        AppCommand(id: ID.inspectElement, group: .inspect, title: "Inspect…",
                   defaultShortcut: KeyboardShortcut(key: "i", modifiers: [.command, .option]), isEditable: true)
    ]

    // MARK: Fixed

    /// Listed so the page can answer "what owns this chord", never rebindable. These are the
    /// platform's, and the app only borrows them.
    static let fixed: [AppCommand] = [
        AppCommand(id: "system.preferences", group: .system, title: "Preferences…",
                   defaultShortcut: KeyboardShortcut(key: ",", modifiers: .command), isEditable: false),
        AppCommand(id: "system.hide", group: .system, title: "Hide Threading",
                   defaultShortcut: KeyboardShortcut(key: "h", modifiers: .command), isEditable: false),
        AppCommand(id: "system.quit", group: .system, title: "Quit Threading",
                   defaultShortcut: KeyboardShortcut(key: "q", modifiers: .command), isEditable: false),
        AppCommand(id: "system.undo", group: .system, title: "Undo",
                   defaultShortcut: KeyboardShortcut(key: "z", modifiers: .command), isEditable: false),
        AppCommand(id: "system.cut", group: .system, title: "Cut",
                   defaultShortcut: KeyboardShortcut(key: "x", modifiers: .command), isEditable: false),
        AppCommand(id: "system.copy", group: .system, title: "Copy",
                   defaultShortcut: KeyboardShortcut(key: "c", modifiers: .command), isEditable: false),
        AppCommand(id: "system.paste", group: .system, title: "Paste",
                   defaultShortcut: KeyboardShortcut(key: "v", modifiers: .command), isEditable: false),
        AppCommand(id: "system.selectAll", group: .system, title: "Select All",
                   defaultShortcut: KeyboardShortcut(key: "a", modifiers: .command), isEditable: false),
        AppCommand(id: "system.fullScreen", group: .system, title: "Enter Full Screen",
                   defaultShortcut: KeyboardShortcut(key: "f", modifiers: [.command, .control]), isEditable: false),
        AppCommand(id: "system.minimize", group: .system, title: "Minimize",
                   defaultShortcut: KeyboardShortcut(key: "m", modifiers: .command), isEditable: false)
    ]
    // ⌘1–⌘9 select a tab by its place in the strip. Listed so the page can answer "what owns
    // ⌘3", fixed because nine recorder rows would drown the list for a binding nobody re-maps.
    + ID.selectTabNumbers.map { number in
        AppCommand(id: ID.selectTab(number), group: .view, title: "Tab \(number)",
                   defaultShortcut: KeyboardShortcut(key: "\(number)", modifiers: .command),
                   isEditable: false)
    }

    static let all: [AppCommand] = editable + fixed

    static func command(id: String) -> AppCommand? {
        all.first { $0.id == id }
    }

    /// The page's sections, in order, skipping any that ended up empty.
    static func grouped() -> [(group: AppCommand.Group, commands: [AppCommand])] {
        AppCommand.Group.allCases.compactMap { group in
            let commands = all.filter { $0.group == group }
            return commands.isEmpty ? nil : (group, commands)
        }
    }
}
