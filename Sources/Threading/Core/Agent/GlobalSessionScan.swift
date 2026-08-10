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

/// One account location that could not be enumerated completely.
///
/// This is data rather than a log line because an unreadable directory means the scan is
/// incomplete, not empty. Onboarding can therefore preserve the usable results and tell the
/// user exactly which account path needs attention.
struct GlobalScanFailure: Equatable, Sendable {
    let accountID: AccountID
    let path: String
    let reason: String
}

/// What a whole-disk scan found.
struct GlobalScanResult {
    let groups: [DiscoveredProjectImports]
    /// Conversations left out because the folder they ran in no longer exists — a project
    /// cannot be created at a path that is not there, and silence would read as "covered".
    let missingFolderConversations: Int
    /// A bounded set of directory-level failures. Results in `groups` remain valid, but they
    /// must not be presented as a complete inventory while this is non-empty.
    let failures: [GlobalScanFailure]
    let additionalFailureCount: Int

    init(
        groups: [DiscoveredProjectImports],
        missingFolderConversations: Int,
        failures: [GlobalScanFailure] = [],
        additionalFailureCount: Int = 0
    ) {
        self.groups = groups
        self.missingFolderConversations = missingFolderConversations
        self.failures = Array(failures.prefix(GlobalSessionScan.maximumReportedFailures))
        self.additionalFailureCount = additionalFailureCount
            + max(0, failures.count - GlobalSessionScan.maximumReportedFailures)
    }

    var totalFailureCount: Int { failures.count + additionalFailureCount }
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
    /// A damaged tree can fail once per descendant. Preserve enough paths to diagnose the
    /// account without letting an input-controlled directory produce an unbounded UI model.
    static let maximumReportedFailures = 20

    struct Discovery {
        var conversations: [(session: ImportableSession, cwd: String)] = []
        var failures: [GlobalScanFailure] = []
        var additionalFailureCount = 0

        mutating func recordFailure(account: AgentAccount, path: String, reason: String) {
            let failure = GlobalScanFailure(accountID: account.id, path: path, reason: reason)
            if failures.count < GlobalSessionScan.maximumReportedFailures {
                failures.append(failure)
            } else {
                additionalFailureCount += 1
            }
        }

        mutating func append(_ other: Discovery) {
            conversations.append(contentsOf: other.conversations)
            for failure in other.failures {
                if failures.count < GlobalSessionScan.maximumReportedFailures {
                    failures.append(failure)
                } else {
                    additionalFailureCount += 1
                }
            }
            additionalFailureCount += other.additionalFailureCount
        }
    }

    // MARK: - Discovery

    @MainActor
    static func discover(
        completion: @escaping @MainActor @Sendable (GlobalScanResult) -> Void
    ) {
        let replaySources = TranscriptReplayFormat.allCases.map { format in
            (format: format, accounts: AgentAccountDiscovery.accounts(for: format.kind))
        }
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

            var discovery = Discovery()
            for source in replaySources {
                discovery.append(conversations(format: source.format, accounts: source.accounts))
            }

            let result = grouped(
                discovery.conversations,
                knownTranscriptIDs: known,
                rootResolver: resolveRoot,
                folderExists: { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                },
                failures: discovery.failures,
                additionalFailureCount: discovery.additionalFailureCount
            )

            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func conversations(
        format: TranscriptReplayFormat,
        accounts: [AgentAccount]
    ) -> Discovery {
        switch format {
        case .claude: return claudeConversations(accounts: accounts)
        case .codex: return codexConversations(accounts: accounts)
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
        folderExists: (String) -> Bool,
        failures: [GlobalScanFailure] = [],
        additionalFailureCount: Int = 0
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

        return GlobalScanResult(
            groups: groups,
            missingFolderConversations: missing,
            failures: failures,
            additionalFailureCount: additionalFailureCount
        )
    }

    /// The pre-check rule, pure for the boundary test.
    static func isPrechecked(_ session: ImportableSession, now: Date) -> Bool {
        session.lastActiveAt >= now.addingTimeInterval(-precheckWindow)
    }

    // MARK: - Claude

    /// Every transcript under every slug directory. The recorded `cwd` is the authority on
    /// where a chat ran; a transcript without one is skipped, because the slug directory name
    /// is a lossy encoding (`/` → `-`) that cannot be reversed for arbitrary paths.
    static func claudeConversations(
        accounts: [AgentAccount],
        directoryContents: (
            URL,
            [URLResourceKey]?,
            FileManager.DirectoryEnumerationOptions
        ) throws -> [URL] = { url, keys, options in
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        }
    ) -> Discovery {
        var discovery = Discovery()
        for account in accounts {
            let projectsDirectory = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory)

            let slugDirectories: [URL]
            do {
                slugDirectories = try directoryContents(
                    projectsDirectory,
                    nil,
                    [.skipsHiddenFiles]
                )
            } catch {
                // A newly configured account legitimately has no projects directory yet.
                // Anything else means the inventory is incomplete and must remain visible.
                if isMissingDirectory(error) { continue }
                discovery.recordFailure(
                    account: account,
                    path: projectsDirectory.path,
                    reason: error.localizedDescription
                )
                continue
            }

            for directory in slugDirectories {
                let files: [URL]
                do {
                    files = try directoryContents(
                        directory,
                        [.contentModificationDateKey],
                        []
                    )
                } catch {
                    discovery.recordFailure(
                        account: account,
                        path: directory.path,
                        reason: error.localizedDescription
                    )
                    continue
                }

                discovery.conversations.append(contentsOf: files.compactMap { url in
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
                        lastActiveAt: SessionImporter.lastActivity(at: url)
                    )
                    return (session, cwd)
                })
            }
        }
        return discovery
    }

    // MARK: - Codex

    /// Every rollout, keeping the two-phase read: the `session_meta` header answers id and
    /// cwd cheaply, and only files with a real user turn earn the longer title scan.
    static func codexConversations(
        accounts: [AgentAccount]
    ) -> Discovery {
        var discovery = Discovery()
        for account in accounts {
            let root = URL(fileURLWithPath: account.configPath)
                .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)

            do {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    discovery.recordFailure(
                        account: account,
                        path: root.path,
                        reason: CocoaError(.fileReadCorruptFile).localizedDescription
                    )
                    continue
                }
            } catch {
                if isMissingDirectory(error) { continue }
                discovery.recordFailure(
                    account: account,
                    path: root.path,
                    reason: error.localizedDescription
                )
                continue
            }

            var didReportEnumerationError = false
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    didReportEnumerationError = true
                    discovery.recordFailure(
                        account: account,
                        path: url.path,
                        reason: error.localizedDescription
                    )
                    return true
                }
            ) else {
                if !didReportEnumerationError {
                    discovery.recordFailure(
                        account: account,
                        path: root.path,
                        reason: "The directory could not be enumerated."
                    )
                }
                continue
            }

            discovery.conversations.append(contentsOf: enumerator.compactMap { element in
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
                    lastActiveAt: SessionImporter.lastActivity(at: url)
                )
                return (session, header.cwd)
            })
        }
        return discovery
    }

    private static func isMissingDirectory(_ error: Error) -> Bool {
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain
            && (cocoa.code == CocoaError.fileNoSuchFile.rawValue
                || cocoa.code == CocoaError.fileReadNoSuchFile.rawValue)
    }
}
