import Foundation

/// Platform clipboard services are supplied by the native window host. A shim-only render
/// cannot claim a successful copy without such a service; fixtures install an explicit writer.
@MainActor
public final class NSPasteboard {
    public struct PasteboardType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let string = PasteboardType(rawValue: "public.utf8-plain-text")
    }

    public static let general = NSPasteboard()
    public var writeString: ((String) -> Bool)?
    public var readString: (() -> String?)?
    public private(set) var changeCount = 0

    @discardableResult public func clearContents() -> Int {
        if writeString?("") == true { changeCount &+= 1 }
        return changeCount
    }

    @discardableResult public func setString(_ string: String, forType type: PasteboardType) -> Bool {
        guard type == .string, string.utf8.prefix(65_537).count <= 65_536,
              writeString?(string) == true else { return false }
        changeCount &+= 1
        return true
    }

    public func string(forType type: PasteboardType) -> String? {
        guard type == .string, let value = readString?(),
              value.utf8.prefix(65_537).count <= 65_536 else { return nil }
        return value
    }
}
