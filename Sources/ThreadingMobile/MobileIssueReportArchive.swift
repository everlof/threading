import Foundation
import ThreadingRemoteKit

/// Packages the files reviewed in Report a Problem into the one attachment handed to iOS.
enum MobileIssueReportArchive {
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
        let archiveURL = outputDirectory.appendingPathComponent(archiveFileName(for: modified))
        try data.write(to: archiveURL, options: .atomic)
        return archiveURL
    }

    /// The moment the report was made, in the name of the file that carries it.
    ///
    /// Every share used to hand iOS the same `threading-report.zip`, so a person saving a second
    /// one was asked which copy to keep and ended up with `threading-report 2.zip` beside a
    /// report they could no longer tell apart. The stamp sorts, reads as a date, and makes two
    /// reports from the same phone distinguishable without opening either.
    static func archiveFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        // Pinned, or the filename inherits the user's numerals and calendar — a Buddhist-era
        // year is a valid path and a wrong name.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = archiveStampFormat
        return "threading-report-\(formatter.string(from: date)).zip"
    }

    private static let archiveStampFormat = "yyyyMMdd-HHmmss"

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
