#if os(macOS)
import CoreGraphics

// Linux Foundation supplies these concrete aliases. In the standalone macOS compiler fixture,
// use the same CoreGraphics geometry that Apple's AppKit would re-export, without loading AppKit.
public typealias NSRect = CGRect
public typealias NSPoint = CGPoint
public typealias NSSize = CGSize
#endif
