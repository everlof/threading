import Foundation

/// The exported document: one self-contained HTML page carrying the comparison.
///
/// It is written by hand rather than by rendering the AppKit surface to a picture, because a
/// picture of a comparison is not a comparison — the recipient has to be able to drag the seam,
/// hold the fade at the middle, and ask difference whether anything moved at all. So the page
/// reproduces `ImageCompareLayout`'s rules in CSS: one shared scale for both sides, each centred
/// in the fitted canvas, captions in bands beside the pixels rather than over them.
///
/// **Nothing loads from the network.** No font, no script, no stylesheet: an export that needs a
/// CDN is an export that stops working the day it is opened on a plane, and it would tell a
/// third party every time the recipient looked at it.
enum CompareExportPage {

    /// Where the images in the document come from.
    enum Assets {
        /// `data:` URIs, so the page is the whole export. Costs base64's third on every byte.
        case inline
        /// Relative paths into the archive's `old/` and `new/` folders.
        case files
    }

    // MARK: - Public Methods

    /// Builds the document.
    ///
    /// Returns `Data` rather than `String` on purpose: an inlined pair can be two 64 MB images,
    /// and base64 goes straight from `Data` to `Data` without ever standing up an 85 MB `String`
    /// beside it.
    static func document(for export: CompareExport, assets: Assets) -> Data {
        var page = HTMLBuffer()
        let title = "\(export.oldTitle) → \(export.newTitle)"

        page += """
            <!doctype html>
            <html lang="\(language)" data-mode="\(export.mode.rawValue)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="\(AppInfo.name)">
            <title>\(title.htmlEscaped)</title>
            <style>
            \(Style.sheet)
            </style>
            </head>
            <body>
            <header class="head">
            <h1>\(export.oldTitle.htmlEscaped)<span class="arrow"> → </span>\
            \(export.newTitle.htmlEscaped)</h1>
            <p class="meta">\(meta(for: export).htmlEscaped)</p>
            </header>
            <main>

            """

        switch export.body {
        case .images(let old, let new):
            appendStage(&page, old: old, new: new, export: export, assets: assets)
        case .text(let files, _, _):
            appendDiff(&page, files: files)
        }

        page += """

            </main>
            <footer class="foot">\(footer.htmlEscaped)</footer>
            <script>
            \(Script.source)
            </script>
            </body>
            </html>

            """
        return page.data
    }

    // MARK: - Private Methods — Images

    /// The interactive surface: the mode buttons, the caption bands, and the two frames.
    private static func appendStage(
        _ page: inout HTMLBuffer,
        old: CompareExport.ImageSide?,
        new: CompareExport.ImageSide?,
        export: CompareExport,
        assets: Assets
    ) {
        guard old != nil || new != nil else {
            page += "<p class=\"note\">\(L10n.string("Neither image could be read.").htmlEscaped)</p>"
            return
        }

        // Both sides at one scale, exactly as the app fits them: the union of the two pixel
        // sizes is the canvas, and each image takes its own fraction of it. A per-image fit
        // would normalise a resized asset into "looks identical", which is the one lie an image
        // comparison must not tell.
        let union = CGSize(
            width: max(old?.pixelSize.width ?? 0, new?.pixelSize.width ?? 0),
            height: max(old?.pixelSize.height ?? 0, new?.pixelSize.height ?? 0)
        )
        let hasPair = old != nil && new != nil

        if hasPair {
            page += "<div class=\"modes\" role=\"group\">\n"
            for mode in ImageCompareMode.allCases {
                let pressed = mode == export.mode ? "true" : "false"
                page += """
                    <button type="button" class="mode" data-mode="\(mode.rawValue)" \
                    aria-pressed="\(pressed)">\(mode.title.htmlEscaped)</button>

                    """
            }
            page += "</div>\n"
        }

        page += """
            <div class="stage" style="--union-width: \(number(union.width)); \
            --union-height: \(number(union.height))">
            <div class="captions top">
            <span class="old">\((old?.title ?? "").htmlEscaped)</span>
            <span class="join"> → </span>
            <span class="new">\((new?.title ?? "").htmlEscaped)</span>
            </div>
            <div class="canvas\(hasPair ? "" : " single")">

            """

        if let old {
            appendFrame(&page, side: old, union: union, isOld: true, assets: assets)
        }
        if let new {
            appendFrame(&page, side: new, union: union, isOld: false, assets: assets)
        }

        page += """
            <div class="seam" aria-hidden="true"><span class="handle"></span></div>
            </div>
            <div class="captions bottom">
            <span class="old">\((old?.title ?? "").htmlEscaped)</span>
            <span class="new">\((new?.title ?? "").htmlEscaped)</span>
            </div>
            </div>

            """

        if hasPair {
            page += "<p class=\"hint\">\(Self.hint.htmlEscaped)</p>\n"
        }
    }

    /// One side's frame, sized to its share of the union so both draw at one scale.
    private static func appendFrame(
        _ page: inout HTMLBuffer,
        side: CompareExport.ImageSide,
        union: CGSize,
        isOld: Bool,
        assets: Assets
    ) {
        let widthShare = union.width > 0 ? side.pixelSize.width / union.width * 100 : 100
        let heightShare = union.height > 0 ? side.pixelSize.height / union.height * 100 : 100
        page += """
            <div class="frame \(isOld ? "old" : "new")" \
            style="--image-width: \(number(widthShare))%; --image-height: \(number(heightShare))%">
            <img alt="\(side.title.htmlEscaped)" src="
            """
        switch assets {
        case .inline:
            page += "data:\(side.mediaType);base64,"
            page.append(side.data.base64EncodedData())
        case .files:
            page += CompareExportPackager.path(for: side.fileName, isOld: isOld).htmlEscaped
        }
        page += "\">\n</div>\n"
    }

    // MARK: - Private Methods — Text

    /// The text comparison: the same unified hunks the tab draws, as a table per hunk.
    private static func appendDiff(_ page: inout HTMLBuffer, files: [GitFileDiff]) {
        page += "<div class=\"diff\">\n"
        for file in files {
            // The *name*, never the path. `git diff --no-index` reports where the file was on
            // this machine, and an exported page is read on someone else's: the header would
            // otherwise tell every recipient the sender's home directory and folder layout,
            // which is not part of the comparison anybody asked to see.
            page += """
                <section class="file">
                <div class="file-head"><span class="path">\(file.fileName.htmlEscaped)</span>\
                <span class="counts"><span class="plus">+\(file.added)</span> \
                <span class="minus">−\(file.removed)</span></span></div>

                """
            var remaining = CompareExportDefaults.maximumDiffLines
            for hunk in file.hunks {
                page += """
                    <div class="hunk">
                    <div class="hunk-head">\(hunk.header.htmlEscaped)</div>
                    <table>

                    """
                for line in hunk.lines.prefix(remaining) {
                    page += row(for: line)
                }
                let shown = min(hunk.lines.count, remaining)
                remaining -= shown
                page += "</table>\n"
                if shown < hunk.lines.count {
                    let dropped = hunk.lines.count - shown
                    page += """
                        <p class="truncated">\
                        \(L10n.format("%lld more lines are not shown.", dropped).htmlEscaped)</p>

                        """
                }
                page += "</div>\n"
                if remaining <= 0 { break }
            }
            page += "</section>\n"
        }
        page += "</div>\n"
    }

    private static func row(for line: GitDiffLine) -> String {
        let kind: String
        let sign: String
        switch line.kind {
        case .added: (kind, sign) = ("added", "+")
        case .removed: (kind, sign) = ("removed", "−")
        case .context: (kind, sign) = ("context", " ")
        }
        let old = line.oldNumber.map(String.init) ?? ""
        let new = line.newNumber.map(String.init) ?? ""
        return """
            <tr class="\(kind)"><td class="num">\(old)</td><td class="num">\(new)</td>\
            <td class="sign">\(sign)</td><td class="code">\(line.text.htmlEscaped)</td></tr>

            """
    }

    // MARK: - Private Methods — Copy

    /// The dimension note, when the two sides disagree — the same thing the surface says, and
    /// the first question anyone asks of a screenshot pair that looks slightly off.
    private static func meta(for export: CompareExport) -> String {
        var parts: [String] = []
        if case .images(let old, let new) = export.body,
           let old, let new, old.pixelSize != new.pixelSize {
            parts.append("\(dimensions(old.pixelSize)) → \(dimensions(new.pixelSize))")
        }
        if case .text(let files, _, _) = export.body {
            let added = files.reduce(0) { $0 + $1.added }
            let removed = files.reduce(0) { $0 + $1.removed }
            parts.append("+\(added) −\(removed)")
        }
        parts.append(dateFormatter.string(from: export.exportedAt))
        return parts.joined(separator: " · ")
    }

    private static var footer: String {
        L10n.format("Exported from %@", AppInfo.name)
    }

    private static var hint: String {
        L10n.string("Drag the seam, or press the arrow keys to move it.")
    }

    private static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    /// A locale-formatted stamp: the export says when it was taken, because a comparison sent to
    /// someone is read later than it is made.
    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    /// The document's language, so a screen reader pronounces the page's own copy correctly.
    private static var language: String {
        L10n.preferredLanguages.first ?? "en"
    }

    /// Formats a CSS number without a locale's decimal comma, which would break the declaration.
    private static func number(_ value: CGFloat) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - Builder

/// Appends UTF-8 text and raw bytes to one buffer.
///
/// The raw half is the reason it exists: an inlined image is `Data.base64EncodedData()`, which
/// belongs in the document without a `String` ever holding it.
private struct HTMLBuffer {
    private(set) var data = Data()

    static func += (buffer: inout HTMLBuffer, text: String) {
        buffer.data.append(Data(text.utf8))
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }
}

// MARK: - Escaping

extension String {
    /// The five characters that can leave their element. Ampersand first, or the escapes escape
    /// each other.
    var htmlEscaped: String {
        var escaped = replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped.replacingOccurrences(of: "'", with: "&#39;")
    }
}
