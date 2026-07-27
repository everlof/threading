# MCP Server and Display Panel

How an agent reaches the GUI it runs inside, and the panel it draws into.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Skalman hosts an MCP server and registers it with each Claude or Codex session it launches,
which is how an agent reaches the GUI it is running inside. The terminal stays the input
surface; the display panel becomes the output surface for anything the terminal renders badly.

The transport is HTTP over a loopback port (`NWListener`, no dependency, no entitlement — the
app is unsandboxed already). stdio was the alternative and is worse here: it spawns a child
that would then have to find its way back to the running app, when the app is already alive
and already owns the routing table.

**Session routing is the whole design.** `MCPSessionRegistry` mints a per-session token and
`AgentLauncher` passes a URL embedding it through Claude's `--mcp-config` file or Codex's
one-run `mcp_servers` overrides, so a tool call arrives already attributed — the URL *is* the
identity. `AgentSession.id` is the key, not
`agentSessionID`, which is nil for Codex until discovery.

Three deliberate choices in the launch line:

- **The display tool is pre-approved** with `--allowedTools mcp__skalman__*` for Claude and a
  tool-specific `approval_mode="approve"` override for Codex, or every image raises a
  permission prompt and the feature costs more attention than it saves. Other tools are
  unaffected.
- **No `--strict-mcp-config`**, which would suppress the user's own MCP servers for every
  session Skalman launches — a far larger change than adding one.
- **The `instructions` field of the `initialize` response** carries the "you have a panel,
  prefer it over describing a file" guidance. Capability alone does not change behaviour: an
  agent in a terminal has no reason to believe anything it emits can be seen as an image.
  Both clients consume those server instructions, so a separate system-prompt flag is not
  needed.

Tool results are **plain text, with one exception**. A display tool has already drawn its image,
so the result costs a sentence rather than an image's worth of tokens — and it sidesteps the
undocumented question of what Claude Code does with an image returned from a tool.
`browser_screenshot` is the exception, because visual inspection is the tool's whole purpose: it
returns a standard MCP image block as well as caching and optionally displaying the PNG. See
[`agent-browser.md`](agent-browser.md).

## Display Panel

`DisplayContent.Body` is an enum, so the panel shows either an `NSImageView` or a `WKWebView`
and the `⋯` menu offers only the actions that fit — an image and a document share almost
nothing worth acting on.

Four things were measured rather than assumed, each having first been wrong:

- **A split item's `holdingPriority` ties with its content's hugging**, and both are 250. That
  tie is what let a dragged panel spring back on mouse-up: the divider's new width and the
  labels' preferred width were equally important, so the solver was free to prefer the labels.
  The panel is the one pane the user positions deliberately, so it holds ten points above that
  (`DisplayPaneDefaults.holdingPriority`) and the terminal keeps the default, which is also what
  makes the terminal absorb a window resize. The `NSImageView` note below is the same bug from
  the other end, fixed by flooring the content instead — one pane's worth of content cannot be
  floored one view at a time, which is why the priority moved.
- **`NSSplitView.setPosition` does nothing** under `NSSplitViewController`, which lays its
  items out with Auto Layout. `setPosition(915, ofDividerAt: 1)` left the pane at its 260pt
  minimum. Width is set with a temporary constraint, released once honoured so the divider
  stays draggable.
- **`NSImageView`'s intrinsic content size is the image's own size**, so left alone it drives
  the split view and a 900px image opens a 900pt panel. Both content priorities are floored.
- **The width observer fired during the uncollapse layout**, recording the transient 260pt
  minimum as the user's width and then restoring *that*. `isRestoringDisplayPaneWidth`
  suppresses recording for the reveal, and the target width is read before uncollapsing.

The web view **allows network** and blocks only navigation. A CSP would be theatre: the agent
already has a shell, so anything it could exfiltrate through a page it could exfiltrate more
easily with `curl`. Blocking link navigation is a usability fix — a 380pt browser with no
back button is a trap — not a security control. Links go to `NSWorkspace` instead.

Documents load with `baseURL: nil`, giving an opaque origin: CDN scripts still load (measured),
but the page cannot read local files or same-origin data. A `color-scheme` meta is prepended
only when the document does not mention one, so unstyled HTML picks up WebKit's dark canvas
beside a dark terminal instead of flashing white.

WKWebView works in the unbundled `swift build` binary — worth knowing, since needing an
`.app` bundle for the web content process would have forced the project to Xcode-only builds.

`MCPServer` calls its handler on the main queue, because neither `ProjectStore`, `AgentRuntime`
nor AppKit is thread-safe. Everything arriving off the network hops before touching them.

The listener must be ready before any launch, since a launch reads the port — so
`AppDelegate` defers `restoreSelectedSession()` to the `start` callback. That callback fires
whether the listener came up or not: a failed server costs sessions their panel, not their
launch (`mcpFlags` returns "" and the command line is unchanged).
