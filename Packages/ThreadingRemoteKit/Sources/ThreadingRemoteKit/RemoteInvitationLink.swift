import Foundation

/// Everything a Threading client can be handed to join a Mac, behind one parser.
///
/// There were two payload shapes before this existed and the phone told them apart with a
/// `if let … else if let …` inside a SwiftUI view, which meant only the paste field could read
/// them. A tapped link arrives somewhere else entirely, and a second copy of that ladder is
/// exactly how the two forms drift apart. Everything that receives a payload — the QR scanner,
/// the paste field, and the `threading://` route the operating system delivers — resolves it
/// here.
///
/// ## The `JOIN` form
///
/// A one-chat invitation points at a private door: a LAN address or a tailnet name, with the
/// Mac's own certificate fingerprint in the fragment. That URL is `https`, so tapping it opens
/// Safari, and Safari can only offer the certificate interstitial: the trust model lives in the
/// app's pin, which a browser has no way to learn. Routing it to the app instead is a wrapper,
/// not a weakening — `JOIN` carries the identical `https` URL, fragment and all, and the app
/// pins the fingerprint before its first request exactly as a scanned code does.
public enum RemoteInvitation: Equatable, Sendable {
    /// A hosted rendezvous credential: `THREADING://PAIR#…`.
    case hostedPairing(HostedPairingLink)
    /// A private door with a bearer, whether it arrived as `https://…#token.fingerprint` or
    /// wrapped in `threading://join#…`.
    case connection(RemoteConnectionLink)

    /// The app's registered URL scheme. Registered lower case in `CFBundleURLTypes`; schemes are
    /// case-insensitive (RFC 3986 §3.1), so the upper-case QR payloads still route here.
    public static let scheme = "threading"
    public static let pairHost = "pair"
    public static let joinHost = "join"

    /// The same ceiling `HostedPairingLink` uses. A payload arrives from a camera, a pasteboard
    /// or another application, so its length is somebody else's decision until it is bounded.
    public static let maximumEncodedBytes = HostedPairingLink.maximumEncodedBytes

    public init?(payload: String, now: Date = Date()) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumEncodedBytes else { return nil }
        if let hosted = HostedPairingLink(string: trimmed, now: now) {
            self = .hostedPairing(hosted)
            return
        }
        if let unwrapped = Self.joinedShareURL(trimmed),
           let link = RemoteConnectionLink(string: unwrapped) {
            self = .connection(link)
            return
        }
        if let link = RemoteConnectionLink(string: trimmed) {
            self = .connection(link)
            return
        }
        return nil
    }

    /// Whether this payload names the app's own scheme at all, which is what a URL route asks
    /// before it decides the operating system handed it something meant for somebody else.
    public static func isAppScheme(_ payload: String) -> Bool {
        URLComponents(string: payload.trimmingCharacters(in: .whitespacesAndNewlines))?
            .scheme?
            .lowercased() == Self.scheme
    }

    /// The `https` invitation carried inside a `threading://join#…` payload, or nil.
    static func joinedShareURL(_ payload: String) -> String? {
        guard let components = URLComponents(string: payload),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.joinHost,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              let fragment = components.fragment,
              let data = Data(
                  base64URLEncoded: fragment,
                  maximumBytes: Self.maximumEncodedBytes
              ),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }
}

public extension RemoteConnectionLink {
    /// The same invitation, addressed to the Threading app rather than to a browser.
    ///
    /// Lower case, unlike `scannablePayload`: that one is upper case to keep a QR code in its
    /// cheaper alphanumeric mode, and this one is read by a person in a message.
    var appOpenPayload: String {
        let encoded = Data(shareURL.absoluteString.utf8).base64URLEncodedString()
        return "\(RemoteInvitation.scheme)://\(RemoteInvitation.joinHost)#\(encoded)"
    }
}

/// The one composition of what an invitation looks like when it leaves Threading.
///
/// The Mac copies a share link from two menus and the iPhone puts one into the system share
/// sheet and onto the pasteboard. All four wrote `url.absoluteString` and nothing else, so the
/// recipient received a bare `https://192.168.1.181:8760/#…` with no way to know it wanted the
/// app, wanted their network, or would open on a certificate warning. Four call sites composing
/// their own sentence is four sentences; this is one.
///
/// The guidance sentence is passed in because each application localizes through its own
/// catalog. The *order and shape* of the message is what lives here, which is what could
/// otherwise drift.
public enum RemoteInvitationShare {
    private static let lineSeparator = "\n"

    public static func text(for link: RemoteConnectionLink, guidance: String) -> String {
        [
            guidance,
            link.appOpenPayload,
            link.shareURL.absoluteString,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: lineSeparator)
    }

    /// The same message from the URL a freshly minted share hands back.
    ///
    /// A share URL that cannot be read back as a link is written through unchanged rather than
    /// dropped: an invitation the recipient cannot use is worse than one without its sentence.
    public static func text(shareURL: URL, guidance: String) -> String {
        guard let link = RemoteConnectionLink(url: shareURL) else {
            return shareURL.absoluteString
        }
        return text(for: link, guidance: guidance)
    }
}

extension Data {
    init?(base64URLEncoded value: String, maximumBytes: Int) {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: base64), data.count <= maximumBytes else {
            return nil
        }
        self = data
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
