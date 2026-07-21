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
    func handle(_ call: MCPToolCall, for sessionID: UUID) -> MCPToolResult
}

// MARK: - Tool Catalogue

/// The tools this server advertises, and the guidance that makes an agent reach for them.
enum MCPTools {

    static let displayImage = "display_image"
    static let displayHTML = "display_html"
    static let displayTools = [displayImage, displayHTML]

    /// Sent in the `initialize` response, where Claude Code and Codex surface it to the model.
    ///
    /// This is the load-bearing half of the feature. An agent running in a terminal has no
    /// reason to believe anything it emits can be seen as an image, so it has to be told that
    /// the surrounding app has a panel and that using it is preferred over describing a file.
    static let instructions = """
        You are running inside Skalman, a native macOS app, in a terminal pane beside a \
        display panel that can render what the terminal itself cannot.

        Use display_image whenever an image is the point: a screenshot you just captured, a \
        chart or diagram you generated, a design asset you were asked to inspect, or a visual \
        diff. Prefer showing the image over describing it or printing its path — the user is \
        looking at the same window and the panel is right there.

        Use display_html when structure is the point and ASCII would mangle it: tables with \
        more than a few columns, charts, Mermaid or graphviz diagrams, side-by-side diffs, \
        rendered reports. It is a real browser engine, so scripts run and CDN libraries load.

        Neither replaces talking to the user. Show the artefact, then say what it means — the \
        panel carries the picture, your reply carries the point.

        The panel belongs to this session alone; other sessions have their own.
        """

    /// The `tools/list` payload.
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
        ]
    ]
}
