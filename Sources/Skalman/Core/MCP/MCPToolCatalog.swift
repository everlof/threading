import Foundation

// MARK: - Tool Metadata

/// One tool, as shown to the user on the Tools settings page. The behavioural schema an agent
/// consumes lives in `MCPTools.definitions`; this is the human-facing half.
struct MCPToolInfo {
    let name: String
    let title: String
    let detail: String
    let symbol: String
}

/// A coherent set of tools that are enabled or disabled together.
///
/// Grouping is the unit of control on purpose: several tools only make sense as a set — clicking a
/// page you never navigated to, or activating a tab you never listed — so the switch is per group,
/// not per tool.
struct MCPToolGroup {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    let tools: [MCPToolInfo]

    /// The agent-facing guidance sent in the `initialize` response — included only while the group
    /// is enabled, so a disabled capability is never described to a model that cannot use it.
    let instruction: String
}

// MARK: - Tool Catalogue

/// The single source of truth for the tools Skalman exposes over MCP: what they are, how they
/// group, and — read live from `AppSettings` — which groups are currently on.
///
/// Everything the server advertises (`tools/list`), the launch line enables, and the model is
/// told (`initialize` instructions) derives from here, so turning a group off on the Tools page
/// removes it from all three at once.
enum MCPToolCatalog {

    // MARK: Groups

    static let groups: [MCPToolGroup] = [display, browser, tabs, project, storage, appearance]

    static let display = MCPToolGroup(
        id: "display",
        title: "Display panel",
        summary: "Let agents show images and rendered HTML in the side panel.",
        symbol: "photo.on.rectangle",
        tools: [
            MCPToolInfo(
                name: MCPTools.displayImage,
                title: "Show image",
                detail: "Render an image file in the panel — a screenshot, chart, or diagram.",
                symbol: "photo"
            ),
            MCPToolInfo(
                name: MCPTools.displayHTML,
                title: "Show HTML",
                detail: "Render an HTML document — tables, charts, diagrams, rich reports.",
                symbol: "doc.richtext"
            )
        ],
        instruction: """
            Use display_image whenever an image is the point: a screenshot you just captured, a \
            chart or diagram you generated, a design asset you were asked to inspect, or a visual \
            diff. Prefer showing the image over describing it or printing its path — the user is \
            looking at the same window and the panel is right there.

            Use display_html when structure is the point and ASCII would mangle it: tables with \
            more than a few columns, charts, Mermaid or graphviz diagrams, side-by-side diffs, \
            rendered reports. It is a real browser engine, so scripts run and CDN libraries load.

            Neither replaces talking to the user. Show the artefact, then say what it means — the \
            panel carries the picture, your reply carries the point.
            """
    )

    static let browser = MCPToolGroup(
        id: "browser",
        title: "Browser",
        summary: "Let agents open, read, and act on live web pages in a browser tab.",
        symbol: "globe",
        tools: [
            MCPToolInfo(
                name: MCPTools.browserNavigate,
                title: "Open a page",
                detail: "Open a URL, or run a search when the text is not a URL.",
                symbol: "arrow.up.forward.app"
            ),
            MCPToolInfo(
                name: MCPTools.browserQuery,
                title: "Query the DOM",
                detail: "Find elements by CSS selector — text, attributes, and position.",
                symbol: "magnifyingglass"
            ),
            MCPToolInfo(
                name: MCPTools.browserClick,
                title: "Click an element",
                detail: "Click the first element matching a CSS selector.",
                symbol: "cursorarrow.rays"
            ),
            MCPToolInfo(
                name: MCPTools.browserScreenshot,
                title: "Screenshot the page",
                detail: "Capture the current page as a new image tab.",
                symbol: "camera"
            )
        ],
        instruction: """
            Skalman also hosts a real browser you can drive, shown as a tab in the display panel \
            beside the terminal. browser_navigate opens a page (or runs a search); browser_query \
            returns the elements matching a CSS selector — their text, attributes and on-screen \
            position — so you can read a page's structure directly rather than scraping HTML; \
            browser_click clicks the first match; and browser_screenshot captures the page as an \
            image tab. Use these to look things up, check a running app, or find and act on a \
            specific element, rather than guessing at a page you cannot see.
            """
    )

    static let tabs = MCPToolGroup(
        id: "tabs",
        title: "Panel tabs",
        summary: "Let agents list the panel's tabs and switch between them.",
        symbol: "rectangle.stack",
        tools: [
            MCPToolInfo(
                name: MCPTools.panelListTabs,
                title: "List tabs",
                detail: "See what is open in the panel and which tab is active.",
                symbol: "list.bullet.rectangle"
            ),
            MCPToolInfo(
                name: MCPTools.panelActivateTab,
                title: "Activate tab",
                detail: "Bring one of the panel's tabs to the front.",
                symbol: "rectangle.stack.badge.play"
            )
        ],
        instruction: """
            The display panel holds a set of tabs that coexist — each image and document opens its \
            own, and the browser is a tab too. panel_list_tabs shows what is open and which tab is \
            active; panel_activate_tab brings one to the front.
            """
    )

    static let project = MCPToolGroup(
        id: "project",
        title: "Project icon",
        summary: "Let agents set the project's sidebar icon.",
        symbol: "app.badge",
        tools: [
            MCPToolInfo(
                name: MCPTools.setProjectIcon,
                title: "Set project icon",
                detail: "Give the sidebar project an icon, from a file or an image URL.",
                symbol: "photo.badge.plus"
            )
        ],
        instruction: """
            set_project_icon sets the sidebar icon of the project this session runs in. Use \
            it when the user asks for a project icon, or offer it when you come across the \
            project's own mark — its favicon, logo, or owner avatar. Do not replace an icon \
            the user chose without being asked.
            """
    )

    static let storage = MCPToolGroup(
        id: "storage",
        title: "Disk space",
        summary: "Let agents see reclaimable build output and propose removing some of it.",
        symbol: "internaldrive",
        tools: [
            MCPToolInfo(
                name: MCPTools.listReclaimableStorage,
                title: "List reclaimable storage",
                detail: "Read what build output can be deleted and rebuilt, and how big it is.",
                symbol: "list.bullet.rectangle"
            ),
            MCPToolInfo(
                name: MCPTools.proposeStorageCleanup,
                title: "Propose a cleanup",
                detail: "Ask you to approve removing some of it. Never removes anything itself.",
                symbol: "hand.raised"
            )
        ],
        instruction: """
            list_reclaimable_storage reports build output across the user's projects that can             be deleted and rebuilt, with sizes. Reach for it when disk space is short or the             user asks what is taking up space. To act on any of it, call             propose_storage_cleanup with paths taken from that listing: it asks the user, who             approves or declines, and only then does Skalman remove anything. Never delete             these directories yourself with shell commands — the proposal exists so the user             sees what is going and what rebuilding it costs.
            """
    )

    static let appearance = MCPToolGroup(
        id: "appearance",
        title: "Terminal theme",
        summary: "Let agents change the colours of this session, its project, or the app.",
        symbol: "paintpalette",
        tools: [
            MCPToolInfo(
                name: MCPTools.listThemes,
                title: "List themes",
                detail: "Read the available themes and which one this session is using.",
                symbol: "list.bullet"
            ),
            MCPToolInfo(
                name: MCPTools.setTheme,
                title: "Set the theme",
                detail: "Apply a theme to this session, its project, or as the default.",
                symbol: "paintbrush"
            ),
            MCPToolInfo(
                name: MCPTools.createTheme,
                title: "Create a theme",
                detail: "Build a new palette from a description, guarded against unreadable text.",
                symbol: "wand.and.stars"
            )
        ],
        instruction: """
            You can change the colours of the terminal you are running in. list_themes reports \
            what exists and what this session currently uses; set_theme applies one, to this \
            session (the default), to its whole project, or as the app-wide default; \
            create_theme builds a new palette when the user describes colours rather than \
            naming a theme — it merges the colours you give onto a base, so a warmer background \
            is one colour, not twenty.

            The change is immediate and needs no restart. Three things are worth knowing: an \
            existing theme is never overwritten, a palette whose text cannot be read on its own \
            background is refused, and a session rendered as a conversation rather than a \
            terminal records the choice but shows almost none of it.

            Do not restyle anything unasked. This changes what the user is looking at while \
            they are looking at it, and the colours they chose are a preference, not a defect \
            to be fixed.
            """
    )

    // MARK: Enabled State

    /// Whether a group is currently switched on. Absent from the disabled set means enabled, so a
    /// group added in a future release is on by default rather than silently missing.
    @MainActor
    static func isEnabled(_ group: MCPToolGroup) -> Bool {
        AppSettings.shared.isToolGroupEnabled(group.id)
    }

    @MainActor
    static var enabledGroups: [MCPToolGroup] {
        groups.filter(isEnabled)
    }

    /// The bare tool names an enabled launch advertises and pre-approves.
    @MainActor
    static var enabledToolNames: [String] {
        enabledGroups.flatMap { $0.tools.map(\.name) }
    }

    /// The `tools/list` payload, filtered to the enabled groups.
    @MainActor
    static var enabledDefinitions: [MCPToolDefinition] {
        let names = Set(enabledToolNames)
        return MCPTools.definitions.filter { names.contains($0.name) }
    }

    /// The `initialize` instructions, assembled from the enabled groups so the model is told about
    /// exactly the tools it has. Empty when everything is off — the server then advertises nothing.
    @MainActor
    static var instructions: String {
        let enabled = enabledGroups
        guard !enabled.isEmpty else { return "" }

        let intro = """
            You are running inside Skalman, a native macOS app, in a terminal pane beside a \
            display panel that can render what the terminal itself cannot. The panel belongs to \
            this session alone; other sessions have their own.
            """

        return ([intro] + enabled.map(\.instruction)).joined(separator: "\n\n")
    }
}
