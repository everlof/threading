# ThreadingPluginKit

The contract between Threading and a **native plugin**: a code bundle the app `dlopen`s into its
own process, with full AppKit and no sandbox.

This is not the safe extension tier. A safe extension is an out-of-process executable built
against `ThreadingExtensionKit`, and the operating system contains it. A native plugin runs with
everything Threading has: the user's files, the network, and every TCC grant the app holds. An
install review has to say plainly which of the two a thing is.

## What you need

This package, and nothing else. `Examples/HelloPanePlugin` is the proof: one dependency, one
source file, one build command.

Threading's bundled native plugins additionally link `ThreadingDesignKit` so their rows are drawn
by the same components as the rest of the window. That package is not published yet, so external
plugins use `PluginTheme`: its full semantic colour palette keeps custom components aligned with
the active design system, while its original seven values remain the compatibility fallback for
older hosts. The unpublished kit buys exact component, typography, material and geometry reuse;
it does not grant additional host capabilities or data.

## Writing one

```swift
import AppKit
import ThreadingPluginKit

@objc(MyPlugin)
public final class MyPlugin: NSObject, ThreadingNativePlugin {
    public static let pluginAPIVersion = 5
    public var pluginIdentifier: String { "com.example.myplugin" }

    public override required init() { super.init() }

    public func makePaneView(context: PluginContext) -> NSView { ... }
    public func apply(theme: PluginTheme) { ... }
}
```

`@objc(MyPlugin)` is load-bearing. `NSBundle` resolves `NSPrincipalClass` through the Objective-C
runtime, so the name in `Info.plist` has to be that one and not the mangled Swift symbol.

Optionally contribute tools the agent can call, through `pluginTools` and `invokeTool`. Tool names
are unqualified — `search`, not `my_plugin_search` — and the host prefixes them with your identity
so two plugins cannot collide.

## Building one

```sh
Tools/build-plugin.sh path/to/MyPlugin --identifier com.example.myplugin --install
```

Three of the steps it performs are not guessable, and each fails by blaming something else:

* the product is linked `-bundle`, not as a plain dylib;
* `NSPrincipalClass` names the `@objc` class;
* the dependency's install name is rewritten to
  `@rpath/ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit`. Without it dyld maps a
  second copy of this framework, and two `@objc` protocol declarations in two images are two
  protocols — so the host refuses your plugin for *not conforming to a protocol it plainly
  conforms to*.

Signing defaults to ad-hoc, which Threading accepts. A Developer ID is not required to write a
plugin; it is how the person installing it knows who you are.

## How the host decides

`~/Library/Application Support/Threading/Plugins` is where installed bundles go. Threading ships
hardened runtime carrying `com.apple.security.cs.disable-library-validation`, so the operating
system will map a bundle signed by anyone, or ad-hoc. **Every check is this package's**, and the
order is a property of `PluginLoader` rather than of whoever calls it:

1. the bundle is readable;
2. its signature validates — from any signer, ad-hoc included;
3. the user has approved *this build*, recorded against the code directory hash, so an update asks
   again;
4. only then is `principalClass` touched, which is the call that maps and runs your code.

There is no team allowlist. There was one, holding Threading's own team and nothing else, which
closed the tier to everyone but us. A plugin of ours installed the ordinary way is refused until
approved exactly as yours is; `NativePluginParityTests` in the app asserts it.

Every refusal has a name (`PluginLoadFailure.code`) carrying no path or identity, because "the
plugin did not appear" is not a diagnosis.

## Versioning

`ThreadingPluginAPI.version` is the latest generation the host will load, and it describes the
**binary call shape**. The host also publishes `minimumSupportedVersion`; anything outside that
closed range is refused before selector dispatch. The generation moves for a removal, a re-type,
or when a formerly required selector becomes optional. Ordinary new protocol members are
`@objc optional`, and new payload fields are additive under library evolution.

Version 4 makes `makePaneView` optional so a plugin may provide only a workspace navigator. A v4
host still accepts v3 pane plugins; a v3 host rejects a v4 navigator-only plugin before attempting
the pane selector.

Version 5 adds the optional provider-neutral `PluginWorkspaceChangeRequest` on session rows, the
`openChangeRequest` host action, and bounded visible-row interest through
`setVisibleItemIdentities`. A navigator reports only realized session rows; Threading owns local
Git, remote providers, credentials, caching, URL validation, and the browser action. Existing v3
and v4 plugins remain in the compatibility window.

The plugin's `pluginAPIVersion` must be a numeric literal for the SDK generation it was compiled
against. Do not implement it by returning `ThreadingPluginAPI.version`: installed plugins use the
host's copy of the dynamic framework, so that implementation would report the host's generation
instead of the plugin's and defeat the compatibility check. The literal is intentionally the one
line an author updates when adopting a new contract generation.

A change that affects your source but not the selectors the host calls does not move it either —
your installed build keeps working, and rebuilding tells you in one compile error. Those are in
the release notes. `PluginLoader` and `PluginLoadFailure` are host-side and not part of the number
at all.
