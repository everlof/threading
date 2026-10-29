import AppKit

/// The selected pane's recorded ground changed; chrome must resolve its ink against this color.
public struct WindowBackdropDidChange: AppEvent {
    public static let name = Notification.Name("windowBackdropDidChange")
    public let color: NSColor
}
