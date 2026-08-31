import Foundation

struct WorkspaceFilePreviewLine: Hashable, Sendable {
    let number: Int
    let text: String
}

struct WorkspaceFilePreview: Hashable, Sendable {
    let projectID: ProjectID
    let relativePath: String
    let lines: [WorkspaceFilePreviewLine]
    let hasLater: Bool
}

enum WorkspaceFilePreviewLoadError: Error, Equatable, Sendable {
    case resultNoLongerAvailable
    case sourceUnavailable
}

/// Loads a small read-only head for a file-name result. It applies the same path containment,
/// regular-file, size and UTF-8 gates as exact project-text activation; no absolute path leaves
/// this loader and binary/oversized content stays unavailable.
enum WorkspaceFilePreviewLoader {
    private enum Limits {
        static let maximumFileBytes = 4 * 1024 * 1024
        static let maximumLines = 41
        static let maximumPresentedLineUTF8Bytes = 2048
    }

    static func load(
        projectID: ProjectID,
        root: URL,
        relativePath: String
    ) async throws -> WorkspaceFilePreview {
        try await Task.detached(priority: .userInitiated) {
            try loadSynchronously(
                projectID: projectID,
                root: root,
                relativePath: relativePath
            )
        }.value
    }

    private static func loadSynchronously(
        projectID: ProjectID,
        root: URL,
        relativePath: String
    ) throws -> WorkspaceFilePreview {
        guard let file = containedFile(root: root, relativePath: relativePath) else {
            throw WorkspaceFilePreviewLoadError.resultNoLongerAvailable
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= Limits.maximumFileBytes
        else {
            throw WorkspaceFilePreviewLoadError.sourceUnavailable
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !Task.isCancelled, let source = String(data: data, encoding: .utf8) else {
            throw WorkspaceFilePreviewLoadError.sourceUnavailable
        }
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let selected = sourceLines.prefix(Limits.maximumLines)
        let lines = selected.enumerated().map { index, sourceLine in
            var line = String(sourceLine)
            if line.last == "\r" { line.removeLast() }
            return WorkspaceFilePreviewLine(
                number: index + 1,
                text: boundedPrefix(line, maximumUTF8Bytes: Limits.maximumPresentedLineUTF8Bytes)
            )
        }
        return WorkspaceFilePreview(
            projectID: projectID,
            relativePath: relativePath,
            lines: lines,
            hasLater: sourceLines.count > selected.count
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

    private static func boundedPrefix(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        for character in value {
            if result.utf8.count + String(character).utf8.count > maximumUTF8Bytes - 3 { break }
            result.append(character)
        }
        return result + "…"
    }
}
