import Foundation

// MARK: - Tool Call

/// A `tools/call` request, resolved to the session that made it.
struct MCPToolCall {
    let name: String
    let arguments: [String: Any]

    func string(_ key: String) -> String? {
        arguments[key] as? String
    }
}

// MARK: - Tool Result

/// What an agent gets back from a tool call.
///
/// Results are deliberately plain text. The image itself never travels back through the
/// protocol — Skalman has already drawn it — so showing a screenshot costs the conversation
/// a sentence rather than an image's worth of tokens.
struct MCPToolResult {
    let text: String
    let isError: Bool

    static func success(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: false)
    }

    static func failure(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: true)
    }

    var payload: [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ]
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

    /// Every tool the server serves, all pre-approved together: each only calls back into the app
    /// the user is already looking at, and an agent with a shell already outreaches a browser
    /// click. `MCPToolCatalog` groups these and decides — from the user's Tools settings — which
    /// are actually advertised and pre-approved on a launch.
    static let allTools = displayTools + browserTools + panelTools + projectTools

    /// The full `tools/list` payload. `MCPToolCatalog.enabledDefinitions` filters this to the
    /// groups the user has switched on before it is served.
    static let definitions: [[String: Any]] = [
        [
            "name": displayImage,
            "description": """
                Display an image to the user in Skalman's side panel, beside this terminal. \
                Use this for screenshots, generated charts and diagrams, or any image file \
                worth looking at — the terminal cannot render images, so this is the only way \
                the user can actually see one. Supports PNG, JPEG, GIF, HEIC, PDF, and SVG.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": """
                            Path to the image file. Absolute, or relative to the session's \
                            project folder.
                            """
                    ],
                    "title": [
                        "type": "string",
                        "description": """
                            Optional caption shown above the image, describing what the user \
                            is looking at.
                            """
                    ]
                ],
                "required": ["path"]
            ]
        ],
        [
            "name": displayHTML,
            "description": """
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
            "inputSchema": [
                "type": "object",
                "properties": [
                    "html": [
                        "type": "string",
                        "description": """
                            The HTML document. A full document or a fragment; either is \
                            rendered as given.
                            """
                    ],
                    "title": [
                        "type": "string",
                        "description": """
                            Optional caption shown above the document, describing what the \
                            user is looking at.
                            """
                    ]
                ],
                "required": ["html"]
            ]
        ],
        [
            "name": browserNavigate,
            "description": """
                Open a URL in Skalman's browser (a full pane beside this terminal), or run a \
                search if the text is not a URL. Waits for the page to load and reports its \
                title and address. Use this before browser_query, browser_click, or \
                browser_screenshot to put the page on screen.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "A URL, a bare domain, or a search query."
                    ]
                ],
                "required": ["url"]
            ]
        ],
        [
            "name": browserQuery,
            "description": """
                Return the elements in the current page matching a CSS selector — their tag, \
                id, classes, visible text, key attributes (href, src, value, aria-label), and \
                on-screen rectangle. This reads the live DOM directly, so prefer it over \
                fetching and parsing HTML. Returns at most a few dozen matches.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "A CSS selector, e.g. \"a.button\", \"#main h2\", \"input[name=q]\"."
                    ]
                ],
                "required": ["selector"]
            ]
        ],
        [
            "name": browserClick,
            "description": """
                Click the first element matching a CSS selector in the current page. Useful for \
                following a link, submitting a form, or opening a menu. Reports what was clicked \
                and the page's address afterwards, since a click may navigate.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "A CSS selector for the element to click."
                    ]
                ],
                "required": ["selector"]
            ]
        ],
        [
            "name": browserScreenshot,
            "description": """
                Capture the current browser page and show it to the user as a new image tab in \
                the display panel. Use it to let the user see the page you are working with, or \
                to record how it looked at a point in time.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "name": panelListTabs,
            "description": """
                List the tabs open in this session's display panel — their index, id, kind \
                (image, document, or browser), title, and which one is active. Use it to see \
                what you have shown the user and to get a tab's index or id for \
                panel_activate_tab.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "name": setProjectIcon,
            "description": """
                Set the icon Skalman shows for this session's project in its sidebar. Use \
                the project's own mark — a favicon or logo file from the repository, or an \
                image URL such as the GitHub owner avatar. Square images read best; the \
                icon is drawn at 16pt. PNG, JPEG, GIF, HEIC and ICO work; SVG does not.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": """
                            Path to an image file. Absolute, or relative to the session's \
                            project folder. Provide this or url, not both.
                            """
                    ],
                    "url": [
                        "type": "string",
                        "description": "An https image URL, when the icon is not a local file."
                    ]
                ],
                "required": [] as [String]
            ]
        ],
        [
            "name": panelActivateTab,
            "description": """
                Bring one of the display panel's tabs to the front, so the user is looking at it. \
                Identify the tab by its index (from panel_list_tabs) or its id.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tab": [
                        "type": ["integer", "string"],
                        "description": "The tab's index (0-based, from panel_list_tabs) or its id."
                    ]
                ],
                "required": ["tab"]
            ]
        ]
    ]
}
