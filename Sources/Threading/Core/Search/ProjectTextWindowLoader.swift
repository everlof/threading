import Foundation

struct ProjectTextWindowLine: Hashable, Sendable {
    let number: Int
    let text: String
}

struct ProjectTextWindow: Hashable, Sendable {
    let projectID: ProjectID
    let relativePath: String
    let lines: [ProjectTextWindowLine]
    let anchorLine: Int
    let anchorMatch: SearchTextRange
    let hasEarlier: Bool
    let hasLater: Bool
}

enum ProjectTextWindowLoadError: Error, Equatable, Sendable {
    case resultNoLongerAvailable
    case sourceUnavailable
}

/// Revalidates and reads one small source window after a project-text result is chosen. Search
/// locators never authorize arbitrary paths: containment, file type, size, line fingerprint and
/// matched range are all checked again at activation time.
enum ProjectTextWindowLoader {
    private enum Limits {
        static let maximumFileBytes = 4 * 1024 * 1024
        static let contextLines = 5
        static let maximumPresentedLineUTF8Bytes = 2048
    }

    static func load(
        projectID: ProjectID,
        root: URL,
        location: SearchFileLocation
    ) async throws -> ProjectTextWindow {
        try await Task.detached(priority: .userInitiated) {
            try loadSynchronously(projectID: projectID, root: root, location: location)
        }.value
    }

    private static func loadSynchronously(
        projectID: ProjectID,
        root: URL,
        location: SearchFileLocation
    ) throws -> ProjectTextWindow {
        guard let requestedLine = location.line,
              let requestedColumn = location.column,
              let matchLength = location.matchLength,
              let fingerprint = location.lineFingerprint,
              requestedLine > 0, requestedColumn > 0, matchLength > 0,
              let file = containedFile(root: root, relativePath: location.relativePath)
        else {
            throw ProjectTextWindowLoadError.resultNoLongerAvailable
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= Limits.maximumFileBytes
        else {
            throw ProjectTextWindowLoadError.sourceUnavailable
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !Task.isCancelled, let source = String(data: data, encoding: .utf8) else {
            throw ProjectTextWindowLoadError.sourceUnavailable
        }
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
            var line = String($0)
            if line.last == "\r" { line.removeLast() }
            return line
        }
        let anchorIndex = requestedLine - 1
        guard sourceLines.indices.contains(anchorIndex),
              SearchSourceFingerprint.text(sourceLines[anchorIndex]) == fingerprint
        else {
            throw ProjectTextWindowLoadError.resultNoLongerAvailable
        }
        let anchor = sourceLines[anchorIndex] as NSString
        let sourceMatch = NSRange(location: requestedColumn - 1, length: matchLength)
        guard NSMaxRange(sourceMatch) <= anchor.length else {
            throw ProjectTextWindowLoadError.resultNoLongerAvailable
        }

        let lower = max(0, anchorIndex - Limits.contextLines)
        let upper = min(sourceLines.count, anchorIndex + Limits.contextLines + 1)
        var translatedAnchorMatch: SearchTextRange?
        let lines = (lower ..< upper).map { index -> ProjectTextWindowLine in
            let bounded = boundedLine(
                sourceLines[index],
                around: index == anchorIndex ? sourceMatch : nil
            )
            if index == anchorIndex { translatedAnchorMatch = bounded.match }
            return ProjectTextWindowLine(number: index + 1, text: bounded.text)
        }
        guard let translatedAnchorMatch else {
            throw ProjectTextWindowLoadError.resultNoLongerAvailable
        }
        return ProjectTextWindow(
            projectID: projectID,
            relativePath: location.relativePath,
            lines: lines,
            anchorLine: requestedLine,
            anchorMatch: translatedAnchorMatch,
            hasEarlier: lower > 0,
            hasLater: upper < sourceLines.count
        )
    }

    private static func containedFile(root: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              relativePath.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = resolvedRoot.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        return file.path.hasPrefix(prefix) ? file : nil
    }

    private static func boundedLine(
        _ value: String,
        around match: NSRange?
    ) -> (text: String, match: SearchTextRange?) {
        let source = value as NSString
        let maximumUTF16 = Limits.maximumPresentedLineUTF8Bytes / 4
        guard source.length > maximumUTF16 else {
            return (
                value,
                match.map {
                    SearchTextRange(utf16Location: $0.location, utf16Length: $0.length)
                }
            )
        }
        let start: Int
        if let match {
            start = min(
                max(match.location - maximumUTF16 / 3, 0),
                max(source.length - maximumUTF16, 0)
            )
        } else {
            start = 0
        }
        let length = min(maximumUTF16, source.length - start)
        let prefix = start > 0 ? "…" : ""
        let suffix = start + length < source.length ? "…" : ""
        return (
            prefix + source.substring(with: NSRange(location: start, length: length)) + suffix,
            match.map {
                SearchTextRange(
                    utf16Location: (prefix as NSString).length + $0.location - start,
                    utf16Length: $0.length
                )
            }
        )
    }
}
