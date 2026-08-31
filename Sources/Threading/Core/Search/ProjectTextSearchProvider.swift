import Foundation

struct ProjectTextSearchMatch: Equatable, Sendable {
    let relativePath: String
    let line: Int
    let text: String
}

struct ProjectTextSearchPage: Equatable, Sendable {
    let matches: [ProjectTextSearchMatch]
    let isCapped: Bool
}

enum ProjectTextSearchFailure: Error, Equatable, Sendable {
    case unavailable
    case cancelled
}

/// Explicit, checkout-scoped source search. It deliberately does not join Everywhere: selecting
/// Project is the user's admission for filesystem text work, and each new query cancels the Git
/// process started by the previous generation.
final class ProjectTextSearchProvider: UniversalSearchProvider, @unchecked Sendable {
    typealias Runner = @Sendable (
        _ project: WorkspaceFileSearchProject,
        _ literal: String
    ) async -> Result<ProjectTextSearchPage, ProjectTextSearchFailure>

    private enum Limits {
        static let minimumTermCharacters = 3
        static let maximumMatchesPerFile = 3
        static let maximumGitOutputBytes = 4 * 1024 * 1024
        static let maximumSearchSeconds: TimeInterval = 5
        static let maximumOpenableFileBytes: UInt64 = 4 * 1024 * 1024
    }

    let id: SearchProviderID = .projectText
    private let projects: [WorkspaceFileSearchProject]
    private let runner: Runner

    init(
        projects: [WorkspaceFileSearchProject],
        runner: @escaping Runner = { project, literal in
            await ProjectTextSearchProvider.runTrackedSearch(
                project: project,
                literal: literal
            )
        }
    ) {
        self.projects = projects
        self.runner = runner
    }

    func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
        let pair = AsyncStream<SearchBatch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task(priority: .userInitiated) { [projects, runner, id] in
            guard case let .project(projectID) = request.query.scope,
                  let project = projects.first(where: { $0.projectID == projectID }),
                  Self.filtersPermitProjectText(request.query.expression.filters)
            else {
                pair.continuation.yield(Self.batch(
                    id: id,
                    query: request.query,
                    hits: [],
                    coverage: .complete,
                    isCapped: false
                ))
                pair.continuation.finish()
                return
            }

            let terms = request.query.expression.positiveTerms.map(\.text)
            guard let literal = terms.max(by: { $0.count < $1.count }),
                  literal.count >= Limits.minimumTermCharacters
            else {
                pair.continuation.yield(Self.batch(
                    id: id,
                    query: request.query,
                    hits: [],
                    coverage: .partial(reason: L10n.string(
                        "Type at least 3 characters to search project text."
                    )),
                    isCapped: false
                ))
                pair.continuation.finish()
                return
            }

            let result = await runner(project, literal)
            guard !Task.isCancelled else {
                pair.continuation.finish()
                return
            }
            switch result {
            case .failure(.cancelled):
                break
            case .failure(.unavailable):
                pair.continuation.yield(Self.batch(
                    id: id,
                    query: request.query,
                    hits: [],
                    coverage: .unavailable(reason: L10n.string(
                        "Project text search is unavailable."
                    )),
                    isCapped: false
                ))
            case let .success(page):
                let hits = page.matches.compactMap {
                    Self.hit(match: $0, project: project, query: request.query)
                }
                pair.continuation.yield(Self.batch(
                    id: id,
                    query: request.query,
                    hits: hits,
                    // `git grep` is intentionally the tracked corpus. Untracked files remain in
                    // path search, but pretending they were searched here would overstate scope.
                    coverage: .partial(reason: L10n.string(
                        "Project text search covers tracked files."
                    )),
                    isCapped: page.isCapped
                ))
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    private static func batch(
        id: SearchProviderID,
        query: SearchQuery,
        hits: [SearchHit],
        coverage: SearchCoverage,
        isCapped: Bool
    ) -> SearchBatch {
        SearchBatch(
            queryGeneration: query.generation,
            provider: id,
            group: .files,
            hits: hits,
            coverage: coverage,
            continuation: nil,
            isCapped: isCapped
        )
    }

    private static func filtersPermitProjectText(_ filters: [SearchFilter]) -> Bool {
        filters.allSatisfy { filter in
            let matches: Bool
            switch filter.predicate {
            case let .kind(kind): matches = kind == .file
            case .project: matches = true
            case let .provider(value):
                matches = normalized("Project text").contains(normalized(value))
                    || normalized(L10n.string("Project text")).contains(normalized(value))
            case .author, .archived, .error, .before, .after: matches = false
            }
            return filter.isExcluded ? !matches : matches
        }
    }

    private static func hit(
        match: ProjectTextSearchMatch,
        project: WorkspaceFileSearchProject,
        query: SearchQuery
    ) -> SearchHit? {
        guard match.line > 0,
              safeOpenableFile(match.relativePath, root: project.root),
              expressionMatches(match.text, expression: query.expression) else { return nil }

        let terms = query.expression.positiveTerms.map(\.text)
        guard let first = firstMatch(in: match.text, terms: terms) else { return nil }
        let snippet = boundedSnippet(match.text, around: first)
        let name = (match.relativePath as NSString).lastPathComponent
        let hitID = SearchHitID(
            rawValue: "project-text:\(project.projectID.uuidString):\(match.relativePath):\(match.line):\(first.location)"
        )
        return SearchHit(
            id: hitID,
            provider: .projectText,
            kind: .projectText,
            title: "\(name):\(match.line)",
            snippet: snippet,
            provenance: SearchProvenance(
                projectID: project.projectID,
                projectName: project.projectName,
                provider: L10n.string("Project text"),
                relativePath: match.relativePath,
                timestamp: project.updatedAt
            ),
            stableOrder: SearchStableOrder(
                group: .files,
                scoreTier: .literalText,
                recency: project.updatedAt,
                title: "\(match.relativePath):\(match.line)",
                stableID: hitID
            ),
            locator: .workspaceFile(
                projectID: project.projectID,
                sessionID: nil,
                location: SearchFileLocation(
                    relativePath: match.relativePath,
                    line: match.line,
                    column: first.location + 1,
                    matchLength: first.length,
                    lineFingerprint: SearchSourceFingerprint.text(match.text)
                )
            )
        )
    }

    private static func expressionMatches(
        _ value: String,
        expression: SearchExpression
    ) -> Bool {
        let folded = normalized(value)
        return expression.positiveTerms.allSatisfy { folded.contains(normalized($0.text)) }
            && expression.excludedTerms.allSatisfy { !folded.contains(normalized($0.text)) }
    }

    private static func firstMatch(in value: String, terms: [String]) -> NSRange? {
        let source = value as NSString
        let options: NSString.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]
        return terms.compactMap {
            let range = source.range(
                of: $0,
                options: options,
                range: NSRange(location: 0, length: source.length)
            )
            return range.location == NSNotFound ? nil : range
        }.min { $0.location < $1.location }
    }

    private static func boundedSnippet(_ value: String, around match: NSRange) -> SearchSnippet {
        let source = value as NSString
        let maximum = UniversalSearchDefaults.maximumSnippetUTF8Bytes / 4
        let start = min(max(match.location - maximum / 3, 0), max(source.length - maximum, 0))
        let length = min(maximum, source.length - start)
        let hasPrefix = start > 0
        let hasSuffix = start + length < source.length
        let prefix = hasPrefix ? "…" : ""
        let suffix = hasSuffix ? "…" : ""
        return SearchSnippet(
            text: prefix + source.substring(with: NSRange(location: start, length: length)) + suffix,
            matches: [SearchTextRange(
                utf16Location: (prefix as NSString).length + match.location - start,
                utf16Length: match.length
            )]
        )
    }

    private static func safeOpenableFile(_ path: String, root: URL) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = resolvedRoot.appendingPathComponent(path)
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard file.path.hasPrefix(prefix),
              let values = try? file.resourceValues(forKeys: [
                  .isRegularFileKey, .fileSizeKey,
              ]),
              values.isRegularFile == true,
              UInt64(values.fileSize ?? Int.max) <= Limits.maximumOpenableFileBytes
        else {
            return false
        }
        return true
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func runTrackedSearch(
        project: WorkspaceFileSearchProject,
        literal: String
    ) async -> Result<ProjectTextSearchPage, ProjectTextSearchFailure> {
        let cancellation = GitProcessCancellation()
        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .userInitiated) {
                do {
                    let data = try GitProcess.run(
                        GitReviewCommands.common + [
                            "grep", "-n", "-I", "-i", "-z", "--no-color", "--full-name",
                            "-F", "-m", String(Limits.maximumMatchesPerFile + 1),
                            "-e", literal, "--",
                        ],
                        in: project.root,
                        maximumOutput: Limits.maximumGitOutputBytes,
                        acceptedExitCodes: [0, 1],
                        timeout: Limits.maximumSearchSeconds,
                        cancellation: cancellation
                    )
                    guard !Task.isCancelled else { return .failure(.cancelled) }
                    return .success(boundedPage(from: parseGitGrep(data)))
                } catch GitFailure.cancelled {
                    return .failure(.cancelled)
                } catch {
                    return .failure(.unavailable)
                }
            }.value
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// `git grep -m` reports at most the requested number of matches, so probing one result
    /// beyond the display cap is the only way to distinguish "exactly full" from truncated.
    static func boundedPage(from matches: [ProjectTextSearchMatch]) -> ProjectTextSearchPage {
        var retained: [ProjectTextSearchMatch] = []
        var countsByPath: [String: Int] = [:]
        var cappedByFile = false

        for match in matches {
            let count = countsByPath[match.relativePath, default: 0]
            countsByPath[match.relativePath] = count + 1
            if count < Limits.maximumMatchesPerFile {
                retained.append(match)
            } else {
                cappedByFile = true
            }
        }

        let cappedByGroup = retained.count > UniversalSearchDefaults.maximumHitsPerGroup
        return ProjectTextSearchPage(
            matches: Array(retained.prefix(UniversalSearchDefaults.maximumHitsPerGroup)),
            isCapped: cappedByFile || cappedByGroup
        )
    }

    /// `git grep -n -z` emits `path NUL line NUL content LF`; paths may contain colons or
    /// newlines, so the two NUL boundaries are the authority and display text is never reparsed.
    private static func parseGitGrep(_ data: Data) -> [ProjectTextSearchMatch] {
        var matches: [ProjectTextSearchMatch] = []
        var cursor = data.startIndex
        while cursor < data.endIndex,
              let pathEnd = data[cursor...].firstIndex(of: 0)
        {
            let lineStart = data.index(after: pathEnd)
            guard let lineEnd = data[lineStart...].firstIndex(of: 0) else { break }
            let textStart = data.index(after: lineEnd)
            let textEnd = data[textStart...].firstIndex(of: 10) ?? data.endIndex
            guard let path = String(data: data[cursor ..< pathEnd], encoding: .utf8),
                  let lineText = String(data: data[lineStart ..< lineEnd], encoding: .utf8),
                  let line = Int(lineText),
                  let text = String(data: data[textStart ..< textEnd], encoding: .utf8)
            else {
                cursor = textEnd < data.endIndex ? data.index(after: textEnd) : data.endIndex
                continue
            }
            matches.append(ProjectTextSearchMatch(
                relativePath: path,
                line: line,
                text: text
            ))
            cursor = textEnd < data.endIndex ? data.index(after: textEnd) : data.endIndex
        }
        return matches
    }
}
