import Foundation

// MARK: - Discovered Project Imports

/// Conversations found on disk that Threading does not track, grouped by the checkout they
/// ran in — the shape onboarding's import page needs: one group per would-be project.
struct DiscoveredProjectImports: Identifiable {
    /// The normalized worktree root the conversations ran in; the folder a project would be
    /// created at.
    let folder: String
    /// Newest first.
    let conversations: [ImportableSession]

    var id: String { folder }
}

/// What a whole-disk scan found.
struct GlobalScanResult {
    let groups: [DiscoveredProjectImports]
    /// Conversations left out because the folder they ran in no longer exists — a project
    /// cannot be created at a path that is not there, and silence would read as "covered".
    let missingFolderConversations: Int
}

// MARK: - Global Session Scan

/// Enumerates *every* conversation each enabled account holds, where `SessionImporter`
/// answers for one project's folder.
///
/// The direction is inverted on purpose: onboarding runs before any project exists, so there
/// is no folder to ask about — conversations are found first and the folders derived from
/// each one's recorded `cwd`. Grouping resolves the cwd to its worktree root (`GitInfo`), so
/// a chat launched in a subdirectory lands with its checkout, and a chat in a nested worktree
/// lands with *that* worktree — the same identity rule `SessionImporter.belongs` draws,
/// arrived at from the other side.
enum GlobalSessionScan {

    /// How far back a found conversation starts pre-checked on the import page.
    static let precheckWindow: TimeInterval = 48 * 60 * 60

    // MARK: - Discovery

    @MainActor
    static func discover(
        completion: @escaping @MainActor @Sendable (GlobalScanResult) -> Void
    ) {
        let claudeAccounts = AgentAccountDiscovery.accounts(for: .claude)
        let codexAccounts = AgentAccountDiscovery.accounts(for: .codex)
        let known = Set(
            ProjectStore.shared.projects
                .flatMap(\.sessions)
                .compactMap { $0.resumeState.transcriptID }
        )

        DispatchQueue.global(qos: .userInitiated).async {
            // Resolving cwd → worktree root shells out to git; conversations cluster in a
            // handful of directories, so the memoized map is what keeps the walk linear in
            // *folders* rather than in conversations — the `TranscriptUsageService` lesson.
            var roots: [String: String?] = [:]
            func resolveRoot(_ cwd: String) -> String? {
                if let cached = roots[cwd] { return cached }
                let root = GitInfo.repositoryRoot(for: cwd).map {
                    SessionImporter.normalized($0.path)
                }
                roots[cwd] = root
                return root
            }

            var found = claudeConversations(accounts: claudeAccounts)
            found.append(contentsOf: codexConversations(accounts: codexAccounts))

            let result = grouped(
                found,
                knownTranscriptIDs: known,
                rootResolver: resolveRoot,
                folderExists: { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }
            )

            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Grouping

    /// The pure core: dedup against what the store already tracks, resolve each conversation's
    /// folder, group, and sort — groups by their newest conversation, conversations newest
    /// first.
    static func grouped(
        _ found: [(session: ImportableSession, cwd: String)],
        knownTranscriptIDs: Set<TranscriptID>,
        rootResolver: (String) -> String?,
        folderExists: (String) -> Bool
    ) -> GlobalScanResult {
        var byFolder: [String: [ImportableSession]] = [:]
        var seen = Set<String>()
        var missing = 0

        for (session, cwd) in found {
            guard !knownTranscriptIDs.contains(session.agentSessionID) else { continue }
            guard seen.insert(session.id).inserted else { continue }

            let normalizedCwd = SessionImporter.normalized(cwd)
            let folder = rootResolver(normalizedCwd) ?? normalizedCwd
            guard folderExists(folder) else {
                missing += 1
                continue
            }
            byFolder[folder, default: []].append(session)
        }

        let groups = byFolder
            .map { folder, conversations in
                DiscoveredProjectImports(
                    folder: folder,
                    conversations: conversations.sorted { $0.lastActiveAt > $1.lastActiveAt }
                )
            }
            .sorted {
                ($0.conversations.first?.lastActiveAt ?? .distantPast)
                    > ($1.conversations.first?.lastActiveAt ?? .distantPast)
            }

        return GlobalScanResult(groups: groups, missingFolderConversations: missing)
    }

    /// The pre-check rule, pure for the boundary test.
    static func isPrechecked(_ session: ImportableSession, now: Date) -> Bool {
        session.lastActiveAt >= now.addingTimeInterval(-precheckWindow)
    }

    // MARK: - Claude

    /// Every transcript under every slug directory. The recorded `cwd` is the authority on
    /// where a chat ran; a transcript without one is skipped, because the slug directory name
    /// is a lossy encoding (`/` → `-`) that cannot be reversed for arbitrary paths.
    private static func claudeConversations(
        accounts: [AgentAccount]
    ) -> [(session: ImportableSession, cwd: String)] {
        accounts.flatMap { account -> [(session: ImportableSession, cwd: String)] in
            let projectsDirectory = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory)

            guard let slugDirectories = try? FileManager.default.contentsOfDirectory(
                at: projectsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return slugDirectories.flatMap { directory -> [(ImportableSession, String)] in
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                ) else { return [] }

                return files.compactMap { url -> (ImportableSession, String)? in
                    guard url.pathExtension == AgentDefaults.transcriptExtension else {
                        return nil
                    }

                    let info = SessionImporter.claudeInfo(at: url)
                    guard let title = info.title, let cwd = info.cwd else { return nil }

                    let session = ImportableSession(
                        agentSessionID: TranscriptID(
                            url.deletingPathExtension().lastPathComponent
                        ),
                        kind: .claude,
                        accountHandle: account.handle,
                        title: title,
                        lastActiveAt: SessionImporter.modificationDate(of: url)
                    )
                    return (session, cwd)
                }
            }
        }
    }

    // MARK: - Codex

    /// Every rollout, keeping the two-phase read: the `session_meta` header answers id and
    /// cwd cheaply, and only files with a real user turn earn the longer title scan.
    private static func codexConversations(
        accounts: [AgentAccount]
    ) -> [(session: ImportableSession, cwd: String)] {
        accounts.flatMap { account -> [(session: ImportableSession, cwd: String)] in
            let root = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return enumerator.compactMap { element -> (ImportableSession, String)? in
                guard let url = element as? URL,
                      url.pathExtension == CodexDiscoveryDefaults.rolloutExtension,
                      url.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix),
                      let header = SessionImporter.codexHeader(at: url),
                      let title = SessionImporter.codexTitle(at: url)
                else { return nil }

                let session = ImportableSession(
                    agentSessionID: header.id,
                    kind: .codex,
                    accountHandle: account.handle,
                    title: title,
                    lastActiveAt: SessionImporter.modificationDate(of: url)
                )
                return (session, header.cwd)
            }
        }
    }
}
