import Foundation

/// Credential-free identity extracted from the common git remote spellings.
///
/// This belongs to git rather than GitHub: provider selection happens only after the host has
/// been parsed, and the same sanitized identity is useful to GitLab and future providers.
struct GitRemoteIdentity: Equatable, Sendable {
    let host: String
    let path: String

    init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    init?(remote: String) {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix(".") else {
            return nil
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ssh", "git"].contains(scheme),
           let host = url.host, !host.isEmpty {
            guard let path = Self.cleanPath(url.path) else { return nil }
            self.host = host.lowercased()
            self.path = path
            return
        }

        // SCP-style syntax: git@github.com:owner/repository.git
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let authority = trimmed[..<colon]
        let rawPath = trimmed[trimmed.index(after: colon)...]
        let host = authority.split(separator: "@").last.map(String.init) ?? ""
        guard !host.isEmpty, !host.contains("/"),
              let path = Self.cleanPath(String(rawPath)) else { return nil }
        self.host = host.lowercased()
        self.path = path
    }

    private static func cleanPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !path.isEmpty,
              !path.split(separator: "/").contains(".."),
              !path.contains("?"),
              !path.contains("#") else { return nil }
        return path
    }
}
