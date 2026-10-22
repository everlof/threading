import Foundation

/// The current native event while the host routes a press through the view tree.
@MainActor
public final class NSApplication {
    public static let shared = NSApplication()
    public var currentEvent: NSEvent?
    private init() {}
}

@MainActor public var NSApp: NSApplication { NSApplication.shared }

@MainActor
public final class NSWorkspace {
    public static let shared = NSWorkspace()
    public var accessibilityDisplayShouldReduceMotion: Bool {
        ProcessInfo.processInfo.environment["THREADING_LINUX_REDUCE_MOTION"] == "1"
    }
    private init() {}

    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
