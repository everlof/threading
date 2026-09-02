import AppKit

// MARK: - Version

public enum ThreadingPluginAPI {
    /// The contract generation this build of the framework speaks.
    ///
    /// A plugin records the value it was compiled against in `pluginAPIVersion`; the host refuses
    /// a mismatch rather than calling into a differently-shaped protocol. Bump this whenever a
    /// member is added, removed or re-typed.
    public static let version = 1
}

// MARK: - Theme

/// The design values a plugin is given, and the whole of what it may assume about appearance.
///
/// A class rather than a struct on purpose. `NSBundle` can only vend an Objective-C principal
/// class, so the plugin entry point is an `@objc` protocol, and an `@objc` signature cannot carry
/// a Swift struct. Making the payloads classes is what buys a *typed* contract without giving up
/// the Objective-C runtime matching the loader depends on.
///
/// This is deliberately tokens only. The intended end state is that a plugin links
/// `ThreadingDesignKit` and uses the real themed components, at which point this type shrinks to
/// whatever the components cannot resolve themselves. See
/// `docs/feature-drafts/native-extension-tier.md`.
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

    public init(
        background: NSColor,
        surface: NSColor,
        text: NSColor,
        secondaryText: NSColor,
        accent: NSColor,
        monospacedFont: NSFont,
        rowHeight: CGFloat,
        isDark: Bool
    ) {
        self.background = background
        self.surface = surface
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.monospacedFont = monospacedFont
        self.rowHeight = rowHeight
        self.isDark = isDark
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
}
