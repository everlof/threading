import AppKit

// MARK: - Version

public enum ThreadingPluginAPI {
    /// The contract generation this build of the framework speaks.
    ///
    /// A plugin records the value it was compiled against in `pluginAPIVersion`; the host refuses
    /// a mismatch rather than calling into a differently-shaped protocol.
    ///
    /// **This number describes the binary call shape, and moves for a removal or a re-type.** A
    /// mismatch stops every installed plugin from loading until its author rebuilds, so the rule
    /// decides whether this is an SDK or a moving target — and the first draft said "bump whenever
    /// a member is added", which would have broken every third-party plugin the next time we grew
    /// a hook. `ThreadingNativePlugin` is an `@objc protocol`, so a new member declared
    /// `@objc optional` breaks no existing conformer, and a new stored property on a payload class
    /// below is additive under library evolution. Neither is a generation.
    ///
    /// A change that affects an author's *source* but not the selectors and signatures the host
    /// calls does not move it either. Adding `@MainActor` to the protocol was exactly that: an
    /// existing plugin binary keeps working, and someone rebuilding gets a compile error they fix
    /// in one line. Bumping would have refused working binaries to announce a change that could
    /// not break them, which is the cost this gate exists to avoid — so such changes belong in
    /// release notes rather than here.
    ///
    /// Host-side symbols are not the contract at all. `PluginLoader` and `PluginLoadFailure` live
    /// here because the host and its tests need them, but nothing a plugin compiles against
    /// depends on their shape.
    public static let version = 3
}

// MARK: - Theme

/// The design values a plugin is given, and the whole of what it may assume about appearance.
///
/// A class rather than a struct on purpose. `NSBundle` can only vend an Objective-C principal
/// class, so the plugin entry point is an `@objc` protocol, and an `@objc` signature cannot carry
/// a Swift struct. Making the payloads classes is what buys a *typed* contract without giving up
/// the Objective-C runtime matching the loader depends on.
///
/// The tokens are the floor: enough to draw something that belongs, with no dependency beyond
/// this framework. A plugin that links `ThreadingDesignKit` should prefer `encodedTheme`, which
/// carries the host's whole theme rather than seven values sampled from it — the components then
/// resolve every colour, radius, bevel and font themselves, exactly as the application's do. See
/// `docs/architecture/plugins.md`.
@objc(ThreadingPluginTheme)
public final class PluginTheme: NSObject {
    public let background: NSColor
    public let surface: NSColor
    public let text: NSColor
    public let secondaryText: NSColor
    public let accent: NSColor
    public let monospacedFont: NSFont
    public let rowHeight: CGFloat
    /// Whether the host is currently presenting a dark appearance. A plugin should prefer the
    /// colours above; this exists for the cases where a system control has to be told.
    public let isDark: Bool

    /// The host's complete theme, encoded.
    ///
    /// Opaque here on purpose: this framework is the narrow contract both sides link, and it must
    /// not gain a dependency on the design system to describe a theme. A plugin linking
    /// `ThreadingDesignKit` hands this to `HostThemeHandoff` and gets the real palette; one that
    /// does not link it ignores the field and uses the tokens above. `nil` when the host could not
    /// encode its theme, which is not a reason to refuse to draw.
    public let encodedTheme: Data?

    public init(
        background: NSColor,
        surface: NSColor,
        text: NSColor,
        secondaryText: NSColor,
        accent: NSColor,
        monospacedFont: NSFont,
        rowHeight: CGFloat,
        isDark: Bool,
        encodedTheme: Data? = nil
    ) {
        self.background = background
        self.surface = surface
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.monospacedFont = monospacedFont
        self.rowHeight = rowHeight
        self.isDark = isDark
        self.encodedTheme = encodedTheme
        super.init()
    }
}

// MARK: - Context

/// What the host tells a plugin about the pane it is being asked to fill.
///
/// `arguments` is a narrow string dictionary rather than a door into the application's model. A
/// plugin never receives a session, a project, a store or a window: if it needs to know something,
/// that thing gets a name here and becomes part of the versioned contract.
@objc(ThreadingPluginContext)
public final class PluginContext: NSObject {
    public let theme: PluginTheme
    public let arguments: [String: String]

    public init(theme: PluginTheme, arguments: [String: String]) {
        self.theme = theme
        self.arguments = arguments
        super.init()
    }

    /// Convenience for the common "an optional named argument" read.
    public func argument(_ name: String) -> String? {
        arguments[name]
    }
}

// MARK: - Tools

/// A tool a plugin contributes to the agent.
///
/// The schema travels as a JSON *string* for the same reason the payloads above are classes: the
/// entry point is an `@objc` protocol, and the Objective-C runtime the loader depends on cannot
/// carry a Swift enum tree. The host parses it at its own edge.
///
/// `name` is unqualified — `search`, not `device_log_search`. The host prefixes it with the
/// plugin's identity so two plugins cannot collide, and so a name in a transcript says where it
/// came from.
@objc(ThreadingPluginTool)
public final class PluginTool: NSObject {
    public let name: String
    /// Shown in Settings beside Threading's own tool groups.
    public let title: String
    /// One line, for the group's row.
    public let detail: String
    public let symbol: String
    /// What the agent reads when deciding whether to call it.
    public let summary: String
    /// A JSON Schema object, as text.
    public let inputSchemaJSON: String

    public init(
        name: String,
        title: String,
        detail: String,
        symbol: String,
        summary: String,
        inputSchemaJSON: String
    ) {
        self.name = name
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.summary = summary
        self.inputSchemaJSON = inputSchemaJSON
        super.init()
    }
}

// MARK: - The contract

/// A natively rendered pane supplied by a loadable bundle.
///
/// The bundle's `NSPrincipalClass` conforms to this. The host owns placement, lifetime, trust and
/// the theme; the plugin owns everything inside the rectangle it is given.
///
/// **Both sides must link this framework.** Compiling a copy of this declaration into the host and
/// another into the plugin does not work: two `@objc protocol` declarations in two binaries are two
/// protocols, and the conformance check fails. `Probes/NativePluginTier` found that the hard way
/// and its README records it.
@MainActor
@objc(ThreadingNativePlugin)
public protocol ThreadingNativePlugin: NSObjectProtocol {
    init()

    /// The contract generation this plugin was compiled against. Compare with
    /// `ThreadingPluginAPI.version`.
    @objc static var pluginAPIVersion: Int { get }

    /// Stable identity, recorded by the host so a plugin that crashes can be quarantined by name
    /// rather than by path.
    @objc var pluginIdentifier: String { get }

    /// Build the pane. Called once per presentation.
    @objc func makePaneView(context: PluginContext) -> NSView

    /// Called after `makePaneView`, and again on every live theme change.
    @objc func apply(theme: PluginTheme)

    /// Tools this plugin offers the agent, if any.
    ///
    /// Optional because a plugin that only draws is a complete plugin. Read once when the plugin
    /// loads: a tool list that changed underneath the agent's own discovery would be a tool that
    /// sometimes exists.
    @objc optional var pluginTools: [PluginTool] { get }

    /// Runs one of them.
    ///
    /// `argumentsJSON` is the object the agent sent; the reply is text and whether it is an error,
    /// which is what an MCP result carries. Asynchronous because a tool may have to ask the thing
    /// it is a tool for — a query against a store, a pane that has to lay out — and blocking the
    /// caller to do it would block the agent.
    @objc optional func invokeTool(
        named name: String,
        argumentsJSON: String,
        completion: @escaping (String, Bool) -> Void
    )
}
