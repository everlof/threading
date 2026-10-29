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
