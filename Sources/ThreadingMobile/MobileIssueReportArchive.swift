import Foundation
import ThreadingRemoteKit

/// Packages the files reviewed in Report a Problem into the one attachment handed to iOS.
enum MobileIssueReportArchive {
    static let archiveFileName = "threading-report.zip"
    static let diagnosticsFileName = "diagnostics.json"
    static let reporterNoteFileName = "description.txt"
    static let screenshotFileName = "screenshot.png"

    static func write(
        diagnosticsURL: URL,
        reporterNoteURL: URL?,
        screenshotURL: URL?,
        modified: Date = Date(),
        outputDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let data = try ZipArchiveWriter.archive(
            entries(
                diagnosticsURL: diagnosticsURL,
                reporterNoteURL: reporterNoteURL,
                screenshotURL: screenshotURL
            ),
            modified: modified
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let archiveURL = outputDirectory.appendingPathComponent(archiveFileName)
        try data.write(to: archiveURL, options: .atomic)
        return archiveURL
    }

    static func entries(
        diagnosticsURL: URL,
        reporterNoteURL: URL?,
        screenshotURL: URL?
    ) throws -> [ZipArchiveWriter.Entry] {
        var entries = [
            try entry(named: diagnosticsFileName, from: diagnosticsURL),
        ]
        if let reporterNoteURL {
            entries.append(try entry(named: reporterNoteFileName, from: reporterNoteURL))
        }
        if let screenshotURL {
            entries.append(try entry(named: screenshotFileName, from: screenshotURL))
        }
        return entries
    }

    private static func entry(named name: String, from url: URL) throws -> ZipArchiveWriter.Entry {
        ZipArchiveWriter.Entry(path: name, data: try Data(contentsOf: url))
    }
}
