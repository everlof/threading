import Foundation
import ThreadingRemoteKit

enum RemoteUniversalSearchError: Error, Equatable {
    case invalidRequest
    case resultNoLongerAvailable
    case unavailable
}

/// The owner-device projection of the universal search graph.
///
/// Provider locators never cross the wire. Each query replaces that device's token generation;
/// resolution consumes an unguessable, 60-second entry and revalidates the underlying model or
/// source before returning a typed destination or a bounded read-only window.
@MainActor
final class RemoteUniversalSearchService {
    typealias WorkspaceMetadata = @MainActor () -> [WorkspaceMetadataSearchRecord]

    private struct TokenEntry {
        let deviceID: String
        let generation: UInt64
        let expiresAt: Date
        let sequence: UInt64
        let locator: SearchLocator
    }

    private struct ActiveQuery {
        let id: UUID
        let generation: UInt64
        let coordinator: UniversalSearchCoordinator
    }

    private struct DeviceGeneration {
        let value: UInt64
        let expiresAt: Date
    }

    private let navigationIndex: NavigationSearchIndexStore
    private let transcriptIndex: TranscriptSearchIndexStore
    private let projectStore: ProjectStore
    private let workspaceMetadata: WorkspaceMetadata
    private let maximumRetainedTokens: Int
    private let workspaceFileIndex = WorkspaceFileIndex()
    private var tokens: [String: TokenEntry] = [:]
    private var nextTokenSequence: UInt64 = 0
    private var generationByDevice: [String: DeviceGeneration] = [:]
    private var activeQueryByDevice: [String: ActiveQuery] = [:]

    init(
        navigationIndex: NavigationSearchIndexStore,
        transcriptIndex: TranscriptSearchIndexStore,
        projectStore: ProjectStore,
        workspaceMetadata: @escaping WorkspaceMetadata = { [] },
        maximumRetainedTokens: Int = RemoteSearchWireLimits.maximumVisibleHits * 32
    ) {
        precondition(maximumRetainedTokens > 0)
        self.navigationIndex = navigationIndex
        self.transcriptIndex = transcriptIndex
        self.projectStore = projectStore
        self.workspaceMetadata = workspaceMetadata
        self.maximumRetainedTokens = maximumRetainedTokens
    }

    func search(
        _ request: RemoteSearchRequestDTO,
        deviceID: String
    ) async throws -> RemoteSearchResponseDTO {
        guard request.query.utf8.count <= RemoteSearchWireLimits.maximumQueryUTF8Bytes,
              let scope = searchScope(for: request)
        else { throw RemoteUniversalSearchError.invalidRequest }

        let query: SearchQuery
        switch SearchQueryParser.parse(
            request.query,
            scope: scope,
            generation: request.generation
        ) {
        case .failure:
            throw RemoteUniversalSearchError.invalidRequest
        case let .success(parsed):
            query = parsed
        }

        let now = Date()
        reapTokens(now: now)
        if let currentGeneration = generationByDevice[deviceID]?.value,
           request.generation < currentGeneration
        {
            throw CancellationError()
        }

        let projects = WorkspaceFileSearchProjection.projects(projectStore.projects)
        let coordinator = UniversalSearchCoordinator(providers: [
            navigationIndex.provider(),
            transcriptIndex.provider(),
            WorkspaceMetadataSearchProvider(records: workspaceMetadata()),
            WorkspaceFileSearchProvider(projects: projects, index: workspaceFileIndex),
            ProjectTextSearchProvider(projects: projects),
        ])
        let queryID = UUID()
        let previous = activeQueryByDevice.updateValue(
            ActiveQuery(
                id: queryID,
                generation: request.generation,
                coordinator: coordinator
            ),
            forKey: deviceID
        )
        generationByDevice[deviceID] = DeviceGeneration(
            value: request.generation,
            expiresAt: now.addingTimeInterval(
                RemoteSearchWireLimits.resultTokenLifetimeSeconds
            )
        )
        tokens = tokens.filter { $0.value.deviceID != deviceID }
        defer {
            if activeQueryByDevice[deviceID]?.id == queryID {
                activeQueryByDevice.removeValue(forKey: deviceID)
            }
        }
        if let previous {
            await previous.coordinator.cancel()
        }
        guard activeQueryByDevice[deviceID]?.id == queryID else {
            await coordinator.cancel()
            throw CancellationError()
        }
        var final = SearchSnapshot(
            queryGeneration: request.generation,
            groups: [],
            selectedHitID: nil,
            isComplete: false
        )
        let stream = await coordinator.start(
            query: query,
            clientCapabilities: .remoteIOS
        )
        for await snapshot in stream {
            guard !Task.isCancelled,
                  activeQueryByDevice[deviceID]?.id == queryID
            else {
                await coordinator.cancel()
                throw CancellationError()
            }
            final = snapshot
        }
        guard !Task.isCancelled,
              activeQueryByDevice[deviceID]?.id == queryID
        else {
            throw CancellationError()
        }
        generationByDevice[deviceID] = DeviceGeneration(
            value: request.generation,
            expiresAt: Date().addingTimeInterval(
                RemoteSearchWireLimits.resultTokenLifetimeSeconds
            )
        )
        let response = project(final, deviceID: deviceID)
        trimTokensToCapacity()
        return response
    }

    func resolve(
        token: String,
        deviceID: String
    ) async throws -> RemoteSearchResolutionDTO {
        let now = Date()
        reapTokens(now: now)
        guard let entry = tokens[token],
              entry.deviceID == deviceID,
              entry.expiresAt > now,
              generationByDevice[deviceID]?.value == entry.generation
        else { throw RemoteUniversalSearchError.resultNoLongerAvailable }
        // A token belongs to one successful authority check. A request from another device must
        // not be able to consume it, but a matching request consumes it before any model or file
        // lookup so retries cannot turn an opaque result into a replayable capability.
        tokens.removeValue(forKey: token)

        switch entry.locator {
        case let .project(projectID):
            guard let project = projectStore.project(withID: projectID) else {
                throw RemoteUniversalSearchError.resultNoLongerAvailable
            }
            return RemoteSearchResolutionDTO(
                kind: .project,
                projectID: project.id.uuidString,
                projectName: project.name
            )

        case let .session(projectID, sessionID):
            guard projectStore.project(forSessionID: sessionID)?.id == projectID
            else { throw RemoteUniversalSearchError.resultNoLongerAvailable }
            return RemoteSearchResolutionDTO(kind: .session, sessionID: sessionID.uuidString)

        case let .projectTerminal(projectID, terminalID):
            guard projectStore.homeProject(forTerminalID: terminalID)?.id == projectID
            else { throw RemoteUniversalSearchError.resultNoLongerAvailable }
            return RemoteSearchResolutionDTO(
                kind: .projectTerminal,
                terminalID: terminalID.uuidString
            )

        case let .archivedSession(projectID, sessionID):
            guard let project = projectStore.project(forSessionID: sessionID),
                  project.id == projectID,
                  let session = projectStore.session(withID: sessionID),
                  session.isArchived
            else { throw RemoteUniversalSearchError.resultNoLongerAvailable }
            return RemoteSearchResolutionDTO(
                kind: .archivedSession,
                projectName: project.name,
                sessionID: sessionID.uuidString
            )

        case let .conversation(locator):
            guard let loader = transcriptIndex.conversationWindowLoader(),
                  let project = projectStore.project(forSessionID: locator.sessionID),
                  project.id == locator.projectID,
                  let session = projectStore.session(withID: locator.sessionID)
            else { throw RemoteUniversalSearchError.resultNoLongerAvailable }
            do {
                let window = try await loader.load(
                    centeredOn: locator,
                    radius: (RemoteSearchWireLimits.maximumConversationRows - 1) / 2
                )
                return RemoteSearchResolutionDTO(
                    kind: .conversation,
                    sessionID: locator.sessionID.uuidString,
                    conversation: conversationDTO(
                        window,
                        projectName: project.name,
                        sessionTitle: session.displayTitle
                    )
                )
            } catch {
                throw RemoteUniversalSearchError.resultNoLongerAvailable
            }

        case let .workspaceFile(projectID, _, location):
            guard let project = projectStore.project(withID: projectID) else {
                throw RemoteUniversalSearchError.resultNoLongerAvailable
            }
            do {
                let file: RemoteSearchFileWindowDTO
                if location.line != nil {
                    let window = try await ProjectTextWindowLoader.load(
                        projectID: projectID,
                        root: project.folderURL,
                        location: location
                    )
                    file = RemoteSearchFileWindowDTO(
                        projectName: project.name,
                        relativePath: window.relativePath,
                        lines: window.lines.map { line in
                            RemoteSearchFileLineDTO(
                                number: line.number,
                                text: line.text,
                                match: line.number == window.anchorLine
                                    ? rangeDTO(window.anchorMatch)
                                    : nil
                            )
                        },
                        anchorLine: window.anchorLine,
                        hasEarlier: window.hasEarlier,
                        hasLater: window.hasLater
                    )
                } else {
                    let window = try await WorkspaceFilePreviewLoader.load(
                        projectID: projectID,
                        root: project.folderURL,
                        relativePath: location.relativePath
                    )
                    file = RemoteSearchFileWindowDTO(
                        projectName: project.name,
                        relativePath: window.relativePath,
                        lines: window.lines.map {
                            RemoteSearchFileLineDTO(number: $0.number, text: $0.text)
                        },
                        hasEarlier: false,
                        hasLater: window.hasLater
                    )
                }
                return RemoteSearchResolutionDTO(kind: .file, file: file)
            } catch {
                throw RemoteUniversalSearchError.resultNoLongerAvailable
            }

        case let .attachment(projectID, sessionID, attachmentID):
            guard projectStore.project(forSessionID: sessionID)?.id == projectID,
                  workspaceMetadata().contains(where: { record in
                      record.projectID == projectID
                          && record.sessionID == sessionID
                          && record.destination == .attachment(attachmentID)
                  })
            else {
                throw RemoteUniversalSearchError.resultNoLongerAvailable
            }
            return RemoteSearchResolutionDTO(
                kind: .attachment,
                sessionID: sessionID.uuidString,
                attachmentID: attachmentID.rawValue
            )

        case let .browserTab(projectID, sessionID, tabID):
            guard let projectID, let sessionID,
                  projectStore.project(forSessionID: sessionID)?.id == projectID,
                  workspaceMetadata().contains(where: { record in
                      record.projectID == projectID
                          && record.sessionID == sessionID
                          && record.destination == .browserTab(tabID)
                  })
            else {
                throw RemoteUniversalSearchError.resultNoLongerAvailable
            }
            return RemoteSearchResolutionDTO(
                kind: .browserTab,
                sessionID: sessionID.uuidString,
                browserTabID: tabID.rawValue
            )

        case .command, .setting, .gitReview:
            throw RemoteUniversalSearchError.unavailable
        }
    }

    private func searchScope(for request: RemoteSearchRequestDTO) -> SearchScope? {
        switch request.scope {
        case .everywhere:
            guard request.projectID == nil, request.projectName == nil,
                  request.sessionID == nil else { return nil }
            return .everywhere
        case .project:
            guard request.sessionID == nil else { return nil }
            if let rawID = request.projectID,
               let projectID = ProjectID(uuidString: rawID),
               let project = projectStore.project(withID: projectID),
               request.projectName == nil || request.projectName == project.name
            {
                return .project(project.id)
            }
            guard request.projectID == nil, let name = request.projectName else { return nil }
            let matches = projectStore.projects.filter { $0.name == name }
            guard matches.count == 1, let project = matches.first else { return nil }
            return .project(project.id)
        case .session:
            guard request.projectID == nil, request.projectName == nil,
                  let rawID = request.sessionID,
                  let sessionID = SessionID(uuidString: rawID),
                  let project = projectStore.project(forSessionID: sessionID)
            else { return nil }
            return .view(.conversation(projectID: project.id, sessionID: sessionID))
        }
    }

    private func project(
        _ snapshot: SearchSnapshot,
        deviceID: String
    ) -> RemoteSearchResponseDTO {
        let expiresAt = Date().addingTimeInterval(
            RemoteSearchWireLimits.resultTokenLifetimeSeconds
        )
        var ordinal = 0
        var remainingHits = RemoteSearchWireLimits.maximumVisibleHits
        let groups = snapshot.groups.prefix(RemoteSearchWireLimits.maximumGroups).map { group in
            let groupLimit = min(
                RemoteSearchWireLimits.maximumHitsPerGroup,
                remainingHits
            )
            let projectedHits = group.hits.prefix(groupLimit)
            remainingHits -= projectedHits.count
            let hits = projectedHits.map { hit in
                ordinal += 1
                let token = freshToken()
                tokens[token] = TokenEntry(
                    deviceID: deviceID,
                    generation: snapshot.queryGeneration,
                    expiresAt: expiresAt,
                    sequence: nextTokenSequence,
                    locator: hit.locator
                )
                nextTokenSequence &+= 1
                return RemoteSearchHitDTO(
                    id: "result-\(ordinal)",
                    token: token,
                    group: groupDTO(group.group),
                    kind: kindDTO(hit.kind),
                    title: bounded(hit.title, bytes: RemoteSearchWireLimits.maximumTitleUTF8Bytes),
                    snippet: hit.snippet.map { snippet in
                        let text = bounded(
                            snippet.text,
                            bytes: RemoteSearchWireLimits.maximumSnippetUTF8Bytes
                        )
                        return RemoteSearchSnippetDTO(
                            text: text,
                            matches: snippet.matches.compactMap {
                                validRangeDTO($0, utf16Count: (text as NSString).length)
                            }
                        )
                    },
                    provenance: RemoteSearchProvenanceDTO(
                        projectName: bounded(hit.provenance.projectName),
                        sessionTitle: bounded(hit.provenance.sessionTitle),
                        provider: bounded(hit.provenance.provider),
                        author: hit.provenance.author.map(authorName),
                        branch: bounded(hit.provenance.branch),
                        relativePath: bounded(hit.provenance.relativePath),
                        timestamp: hit.provenance.timestamp?.timeIntervalSince1970,
                        isArchived: hit.provenance.isArchived
                    )
                )
            }
            return RemoteSearchGroupResultDTO(
                group: groupDTO(group.group),
                hits: hits,
                coverage: group.providers.map { coverageDTO($0.coverage) },
                isCapped: group.isCapped || group.hits.count > hits.count
            )
        }
        return RemoteSearchResponseDTO(
            generation: snapshot.queryGeneration,
            groups: groups,
            isComplete: snapshot.isComplete
        )
    }

    private func conversationDTO(
        _ window: ConversationWindow,
        projectName: String,
        sessionTitle: String
    ) -> RemoteSearchConversationWindowDTO {
        let rows = Array(window.rows.prefix(RemoteSearchWireLimits.maximumConversationRows))
        let anchorIndex = rows.firstIndex(where: { $0.id == window.anchorRowID }) ?? 0
        let projectedRows = rows.enumerated().map { index, row in
            RemoteSearchConversationRowDTO(
                id: "row-\(index)",
                kind: kindDTO(row.kind).rawValue,
                author: row.author.map(authorName),
                title: row.title.isEmpty ? nil : bounded(
                    row.title,
                    bytes: RemoteSearchWireLimits.maximumTitleUTF8Bytes
                ),
                body: bounded(row.body, bytes: RemoteSearchWireLimits.maximumSnippetUTF8Bytes),
                timestamp: row.timestamp?.timeIntervalSince1970,
                isError: row.hasError
            )
        }
        let anchorBodyLength = projectedRows.indices.contains(anchorIndex)
            ? (projectedRows[anchorIndex].body as NSString).length
            : 0
        return RemoteSearchConversationWindowDTO(
            sessionID: window.sessionID.uuidString,
            sessionTitle: bounded(
                sessionTitle,
                bytes: RemoteSearchWireLimits.maximumTitleUTF8Bytes
            ),
            projectName: bounded(projectName, bytes: RemoteSearchWireLimits.maximumTitleUTF8Bytes),
            rows: projectedRows,
            anchorRowID: "row-\(anchorIndex)",
            anchorMatch: window.anchorMatch.flatMap {
                validRangeDTO($0, utf16Count: anchorBodyLength)
            },
            hasEarlier: window.hasEarlier,
            hasLater: window.hasLater
        )
    }

    private func reapTokens(now: Date) {
        tokens = tokens.filter { $0.value.expiresAt > now }
        generationByDevice = generationByDevice.filter {
            $0.value.expiresAt > now || activeQueryByDevice[$0.key] != nil
        }
    }

    private func trimTokensToCapacity() {
        let overflow = tokens.count - maximumRetainedTokens
        guard overflow > 0 else { return }
        let oldest = tokens.sorted {
            if $0.value.sequence != $1.value.sequence {
                return $0.value.sequence < $1.value.sequence
            }
            return $0.key < $1.key
        }.prefix(overflow)
        for (token, _) in oldest {
            tokens.removeValue(forKey: token)
        }
    }

    private func freshToken() -> String {
        var token = UUID().uuidString.lowercased()
        while tokens[token] != nil {
            token = UUID().uuidString.lowercased()
        }
        return token
    }

    private func bounded(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        var result = ""
        for character in value {
            if result.utf8.count + String(character).utf8.count > bytes - 3 { break }
            result.append(character)
        }
        return result + "…"
    }

    private func bounded(_ value: String?) -> String? {
        value.map { bounded($0, bytes: RemoteSearchWireLimits.maximumTitleUTF8Bytes) }
    }

    private func groupDTO(_ group: SearchResultGroup) -> RemoteSearchGroupDTO {
        switch group {
        case .destinations: return .destinations
        case .currentView: return .currentView
        case .conversations: return .conversations
        case .files: return .files
        case .settings: return .settings
        case .archived: return .archived
        }
    }

    private func kindDTO(_ kind: SearchHitKind) -> RemoteSearchHitKindDTO {
        switch kind {
        case .project: return .project
        case .session: return .session
        case .projectTerminal: return .projectTerminal
        case .conversationMessage: return .conversationMessage
        case .toolSummary: return .toolSummary
        case .file: return .file
        case .projectText: return .projectText
        case .command: return .command
        case .setting: return .setting
        case .archivedSession: return .archivedSession
        case .attachment: return .attachment
        case .browserTab: return .browserTab
        case .gitReview: return .gitReview
        }
    }

    private func authorName(_ author: SearchAuthor) -> String {
        switch author {
        case .you: return "you"
        case .agent: return "agent"
        case .system: return "system"
        }
    }

    private func coverageDTO(_ coverage: SearchCoverage) -> RemoteSearchCoverageDTO {
        switch coverage {
        case .complete:
            return RemoteSearchCoverageDTO(kind: .complete)
        case let .partial(reason):
            return RemoteSearchCoverageDTO(kind: .partial, detail: reason)
        case let .indexing(indexed, total):
            return RemoteSearchCoverageDTO(kind: .indexing, indexed: indexed, total: total)
        case let .unavailable(reason):
            return RemoteSearchCoverageDTO(kind: .unavailable, detail: reason)
        }
    }

    private func rangeDTO(_ range: SearchTextRange) -> RemoteSearchTextRangeDTO {
        RemoteSearchTextRangeDTO(
            utf16Location: range.utf16Location,
            utf16Length: range.utf16Length
        )
    }

    private func validRangeDTO(
        _ range: SearchTextRange,
        utf16Count: Int
    ) -> RemoteSearchTextRangeDTO? {
        guard range.isValid,
              range.utf16Location <= utf16Count,
              range.utf16Length <= utf16Count - range.utf16Location
        else { return nil }
        return rangeDTO(range)
    }
}
