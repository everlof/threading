/// Real AppKit re-exports Foundation, which is why `import AppKit` alone is enough for `NSRect`,
/// `CGFloat` and `NSCoder` in every file in `UI/Design`. The shim has to say so too — without
/// this line, 816 `NSRect` sites stop resolving even though Linux Foundation defines the type.
@_exported import Foundation
