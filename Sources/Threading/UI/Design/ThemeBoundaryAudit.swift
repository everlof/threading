import AppKit

/// Marks a view as an application-owned theme boundary.
///
/// Runtime auditing uses the marker rather than a list of class names, so a new wrapper cannot
/// become legitimate merely by being named `ThemedSomething`: it opts into the contract and its
/// tests have to prove that contract.
@MainActor
public protocol ThemedComponent: AnyObject {}

/// A themed component that intentionally contains window-server or AppKit-owned chrome.
///
/// Permission is per descendant, not per subtree. A colour well may live inside a swatch without
/// making a raw button beside it legitimate; a scroll view may contain AppKit's overlay scroller
/// without granting its document view an exemption.
@MainActor
public protocol SystemChromeBoundary: AnyObject {
    func permitsSystemChrome(_ view: NSView) -> Bool
}

/// A runtime second line of defence for factories and framework-created view trees.
///
/// The source checker proves how code constructs UI. This checks what actually appeared after
/// AppKit finished expanding it. Tests run it over complete component and screen fixtures.
@MainActor
public enum ThemeBoundaryAudit {

    public struct Violation: Equatable, CustomStringConvertible {
        public let className: String
        public let path: String

        public var description: String { "\(className) at \(path)" }
    }

    public static func violations(in root: NSView) -> [Violation] {
        var result: [Violation] = []
        inspect(root, path: String(describing: type(of: root)), boundaries: [], result: &result)
        return result
    }

    /// Audits only the application-owned content of a window.
    ///
    /// The frame view, title bar and toolbar are AppKit's chrome and intentionally outside the
    /// boundary. Starting at the content controller still includes everything the application
    /// supplied, including split-view wrappers AppKit expanded underneath that root.
    public static func violations(in window: NSWindow) -> [Violation] {
        guard let root = window.contentViewController?.view ?? window.contentView else {
            return []
        }
        root.layoutSubtreeIfNeeded()
        return violations(in: root)
    }

    public static func failureDescription(
        for violations: [Violation],
        windowTitle: String
    ) -> String {
        let detail = violations.map { "  - \($0.description)" }.joined(separator: "\n")
        return """
            Theme boundary violation in \(windowTitle):
            \(detail)
            App-owned window content must use UI/Design components or a named system-chrome boundary.
            """
    }

    private static func inspect(
        _ view: NSView,
        path: String,
        boundaries: [SystemChromeBoundary],
        result: inout [Violation]
    ) {
        if isForbidden(view), !isPermitted(view, by: boundaries) {
            result.append(
                Violation(className: String(describing: type(of: view)), path: path)
            )
        }

        var descendants = boundaries
        if let boundary = view as? SystemChromeBoundary {
            descendants.append(boundary)
        }

        for (index, child) in view.subviews.enumerated() {
            let name = String(describing: type(of: child))
            inspect(
                child,
                path: "\(path)/\(name)[\(index)]",
                boundaries: descendants,
                result: &result
            )
        }
    }

    private static func isPermitted(_ view: NSView, by boundaries: [SystemChromeBoundary]) -> Bool {
        if view is ThemedComponent { return true }
        return boundaries.reversed().contains { $0.permitsSystemChrome(view) }
    }

    private static func isForbidden(_ view: NSView) -> Bool {
        if view is ThemedComponent { return false }

        // Labels are the one safe NSTextField factory: no bezel, background, editing or focus
        // treatment. Test the resulting object rather than trusting which initializer produced it.
        if let field = view as? NSTextField {
            return field.isEditable || field.isBezeled || field.drawsBackground
        }

        // A list's row is where "nobody wrote anything" turns into a colour. AppKit builds a
        // plain `NSTableRowView` for a delegate that declines to supply one, and that row fills
        // its selection from the system accent — the defect this audit could not see, because
        // every class in the tree was legitimate and the wrong pixels came from a permitted one.
        // `ThemedTableView` now creates the themed row itself, so a bare row reaching a rendered
        // tree means a list got its rows from somewhere this boundary does not reach.
        if view is NSTableRowView { return !(view is ThemedComponent) }

        if view is NSImageView { return false }
        if view is NSControl { return true }

        return view is NSScrollView
            || view is NSClipView
            || view is NSTextView
            || view is NSTableHeaderView
            || view is NSVisualEffectView
    }
}
