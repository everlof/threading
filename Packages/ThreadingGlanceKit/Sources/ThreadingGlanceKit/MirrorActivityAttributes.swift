#if os(iOS)
import ActivityKit
import Foundation

/// The Live Activity a running Mirror shows while Threading is not in front: in the Dynamic
/// Island, on the Lock Screen and in StandBy. It is the way back to the stage and the way out.
///
/// Shared by the app, which starts it locally the moment the stage opens (so no push is needed),
/// and the widget extension, which draws it.
public struct MirrorActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var sourceTitle: String
        public var updatedAt: Date

        public init(sourceTitle: String, updatedAt: Date) {
            self.sourceTitle = sourceTitle
            self.updatedAt = updatedAt
        }
    }

    public var macName: String
    public var hostID: String
    public var mirrorID: String

    public init(macName: String, hostID: String, mirrorID: String) {
        self.macName = macName
        self.hostID = hostID
        self.mirrorID = mirrorID
    }

    /// Where **Return** goes: the app routes it back to the stage for this mirror.
    public var returnURL: URL? {
        var components = URLComponents()
        components.scheme = "threading"
        components.host = "mirror"
        components.queryItems = [
            URLQueryItem(name: "host", value: hostID),
            URLQueryItem(name: "id", value: mirrorID),
        ]
        return components.url
    }
}

/// A `threading://mirror?host=…&id=…` link, parsed strictly.
public struct MirrorReturnRoute: Equatable, Sendable {
    public let hostID: String
    public let mirrorID: String

    public init?(url: URL) {
        guard url.scheme == "threading", url.host == "mirror",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 2,
              let host = items.first(where: { $0.name == "host" })?.value,
              let id = items.first(where: { $0.name == "id" })?.value,
              Self.isToken(host), Self.isToken(id)
        else { return nil }
        hostID = host
        mirrorID = id
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0))
            }
    }
}
#endif
