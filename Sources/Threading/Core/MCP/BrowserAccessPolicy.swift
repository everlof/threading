import Foundation

/// Chooses whether a live browser participates in Threading's signed-in browser state.
///
/// A private context owns one non-persistent WebKit data store. It is deliberately per tab rather
/// than shared between all private tabs, so "private" also means isolated from another agent test.
enum BrowserContextKind: String {
    case shared
    case `private`
}

enum BrowserGrantPromptDefaults {
    /// Long enough for an ordinary page URL, short enough that a padded one cannot push an
    /// alert's buttons off a small screen.
    static let displayedURLCharacters = 120
    static let truncationMark = "…"
}

/// The origin an agent is asking Threading's authenticated browser to expose.
struct BrowserOrigin: Hashable, Equatable {
    let scheme: String
    let host: String
    let port: Int?

    /// The one document in the `about:` scheme this app treats as an origin.
    static let blankPageURLString = "about:blank"

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "about" {
            // Only the blank document is the blank document. This origin is waved through with no
            // prompt and would be described as "this blank page", so the whole `about:` scheme
            // cannot claim both: `about:srcdoc` is neither, and gets no origin at all.
            guard url.absoluteString.caseInsensitiveCompare(Self.blankPageURLString) == .orderedSame
            else { return nil }
            self.scheme = scheme
            host = ""
            port = nil
            return
        }
        guard ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        port = url.port
    }

    var key: String {
        guard !host.isEmpty else { return "\(scheme):" }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    var displayName: String {
        guard !host.isEmpty else { return L10n.string("this blank page") }
        return host + (port.map { ":\($0)" } ?? "")
    }

    /// The exact URL as the grant prompt shows it.
    ///
    /// The prompt used to say "this website", so the only thing naming the target was the host in
    /// the title — which is not enough to answer the question: two paths on one host can be an
    /// article and an account page, and a mangled URL showed as a host that does not exist at all
    /// ("Allow the agent to use file?"). What the browser would load is now on screen beside it.
    ///
    /// The string is agent-supplied and is about to be read as a security question, so three
    /// things are done to it, each of which the prompt's wording depends on:
    ///
    /// * Cc/Cf scalars are dropped — bidi overrides among them, which can visually reorder a host.
    /// * Credentials are removed. `https://example.com@evil.com/` is a page on **evil.com** that
    ///   reads as example.com, and a password in an alert is a secret on screen. This is the one
    ///   place the shown string is deliberately not the loaded string, which is why the host the
    ///   grant is actually keyed on is stated separately by `displayName`. If the URL cannot be
    ///   rebuilt without them, the answer falls back to the origin alone rather than showing them.
    /// * A long URL is cut from the *tail*, so the origin survives padding.
    static func displayURL(_ url: URL) -> String {
        var absolute = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
            absolute = components.string ?? BrowserOrigin(url: url)?.key ?? ""
        }
        let readable = String(String.UnicodeScalarView(
            absolute.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ))
        guard readable.count > BrowserGrantPromptDefaults.displayedURLCharacters else { return readable }
        return readable.prefix(BrowserGrantPromptDefaults.displayedURLCharacters)
            + BrowserGrantPromptDefaults.truncationMark
    }

    /// Whether this origin is the machine itself, and so needs no grant.
    ///
    /// This answer *skips the consent prompt entirely* — `hasBrowserAccess` returns true on it
    /// alone — so it has to mean "loopback" and nothing wider. `hasPrefix("127.")` did not:
    /// `127.` is a legal subdomain label, so `127.evil.com` is an ordinary registrable domain
    /// that read as loopback and was handed Threading's signed-in browser with no prompt. The
    /// octets are parsed rather than string-matched for that reason.
    ///
    /// `.localhost` stays a suffix test on purpose: RFC 6761 reserves the whole TLD for the
    /// loopback, so `sub.localhost` genuinely is this machine.
    var isLocal: Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || Self.isLoopbackIPv4(host)
    }

    /// Whether `host` is a dotted-quad literal inside 127.0.0.0/8.
    ///
    /// Every octet must be plain digits: `Int("0x7f")` is nil, but so is any label that merely
    /// starts with a number, which is what keeps a hostname out of this.
    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        guard octets.allSatisfy({ octet in
            !octet.isEmpty
                && octet.allSatisfy(\.isASCII)
                && octet.allSatisfy(\.isNumber)
                && (Int(octet).map { 0...255 ~= $0 } ?? false)
        }) else { return false }
        return Int(octets[0]) == 127
    }
}

enum BrowserAccessDecision {
    case allowOnce
    case allowPersistently
    case deny
}

/// Test and embedding seam for presenting an origin decision without coupling the policy to a
/// particular window. Production leaves this nil and uses the native alert owned by the
/// coordinator.
typealias BrowserAccessDecisionProvider = (
    _ origin: BrowserOrigin,
    _ purpose: String,
    _ decide: @escaping (BrowserAccessDecision) -> Void
) -> Void

/// Separate from an origin grant because clearing site data is destructive. A persistent
/// "always allow this host" choice must never silently authorize deleting its signed-in state.
typealias BrowserSiteDataDecisionProvider = (
    _ origin: BrowserOrigin,
    _ context: BrowserContextKind,
    _ decide: @escaping (Bool) -> Void
) -> Void

/// Persistent "always allow" choices. Per-session "allow once" choices deliberately live in the
/// coordinator so they vanish with the running app and never become an invisible long-term grant.
@MainActor
final class BrowserAccessStore {
    private enum Keys {
        static let allowedOrigins = "browser.allowedOrigins"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isPersistentlyAllowed(_ origin: BrowserOrigin) -> Bool {
        allowedOrigins.contains(origin.key)
    }

    func allowPersistently(_ origin: BrowserOrigin) {
        var origins = allowedOrigins
        origins.insert(origin.key)
        defaults.set(Array(origins).sorted(), forKey: Keys.allowedOrigins)
    }

    func revoke(_ origin: BrowserOrigin) {
        revoke(key: origin.key)
    }

    func revoke(key: String) {
        var origins = allowedOrigins
        origins.remove(key)
        defaults.set(Array(origins).sorted(), forKey: Keys.allowedOrigins)
    }

    func revokeAll() {
        defaults.removeObject(forKey: Keys.allowedOrigins)
    }

    var allowedOrigins: Set<String> {
        Set(defaults.stringArray(forKey: Keys.allowedOrigins) ?? [])
    }
}
