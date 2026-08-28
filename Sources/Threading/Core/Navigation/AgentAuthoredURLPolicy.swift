import Foundation

/// The one kind of external navigation untrusted agent-authored content may create.
///
/// Both native Markdown and rendered HTML can hand a URL to a system application. Keeping the
/// allowlist here prevents those two surfaces from quietly acquiring different scheme policies.
enum AgentAuthoredURLPolicy {
  static func externalWebURL(_ value: String) -> URL? {
    guard let url = URL(string: value) else { return nil }
    return externalWebURL(url)
  }

  static func externalWebURL(_ url: URL) -> URL? {
    guard let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else { return nil }
    return url
  }
}
