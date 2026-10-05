import Foundation

/// Font files can exceed one response. Every request still admits at most one MiB.
public struct RemoteThemeAssetRange: Equatable, Sendable {
    public let bytes: Range<Int>
    public let total: Int
    public var requestHeader: String { "bytes=\(bytes.lowerBound)-\(bytes.upperBound - 1)" }
    public var responseHeader: String { "bytes \(bytes.lowerBound)-\(bytes.upperBound - 1)/\(total)" }

    public init?(start: Int, total: Int) {
        guard total > 0, total <= RemoteThemeAsset.maximumFontBytes, start >= 0, start < total else { return nil }
        self.total = total
        bytes = start..<min(total, start + RemoteThemeAsset.maximumBytes)
    }

    public init?(header: String, total: Int) {
        guard header.utf8.count <= 64, header.hasPrefix("bytes="),
              total > 0, total <= RemoteThemeAsset.maximumFontBytes else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
              start >= 0, end >= start, end < total,
              end - start < RemoteThemeAsset.maximumBytes else { return nil }
        self.total = total
        bytes = start..<(end + 1)
    }
}
