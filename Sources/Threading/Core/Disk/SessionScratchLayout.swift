import Foundation

// MARK: - Session Scratch Layout

/// An agent session's scratch directory, recognised by the shape of its path.
///
/// This is the third recognizer in `Core/Disk`, beside `ArtifactKind.kind(for:)` (a name plus an
/// ecosystem marker) and `DerivedDataManifest.read(inDirectory:)` (a manifest the producing tool
/// wrote). It exists because neither of those can see the thing that actually holds the space.
///
/// **What was measured.** On 2026-08-17, `/private/tmp/claude-501` held **97 GB across 3,873
/// session directories, of which 3,861 belonged to sessions that no longer exist**. The scratch
/// scan reported only the Xcode caches *inside* them, because `scanScratch` prunes everything
/// else whole — correctly, under the gates it had. The session directory is the unit that grows,
/// and nothing could name it.
///
/// **Why a shape and not a name.** `claude-501` is a namespace Claude Code mints from the user's
/// uid, and the leaf is the session id Threading assigned when it launched the agent. So the path
/// is not a guess about what a directory is for: the leaf either parses as a session id or the
/// directory is not one of these at all. Three components, exactly — a deeper path is something
/// *inside* a session's scratchpad, which this deliberately does not answer about.
///
/// **What this does not establish.** Recognising the shape says only which session a directory
/// belongs to. It says nothing about whether that session is running, and this type refuses to
/// guess: liveness is the caller's to supply, and `ArtifactScanner` will not offer a session
/// directory without it. The separation is the point — a recognizer that also decided liveness
/// would be a delete gate with a filesystem walk inside it.
struct SessionScratchLayout: Equatable {

    // MARK: - Properties

    /// The session the directory was created for. Nothing else in the path identifies it.
    let sessionID: SessionID

    /// The uid-derived namespace the leaf sat under (`claude-501`), kept because it is the half
    /// of the path that proves this is an agent scratch root rather than a coincidence.
    let namespace: String

    // MARK: - Reading

    /// The layout `url` describes, or nil when the path is not a session scratch directory.
    ///
    /// Both sides are compared with symlinks resolved, for the same reason `isDisposableScratch`
    /// does it: `/tmp` is a symlink to `/private/tmp`, and two spellings of one directory must
    /// not read as two places.
    ///
    /// Matching is **structural and exact**. A path is measured in whole components below a root
    /// rather than matched by prefix, so a directory merely *named* like a session id — nested
    /// deeper, or sitting outside any scratch root — is refused rather than normalised into an
    /// answer. Every rule that makes two different paths mean one directory is a rule that runs
    /// backwards; see `StorageCleanupGate`, which refuses on the same principle.
    static func read(_ url: URL, roots: [URL] = ScratchDefaults.roots) -> SessionScratchLayout? {
        let path = normalizedComponents(url)

        for root in roots {
            let rootPath = normalizedComponents(root)
            guard path.count == rootPath.count + ScratchDefaults.sessionScratchDepth,
                  Array(path.prefix(rootPath.count)) == rootPath else { continue }

            let remainder = Array(path.suffix(ScratchDefaults.sessionScratchDepth))
            guard let namespace = remainder.first, isAgentNamespace(namespace) else { continue }

            // The middle component is the project slug. It is deliberately not validated: it is
            // an encoding of a folder path that has changed shape before, and a session directory
            // whose slug this code did not expect is still that session's directory.
            guard let sessionID = SessionID(uuidString: remainder[2]) else { continue }

            return SessionScratchLayout(sessionID: sessionID, namespace: namespace)
        }

        return nil
    }

    /// A path split into components, normalised so that the answer does not depend on whether
    /// the directory happens to exist.
    ///
    /// **`resolvingSymlinksInPath()` alone is not stable here.** It drops a leading `/private`
    /// only when the shorter path still resolves to something on disk, so
    /// `/private/tmp/claude-501/<slug>/<id>` normalises to four components when that directory
    /// exists and five when it does not. A test caught it: the well-formed case passed only
    /// because the path named a real session directory, while a fabricated slug beside it was
    /// refused for having one component too many.
    ///
    /// That is worse than a wrong answer, because a scratch root is the most volatile place this
    /// code looks — during one five-minute measurement a session directory fell from 21 GB to
    /// 92 KB with nobody acting. A recognizer a delete gate rests on cannot change its mind about
    /// what a path *is* because the path was removed while it read it. So the alias is collapsed
    /// unconditionally, on both sides of every comparison: the rule relabels, and cannot make two
    /// genuinely different directories match.
    private static func normalizedComponents(_ url: URL) -> [String] {
        var components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        if components.count > ScratchDefaults.privateAliasMinimumComponents,
           components[1] == ScratchDefaults.privateAliasComponent {
            components.remove(at: 1)
        }

        return components
    }

    /// Whether a component is the uid-derived namespace Claude Code mints (`claude-501`).
    ///
    /// The digits are required rather than ignored. `claude-` alone is a plausible name for
    /// somebody's own directory in `/tmp`; `claude-501` is a namespace with a uid in it.
    private static func isAgentNamespace(_ component: String) -> Bool {
        guard component.hasPrefix(ScratchDefaults.sessionScratchNamespacePrefix) else { return false }

        let digits = component.dropFirst(ScratchDefaults.sessionScratchNamespacePrefix.count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}
