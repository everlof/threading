import AppKit

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
        case system = "System"
    }

    /// Stable across releases and across renames: this is what an override is stored under, so
    /// changing it silently drops the user's binding.
    let id: String

    let group: Group
    let title: String
    let defaultShortcut: KeyboardShortcut?

    /// Whether the user may rebind it.
    ///
    /// The system commands are listed but fixed. Rebinding ⌘C or ⌘Q is not a preference anyone
    /// wants and breaking either is worse than any flexibility it buys — they appear so the page
    /// answers "what is this key doing", which is most of why a shortcuts list is opened.
    let isEditable: Bool
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
        static let find = "edit.find"

        static let toggleSidebar = "view.sidebar"
        static let newTerminalTab = "view.terminal"
        static let browser = "view.browser"
        static let files = "view.files"
        static let review = "view.review"
        static let sessionInfo = "view.info"
        static let shell = "view.shell"
        static let displayPanel = "view.displayPanel"
        static let componentGallery = "view.componentGallery"
        static let biggerText = "view.biggerText"
        static let smallerText = "view.smallerText"

        static let inspectElement = "inspect.element"
        static let inspectGeometry = "inspect.geometry"
    }

    // MARK: Editable

    /// Skalman's own commands, in the order the page lists them.
    static let editable: [AppCommand] = [
        AppCommand(id: ID.newSession, group: .session, title: "New Session",
                   defaultShortcut: KeyboardShortcut(key: "n", modifiers: .command), isEditable: true),
        AppCommand(id: ID.newProject, group: .session, title: "New Project…",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.addProject, group: .session, title: "Add Existing Project…",
                   defaultShortcut: KeyboardShortcut(key: "n", modifiers: [.command, .shift]), isEditable: true),
        AppCommand(id: ID.closeSession, group: .session, title: "Close Session",
                   defaultShortcut: KeyboardShortcut(key: "w", modifiers: .command), isEditable: true),
        AppCommand(id: ID.find, group: .session, title: "Find…",
                   defaultShortcut: KeyboardShortcut(key: "f", modifiers: .command), isEditable: true),

        AppCommand(id: ID.toggleSidebar, group: .view, title: "Toggle Sidebar",
                   defaultShortcut: KeyboardShortcut(key: "s", modifiers: [.command, .control]), isEditable: true),
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
        AppCommand(id: ID.componentGallery, group: .view, title: "Component Gallery",
                   defaultShortcut: nil, isEditable: true),
        AppCommand(id: ID.biggerText, group: .view, title: "Bigger",
                   defaultShortcut: KeyboardShortcut(key: "+", modifiers: .command), isEditable: true),
        AppCommand(id: ID.smallerText, group: .view, title: "Smaller",
                   defaultShortcut: KeyboardShortcut(key: "-", modifiers: .command), isEditable: true),

        AppCommand(id: ID.inspectElement, group: .inspect, title: "Inspect Element",
                   defaultShortcut: KeyboardShortcut(key: "i", modifiers: [.command, .option]), isEditable: true),
        AppCommand(id: ID.inspectGeometry, group: .inspect, title: "Inspect Geometry",
                   defaultShortcut: KeyboardShortcut(key: "i", modifiers: [.command, .option, .shift]), isEditable: true)
    ]

    // MARK: Fixed

    /// Listed so the page can answer "what owns this chord", never rebindable. These are the
    /// platform's, and the app only borrows them.
    static let fixed: [AppCommand] = [
        AppCommand(id: "system.preferences", group: .system, title: "Preferences…",
                   defaultShortcut: KeyboardShortcut(key: ",", modifiers: .command), isEditable: false),
        AppCommand(id: "system.hide", group: .system, title: "Hide Skalman",
                   defaultShortcut: KeyboardShortcut(key: "h", modifiers: .command), isEditable: false),
        AppCommand(id: "system.quit", group: .system, title: "Quit Skalman",
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
