import AppKit

/// The containment boundary for a native plugin presentation.
///
/// Bundled native plugins can link the repository-local `ThreadingDesignKit` product. External
/// plugins instead receive the public `PluginTheme` palette and own the AppKit or SwiftUI tree
/// they return. SwiftUI expands even a plain `TextField` and `ScrollView` into private AppKit
/// controls, so auditing that foreign subtree as app-authored UI would reject every useful
/// SwiftUI plugin after it loaded.
///
/// Permission is still narrow: only the installed presentation and AppKit/framework descendants
/// beneath it cross the boundary. Host-owned siblings remain ordinary application UI and are
/// audited normally.
final class NativePluginPresentationBoundaryView:
    NSView,
    ThemedComponent,
    SystemChromeBoundary
{
    private weak var presentation: NSView?

    func install(_ content: NSView) {
        precondition(presentation == nil, "a native plugin host installs one presentation")
        presentation = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func permitsSystemChrome(_ view: NSView) -> Bool {
        guard let presentation else { return false }
        return view === presentation || view.isDescendant(of: presentation)
    }
}
