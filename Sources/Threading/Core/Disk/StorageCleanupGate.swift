import Foundation

/// The one rule that keeps `propose_storage_cleanup` from being an arbitrary-delete primitive:
/// **a proposal may only name paths the scanner already found.**
///
/// Pulled out of the tool handler and made a pure function, because it is the security boundary
/// of the whole storage feature and it lived inline in a method that needs a window, a project
/// store and a modal sheet to reach — so nothing tested it. Everything here is a decision about
/// strings, and the answers are worth pinning:
///
/// - **Matching is exact.** A path that merely *resolves* to a vetted directory — a trailing
///   slash, a `..` segment, a `~`, a symlink — is refused rather than normalised into a match.
///   Normalisation is where a delete gate goes wrong: every rule that makes two different
///   strings mean one directory is a rule an attacker can run backwards. Refusing costs an agent
///   one corrected call, and the refusal names the path so it can tell a typo from a rejection.
/// - **Duplicates in the *findings* are tolerated.** Two projects can list the same artifact —
///   the same folder added twice, or one checkout nested inside another — and the previous
///   `Dictionary(uniqueKeysWithValues:)` **trapped** on that, taking the app down from a tool
///   call. Same path, same directory, so the first wins and the second is not news.
/// - **Duplicates in the *request* collapse**, so an agent that lists a path twice does not put
///   it to the user twice.
enum StorageCleanupGate {

    struct Resolution {
        /// Vetted artifacts the request named, in the order they were asked for.
        let matched: [ReclaimableArtifact]

        /// Named paths that no finding covers. Reported back rather than dropped.
        let unknown: [String]

        /// The request named nothing at all, which is a different failure from naming only
        /// unknown paths — one is a malformed call, the other a stale listing.
        let isEmptyRequest: Bool
    }

    static func resolve(_ paths: String?, against vetted: [ReclaimableArtifact]) -> Resolution {
        var requested: [String] = []
        var seen: Set<String> = []

        for line in (paths ?? "").split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            requested.append(path)
        }

        guard !requested.isEmpty else {
            return Resolution(matched: [], unknown: [], isEmptyRequest: true)
        }

        var known: [String: ReclaimableArtifact] = [:]
        for artifact in vetted {
            known[artifact.url.path] = known[artifact.url.path] ?? artifact
        }

        return Resolution(
            matched: requested.compactMap { known[$0] },
            unknown: requested.filter { known[$0] == nil },
            isEmptyRequest: false
        )
    }
}
