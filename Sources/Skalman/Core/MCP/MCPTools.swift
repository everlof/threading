import Foundation

// MARK: - Tool Call

struct DisplayImageArguments: Decodable {
    let path: String?
    let title: String?
}

struct DisplayHTMLArguments: Decodable {
    let html: String?
    let title: String?
}

struct BrowserNavigateArguments: Decodable {
    let url: String?
}

struct BrowserSelectorArguments: Decodable {
    let selector: String?
}

struct SetProjectIconArguments: Decodable {
    let path: String?
    let url: String?
}

struct ListThemesArguments: Decodable {}

struct SetThemeArguments: Decodable {
    let theme: String?
    let scope: String?
}

struct CreateThemeArguments: Decodable {
    let name: String?
    let base: String?
    let colors: [String: String]?
    let apply: String?
}

/// What an agent proposes removing, and why the user should agree.
///
/// Paths arrive as one absolute path per line, since the schema this server speaks has no
/// array type. Whatever arrives is only ever *matched against* the current findings — see
/// `MainWindowController.proposeStorageCleanup`.
struct StorageCleanupArguments: Decodable {
    let paths: String?
    let reason: String?
}

enum PanelTabReference: Decodable, Equatable {
    case index(Int)
    case identifier(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let index = try? container.decode(Int.self) {
            self = .index(index)
        } else {
            self = .identifier(try container.decode(String.self))
        }
    }
}

struct PanelActivateTabArguments: Decodable {
    let tab: PanelTabReference?
}

struct EmptyToolArguments: Decodable {}

/// A `tools/call` request whose argument payload has been decoded for the named tool.
enum MCPToolCall {
    case displayImage(DisplayImageArguments)
    case displayHTML(DisplayHTMLArguments)
    case browserNavigate(BrowserNavigateArguments)
    case browserScreenshot(EmptyToolArguments)
    case browserQuery(BrowserSelectorArguments)
    case browserClick(BrowserSelectorArguments)
    case panelListTabs(EmptyToolArguments)
    case panelActivateTab(PanelActivateTabArguments)
    case setProjectIcon(SetProjectIconArguments)
    case listReclaimableStorage(EmptyToolArguments)
    case proposeStorageCleanup(StorageCleanupArguments)
    case listThemes(ListThemesArguments)
    case setTheme(SetThemeArguments)
    case createTheme(CreateThemeArguments)
    case unknown(String)

    var name: String {
        switch self {
        case .displayImage: return MCPTools.displayImage
        case .displayHTML: return MCPTools.displayHTML
        case .browserNavigate: return MCPTools.browserNavigate
        case .browserScreenshot: return MCPTools.browserScreenshot
        case .browserQuery: return MCPTools.browserQuery
        case .browserClick: return MCPTools.browserClick
        case .panelListTabs: return MCPTools.panelListTabs
        case .panelActivateTab: return MCPTools.panelActivateTab
        case .setProjectIcon: return MCPTools.setProjectIcon
        case .listReclaimableStorage: return MCPTools.listReclaimableStorage
        case .proposeStorageCleanup: return MCPTools.proposeStorageCleanup
        case .listThemes: return MCPTools.listThemes
        case .setTheme: return MCPTools.setTheme
        case .createTheme: return MCPTools.createTheme
        case .unknown(let name): return name
        }
    }
}

/// Decodes `arguments` only after `name` identifies its concrete schema.
struct MCPToolCallParameters: Decodable {
    let call: MCPToolCall

    private enum CodingKeys: String, CodingKey {
        case name, arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)

        switch name {
        case MCPTools.displayImage:
            call = .displayImage(
                try container.decodeIfPresent(DisplayImageArguments.self, forKey: .arguments)
                    ?? DisplayImageArguments(path: nil, title: nil)
            )
        case MCPTools.displayHTML:
            call = .displayHTML(
                try container.decodeIfPresent(DisplayHTMLArguments.self, forKey: .arguments)
                    ?? DisplayHTMLArguments(html: nil, title: nil)
            )
        case MCPTools.browserNavigate:
            call = .browserNavigate(
                try container.decodeIfPresent(BrowserNavigateArguments.self, forKey: .arguments)
                    ?? BrowserNavigateArguments(url: nil)
            )
        case MCPTools.browserScreenshot:
            call = .browserScreenshot(
                try container.decodeIfPresent(EmptyToolArguments.self, forKey: .arguments)
                    ?? EmptyToolArguments()
            )
        case MCPTools.browserQuery:
            call = .browserQuery(
                try container.decodeIfPresent(BrowserSelectorArguments.self, forKey: .arguments)
                    ?? BrowserSelectorArguments(selector: nil)
            )
        case MCPTools.browserClick:
            call = .browserClick(
                try container.decodeIfPresent(BrowserSelectorArguments.self, forKey: .arguments)
                    ?? BrowserSelectorArguments(selector: nil)
            )
        case MCPTools.panelListTabs:
            call = .panelListTabs(
                try container.decodeIfPresent(EmptyToolArguments.self, forKey: .arguments)
                    ?? EmptyToolArguments()
            )
        case MCPTools.panelActivateTab:
            call = .panelActivateTab(
                try container.decodeIfPresent(PanelActivateTabArguments.self, forKey: .arguments)
                    ?? PanelActivateTabArguments(tab: nil)
            )
        case MCPTools.setProjectIcon:
            call = .setProjectIcon(
                try container.decodeIfPresent(SetProjectIconArguments.self, forKey: .arguments)
                    ?? SetProjectIconArguments(path: nil, url: nil)
            )
        case MCPTools.listReclaimableStorage:
            call = .listReclaimableStorage(
                try container.decodeIfPresent(EmptyToolArguments.self, forKey: .arguments)
                    ?? EmptyToolArguments()
            )
        case MCPTools.proposeStorageCleanup:
            call = .proposeStorageCleanup(
                try container.decodeIfPresent(StorageCleanupArguments.self, forKey: .arguments)
                    ?? StorageCleanupArguments(paths: nil, reason: nil)
            )
        case MCPTools.listThemes:
            call = .listThemes(
                try container.decodeIfPresent(ListThemesArguments.self, forKey: .arguments)
                    ?? ListThemesArguments()
            )
        case MCPTools.setTheme:
            call = .setTheme(
                try container.decodeIfPresent(SetThemeArguments.self, forKey: .arguments)
                    ?? SetThemeArguments(theme: nil, scope: nil)
            )
        case MCPTools.createTheme:
            call = .createTheme(
                try container.decodeIfPresent(CreateThemeArguments.self, forKey: .arguments)
                    ?? CreateThemeArguments(name: nil, base: nil, colors: nil, apply: nil)
            )
        default:
            call = .unknown(name)
        }
    }
}

// MARK: - Tool Result

/// What an agent gets back from a tool call.
///
/// Results are deliberately plain text. The image itself never travels back through the
/// protocol — Skalman has already drawn it — so showing a screenshot costs the conversation
/// a sentence rather than an image's worth of tokens.
struct MCPToolResult: Encodable {
    let text: String
    let isError: Bool

    static func success(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: false)
    }

    static func failure(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: true)
    }

    private enum CodingKeys: String, CodingKey {
        case content, isError
    }

    private struct TextContent: Encodable {
        let type = "text"
        let text: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([TextContent(text: text)], forKey: .content)
        try container.encode(isError, forKey: .isError)
    }
}

// MARK: - Tool Handling

/// Implemented by whatever can actually show the content — in practice the main window.
///
/// Called on the main queue, since the model layer and AppKit both require it.
protocol MCPToolHandling: AnyObject {
    func handle(_ call: MCPToolCall, for sessionID: SessionID) -> MCPToolResult

    /// Async variant, for tools whose answer is not ready synchronously — a page load, a DOM
    /// query, a screenshot. Defaults to the synchronous form for handlers that need nothing.
    func handle(_ call: MCPToolCall, for sessionID: SessionID, completion: @escaping (MCPToolResult) -> Void)

    /// Text appended to the `initialize` instructions describing the session's current display
    /// panel — but only when it changed while the agent was away, so a resume does not re-state a
    /// panel the agent's own transcript already reflects. Empty when there is nothing to add.
    func panelState(for sessionID: SessionID) -> String
}

extension MCPToolHandling {
    func handle(_ call: MCPToolCall, for sessionID: SessionID, completion: @escaping (MCPToolResult) -> Void) {
        completion(handle(call, for: sessionID))
    }

    func panelState(for sessionID: SessionID) -> String { "" }
}

// MARK: - Tool Schema

struct MCPToolDefinition: Encodable {
    let name: String
    let description: String
    let inputSchema: MCPInputSchema
}

struct MCPInputSchema: Encodable {
    let type = "object"
    let properties: [String: MCPPropertySchema]
    let required: [String]
}

struct MCPPropertySchema: Encodable {
    let type: MCPPropertyType
    let description: String

    /// The members of an `.object` property. Omitted for every other type, so a scalar's
    /// schema is unchanged.
    var properties: [String: MCPPropertySchema]?
}

enum MCPPropertyType: Encodable {
    case string
    case integerOrString
    /// A nested object, whose members are described by the schema's own `properties`.
    ///
    /// Worth the extra case rather than flattening a structure into a delimited string: a
    /// palette is twenty named colours, and "sixteen hex values, comma separated, in ANSI
    /// order" is a format a model gets subtly wrong while a named object is one it cannot.
    case object

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string:
            try container.encode("string")
        case .integerOrString:
            try container.encode(["integer", "string"])
        case .object:
            try container.encode("object")
        }
    }
}

// MARK: - Tool Catalogue

/// The tools this server advertises, and the guidance that makes an agent reach for them.
enum MCPTools {

    static let displayImage = "display_image"
    static let displayHTML = "display_html"
    static let displayTools = [displayImage, displayHTML]

    static let browserNavigate = "browser_navigate"
    static let browserScreenshot = "browser_screenshot"
    static let browserQuery = "browser_query"
    static let browserClick = "browser_click"
    static let browserTools = [browserNavigate, browserScreenshot, browserQuery, browserClick]

    static let panelListTabs = "panel_list_tabs"
    static let panelActivateTab = "panel_activate_tab"
    static let panelTools = [panelListTabs, panelActivateTab]

    static let setProjectIcon = "set_project_icon"
    static let projectTools = [setProjectIcon]

    static let listReclaimableStorage = "list_reclaimable_storage"
    static let proposeStorageCleanup = "propose_storage_cleanup"
    static let storageTools = [listReclaimableStorage, proposeStorageCleanup]

    static let listThemes = "list_themes"
    static let setTheme = "set_theme"
    static let createTheme = "create_theme"
    static let themeTools = [listThemes, setTheme, createTheme]

    /// Every tool the server serves, all pre-approved together: each only calls back into the app
    /// the user is already looking at, and an agent with a shell already outreaches a browser
    /// click. `MCPToolCatalog` groups these and decides — from the user's Tools settings — which
    /// are actually advertised and pre-approved on a launch.
    static let allTools = displayTools + browserTools + panelTools + projectTools
        + storageTools + themeTools

    /// The full `tools/list` payload. `MCPToolCatalog.enabledDefinitions` filters this to the
    /// groups the user has switched on before it is served.
    static let definitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: displayImage,
            description: """
                Display an image to the user in Skalman's side panel, beside this terminal. \
                Use this for screenshots, generated charts and diagrams, or any image file \
                worth looking at — the terminal cannot render images, so this is the only way \
                the user can actually see one. Supports PNG, JPEG, GIF, HEIC, PDF, and SVG.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "path": MCPPropertySchema(
                        type: .string,
                        description: """
                            Path to the image file. Absolute, or relative to the session's \
                            project folder.
                            """
                    ),
                    "title": MCPPropertySchema(
                        type: .string,
                        description: """
                            Optional caption shown above the image, describing what the user \
                            is looking at.
                            """
                    )
                ],
                required: ["path"]
            )
        ),
        MCPToolDefinition(
            name: displayHTML,
            description: """
                Render an HTML document in Skalman's side panel, beside this terminal. Use \
                this when structure carries the meaning and plain text would destroy it: \
                wide tables, charts, Mermaid or graphviz diagrams, side-by-side diffs, \
                rendered reports.

                It is a real browser engine — inline scripts run, and libraries load from a \
                CDN, so you can pull in Chart.js, Mermaid, or anything similar with a script \
                tag rather than hand-rolling SVG.

                The panel follows the system appearance and is narrow, often around 400px \
                wide. Write for both light and dark, use `prefers-color-scheme` if you set \
                your own colours, and let content reflow rather than assuming a wide viewport. \
                Links open in the user's real browser rather than navigating the panel.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "html": MCPPropertySchema(
                        type: .string,
                        description: """
                            The HTML document. A full document or a fragment; either is \
                            rendered as given.
                            """
                    ),
                    "title": MCPPropertySchema(
                        type: .string,
                        description: """
                            Optional caption shown above the document, describing what the \
                            user is looking at.
                            """
                    )
                ],
                required: ["html"]
            )
        ),
        MCPToolDefinition(
            name: browserNavigate,
            description: """
                Open a URL in Skalman's browser (a full pane beside this terminal), or run a \
                search if the text is not a URL. Waits for the page to load and reports its \
                title and address. Use this before browser_query, browser_click, or \
                browser_screenshot to put the page on screen.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "url": MCPPropertySchema(
                        type: .string,
                        description: "A URL, a bare domain, or a search query."
                    )
                ],
                required: ["url"]
            )
        ),
        MCPToolDefinition(
            name: browserQuery,
            description: """
                Return the elements in the current page matching a CSS selector — their tag, \
                id, classes, visible text, key attributes (href, src, value, aria-label), and \
                on-screen rectangle. This reads the live DOM directly, so prefer it over \
                fetching and parsing HTML. Returns at most a few dozen matches.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "selector": MCPPropertySchema(
                        type: .string,
                        description: "A CSS selector, e.g. \"a.button\", \"#main h2\", \"input[name=q]\"."
                    )
                ],
                required: ["selector"]
            )
        ),
        MCPToolDefinition(
            name: browserClick,
            description: """
                Click the first element matching a CSS selector in the current page. Useful for \
                following a link, submitting a form, or opening a menu. Reports what was clicked \
                and the page's address afterwards, since a click may navigate.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "selector": MCPPropertySchema(
                        type: .string,
                        description: "A CSS selector for the element to click."
                    )
                ],
                required: ["selector"]
            )
        ),
        MCPToolDefinition(
            name: browserScreenshot,
            description: """
                Capture the current browser page and show it to the user as a new image tab in \
                the display panel. Use it to let the user see the page you are working with, or \
                to record how it looked at a point in time.
                """,
            inputSchema: MCPInputSchema(properties: [:], required: [])
        ),
        MCPToolDefinition(
            name: panelListTabs,
            description: """
                List the tabs open in this session's display panel — their index, id, kind \
                (image, document, or browser), title, and which one is active. Use it to see \
                what you have shown the user and to get a tab's index or id for \
                panel_activate_tab.
                """,
            inputSchema: MCPInputSchema(properties: [:], required: [])
        ),
        MCPToolDefinition(
            name: setProjectIcon,
            description: """
                Set the icon Skalman shows for this session's project in its sidebar. Use \
                the project's own mark — a favicon or logo file from the repository, or an \
                image URL such as the GitHub owner avatar. Square images read best; the \
                icon is drawn at 16pt. PNG, JPEG, GIF, HEIC and ICO work; SVG does not.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "path": MCPPropertySchema(
                        type: .string,
                        description: """
                            Path to an image file. Absolute, or relative to the session's \
                            project folder. Provide this or url, not both.
                            """
                    ),
                    "url": MCPPropertySchema(
                        type: .string,
                        description: "An https image URL, when the icon is not a local file."
                    )
                ],
                required: []
            )
        ),
        MCPToolDefinition(
            name: panelActivateTab,
            description: """
                Bring one of the display panel's tabs to the front, so the user is looking at it. \
                Identify the tab by its index (from panel_list_tabs) or its id.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "tab": MCPPropertySchema(
                        type: .integerOrString,
                        description: "The tab's index (0-based, from panel_list_tabs) or its id."
                    )
                ],
                required: ["tab"]
            )
        ),
        MCPToolDefinition(
            name: listReclaimableStorage,
            description: """
                List build output across the user's projects that can be deleted and rebuilt — \
                Rust and Swift build directories, node_modules, caches — with the size of each, \
                which checkout it belongs to, and when it was last written. Use this when disk \
                space is short, or when the user asks what is taking up space. Skalman has \
                already checked that everything listed is ignored by git and rebuildable by a \
                known command, so nothing tracked or irreplaceable appears here. Reading this \
                changes nothing.
                """,
            inputSchema: MCPInputSchema(properties: [:], required: [])
        ),
        MCPToolDefinition(
            name: proposeStorageCleanup,
            description: """
                Propose deleting some of what list_reclaimable_storage returned. This does not \
                delete anything: it shows the user exactly what you are proposing and why, and \
                they approve or decline. Only paths from that listing can be proposed. Say in \
                `reason` what the user gets and what it costs — how much space, and what will \
                have to be rebuilt.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "paths": MCPPropertySchema(
                        type: .string,
                        description: """
                            The directories to propose removing, one absolute path per line, \
                            each exactly as list_reclaimable_storage reported it.
                            """
                    ),
                    "reason": MCPPropertySchema(
                        type: .string,
                        description: """
                            One sentence the user will read, saying why these and what it \
                            costs to rebuild them.
                            """
                    )
                ],
                required: ["paths"]
            )
        ),
        MCPToolDefinition(
            name: listThemes,
            description: """
                List the terminal colour themes available in Skalman — each one's name, whether \
                it is built in, and its background and text colours — and report which theme \
                this session is currently drawing with and which scope decided that. Use it \
                before set_theme, and as the `base` for create_theme.
                """,
            inputSchema: MCPInputSchema(properties: [:], required: [])
        ),
        MCPToolDefinition(
            name: setTheme,
            description: """
                Set the terminal colour theme, for this session, for its whole project, or as \
                the app-wide default. Takes effect immediately — the terminal you are running \
                in is restyled without restarting anything.

                The three scopes are a chain: a session follows its project, and a project \
                follows the default. Prefer `session`, which is what "make this one darker" \
                means and is the only scope that touches nothing else; use `project` or \
                `global` when the user asks for something broader.

                Omit `theme` to clear that scope's choice, so it inherits again. Do not restyle \
                the terminal unasked — this changes what the user is looking at.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "theme": MCPPropertySchema(
                        type: .string,
                        description: """
                            The theme's name, exactly as list_themes reported it. Omit to clear \
                            the assignment at this scope and inherit again.
                            """
                    ),
                    "scope": MCPPropertySchema(
                        type: .string,
                        description: """
                            "session" (the default — this conversation's own terminal), \
                            "project" (every session in this project that has not chosen its \
                            own), or "global" (the app-wide default).
                            """
                    )
                ],
                required: []
            )
        ),
        MCPToolDefinition(
            name: createTheme,
            description: """
                Create a new terminal theme and, unless told otherwise, apply it to this \
                session. Use it when the user describes colours they want rather than naming a \
                theme that exists — "something warmer", "match the Rust logo", "solarized but \
                darker".

                `colors` is merged onto `base`, so changing one colour means sending one \
                colour, not twenty. Every value is a hex string such as "#1E1E2E".

                An existing theme is never overwritten: pick another name if this one is taken. \
                Text that cannot be read against its own background is refused — check the pair \
                yourself before sending, since a terminal the user cannot read is one they \
                cannot type in either.
                """,
            inputSchema: MCPInputSchema(
                properties: [
                    "name": MCPPropertySchema(
                        type: .string,
                        description: "A name for the new theme. Must not already be taken."
                    ),
                    "base": MCPPropertySchema(
                        type: .string,
                        description: """
                            The theme to start from, by name. Defaults to whatever this session \
                            is drawing with now, so unspecified colours keep their current value.
                            """
                    ),
                    "colors": MCPPropertySchema(
                        type: .object,
                        description: """
                            The colours to change, as hex strings. Any subset; anything omitted \
                            is taken from `base`.
                            """,
                        properties: paletteSchema
                    ),
                    "apply": MCPPropertySchema(
                        type: .string,
                        description: """
                            Where to apply the new theme once created: "session" (the default), \
                            "project", "global", or "none" to create it without using it.
                            """
                    )
                ],
                required: ["name", "colors"]
            )
        )
    ]

    /// The twenty named colours of a palette, described once for `create_theme`.
    ///
    /// Generated from `ThemeColorKey` rather than written out, so a colour cannot be added to
    /// the model and left out of the schema an agent reads.
    private static var paletteSchema: [String: MCPPropertySchema] {
        var properties: [String: MCPPropertySchema] = [:]

        for key in ThemeColorKey.allCases {
            let role: String
            switch key {
            case .foreground: role = "Default text colour."
            case .background: role = "The terminal's ground."
            case .cursor: role = "The caret."
            case .selection: role = "The fill behind selected text."
            default: role = "ANSI \(key.displayName.lowercased())."
            }

            properties[key.wireName] = MCPPropertySchema(
                type: .string,
                description: "\(role) Hex, e.g. \"#1E1E2E\"."
            )
        }

        return properties
    }
}
