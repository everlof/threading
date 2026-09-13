import AppKit
import ThreadingPluginKit

/// A pane that says hello in the host's own colours, and one tool that lets the agent change what
/// it says.
///
/// The `@objc` name matters: `NSBundle` looks up `NSPrincipalClass` through the Objective-C
/// runtime, so the name in `Info.plist` has to be this one rather than the mangled Swift symbol.
/// `Tools/build-plugin.sh` writes the package's name into both.
///
/// No `@MainActor` here: `ThreadingNativePlugin` carries it, so a conformer is main-actor isolated
/// and may hold views as stored properties without the compiler objecting.
@objc(HelloPanePlugin)
public final class HelloPanePlugin: NSObject, ThreadingNativePlugin {

    // Keep this a literal. Installed plugins share the host's framework at runtime, so forwarding
    // to ThreadingPluginAPI.version would report the host generation instead of this build's.
    public static let pluginAPIVersion = 5

    public var pluginIdentifier: String { "com.example.hellopane" }

    private let label = NSTextField(labelWithString: "Hello from a plugin.")
    private var pane: NSView?

    public override required init() {
        super.init()
    }

    // MARK: - Drawing

    public func makePaneView(context: PluginContext) -> NSView {
        let view = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
        if let greeting = context.argument("greeting") { label.stringValue = greeting }
        pane = view
        return view
    }

    /// Called once after `makePaneView`, and again every time the host's theme changes. A plugin
    /// that reads the theme only in `makePaneView` looks right until someone switches themes.
    public func apply(theme: PluginTheme) {
        pane?.wantsLayer = true
        pane?.layer?.backgroundColor = theme.background.cgColor
        label.textColor = theme.text
        label.font = theme.monospacedFont
    }

    // MARK: - Tools

    /// Optional: a plugin that only draws is a complete plugin.
    ///
    /// Names are unqualified. The host prefixes them with the plugin's identity, so two plugins
    /// cannot collide and a name in a transcript says where it came from.
    public var pluginTools: [PluginTool] {
        [
            PluginTool(
                name: "set_greeting",
                title: "Hello Pane",
                detail: "Change what the example pane says.",
                symbol: "hand.wave",
                summary: "Sets the greeting shown in the Hello pane.",
                inputSchemaJSON: """
                {
                  "type": "object",
                  "properties": { "text": { "type": "string" } },
                  "required": ["text"]
                }
                """
            ),
        ]
    }

    public func invokeTool(
        named name: String,
        argumentsJSON: String,
        completion: @escaping (String, Bool) -> Void
    ) {
        guard name == "set_greeting" else {
            return completion("no such tool: \(name)", true)
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any]
        guard let text = arguments?["text"] as? String else {
            return completion("set_greeting needs a string `text`", true)
        }
        label.stringValue = text
        completion("greeting is now \(text)", false)
    }
}
