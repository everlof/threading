import Foundation
import ThreadingExtensionKit

// MARK: - Reference Detection

/// Extracts only supported-attachment-shaped paths — images, PDFs, HTML, archives and open
/// document formats — then lets the filesystem decide whether each one is real.
enum AttachmentReferenceDetector {

    /// Real files the text named, split by the one question the caller has to answer.
    ///
    /// The split is the detector's whole contribution to the scope rule: it reports what it
    /// found and where, and the store — which knows the user's answer — decides what that means.
    /// Sorting the two apart here rather than filtering at the call site is what lets a refused
    /// file still be counted.
    struct Resolution: Equatable, Sendable {
        var insideProject: [URL] = []
        var outsideProject: [URL] = []
        var resolvedProjectRoot: URL?

        var isEmpty: Bool { insideProject.isEmpty && outsideProject.isEmpty }
    }

    /// One set per kind, and the kinds joined for the scan. `kind(for:)` maps each set
    /// explicitly — it used to answer `.image` for anything the list held that was not a PDF or
    /// HTML, which was correct only while images were the remainder, and one added extension
    /// away from the pane decoding a zip as a picture.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"
    ]
    /// What the platform's audiovisual stack actually plays, which is a shorter list than the
    /// one people mean by "video".
    ///
    /// `webm`, `mkv` and `avi` are deliberately absent: AVFoundation opens none of them, so
    /// admitting one would put a row in the pane whose preview could only ever say it cannot be
    /// played — and would take that file's name off the terminal line where the user can still
    /// open it in something that can. The gate is the *name* here and playability is confirmed by
    /// the decoder at preview time, because an extension is a claim and a container is not
    /// obliged to honour it.
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v"
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar"
    ]
    private static let documentExtensions: Set<String> = [
        "odt", "ods", "odp", "docx", "xlsx", "pptx", "rtf"
    ]
    /// `.dot` is also the legacy Word-template extension; the filesystem check keeps it honest,
    /// and a template named in a coding session's output is the rarer reading by far.
    private static let diagramExtensions: Set<String> = [
        "dot", "gv", "mmd", "mermaid"
    ]
    /// Classified, but deliberately **not** in the scan below. A diff reaches the list as a
    /// handoff — a frozen comparison, a patch dropped on the composer — while `git format-patch`
    /// alone prints a column of `.patch` paths that nobody meant as attachments.
    private static let diffExtensions: Set<String> = ["diff", "patch"]
    /// The app's own record of a picture comparison; nothing outside it writes one.
    private static let comparisonExtension = "comparison"
    /// Extensions a *registration* may claim, plus the ambiguous ones the host probes itself.
    ///
    /// Both are in the scan's alternation unconditionally, because the alternation is a compiled
    /// regular expression and the registered set changes when an extension is enabled. Matching a
    /// path is cheap; admission is where the real decision happens, and both routes are refused
    /// there unless the registry or the probe says otherwise.
    static let registrableExtensions: Set<String> = ["lottie"]
    private static let extensions =
        imageExtensions.sorted() + ["pdf", "html", "htm"]
            + videoExtensions.sorted()
            + archiveExtensions.sorted() + documentExtensions.sorted()
            + diagramExtensions.sorted()
            + registrableExtensions.sorted()
            + MediaContentProbe.ambiguousExtensions.sorted()
    /// Longest first, because the alternation is ordered and nothing after it requires a word
    /// boundary: with `tif` offered before `tiff`, `shot.tiff` matched as `shot.tif`, a file
    /// that does not exist, and the real one was never recorded.
    private static let extensionAlternation = extensions
        .sorted { $0.count > $1.count }
        .joined(separator: "|")

    /// Quoted and Markdown forms admit spaces. The plain form deliberately does not: prose around
    /// an unquoted path is otherwise indistinguishable from the path itself.
    private static let patterns: [NSRegularExpression] = [
        expression(#"\]\(([^)\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)\)"#),
        expression(#"[`"]([^`"\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)[`"]"#),
        expression(#"'([^'\r\n]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)'"#),
        // Try a plain path only at the start of its token. Without this boundary, a token
        // with no supported suffix retries the entire remainder at every character: a 16 KiB
        // line took seconds even though it produced no candidates and performed no file I/O.
        expression(#"(?<![^\s<>"'`()\[\]{}])((?:file://)?[^\s<>"'`()\[\]{}]+\.(?:"# + extensionAlternation + #")(?::\d+(?::\d+)?)?)"#)
    ].compactMap { $0 }

    /// Every real supported file the text names, sorted by whether it lives in the project.
    ///
    /// Containment used to be checked *before* the filesystem, which made an outside path free to
    /// reject — it was rejected on a string. Reporting one costs a `stat`, because a path in prose
    /// is not evidence that a file exists and a count of files that are not there would be worse
    /// than saying nothing. `maximumCandidatesPerScan` is what keeps that bounded: a terminal
    /// printing thousands of paths is a normal afternoon, and both lists are capped downstream
    /// anyway, so the work per scan may not scale with what an agent happened to `cat`.
    static func resolve(
        text: String,
        projectRoot: URL,
        currentDirectory: URL?,
        fileManager: FileManager = .default
    ) -> Resolution {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        var seen: Set<String> = []
        var result = Resolution(resolvedProjectRoot: root)
        // The probe's own ceiling, spent per scan rather than per file: a buffer naming three
        // hundred `.json` paths is a normal afternoon, and the work a scan may do on them is
        // ours to bound even though their number is not.
        var probedCandidates = 0

        for candidate in candidates(in: text) {
            // A relative candidate is proposed against the working directory before the checkout,
            // and the checkout still wins when both hold a file of that name: `a.png` printed
            // from a session that has wandered into `/tmp` means the project's file if there is
            // one. Only when nothing inside answers does the outside match stand.
            var outside: URL?
            var matchedInside = false

            for proposed in proposedURLs(
                for: candidate,
                projectRoot: root,
                currentDirectory: currentDirectory
            ) {
                let file = proposed.standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                // Existence first for an ambiguous candidate, so a path in prose that names no
                // file cannot spend the probe budget a real one needs.
                let isAmbiguous = MediaContentProbe.ambiguousExtensions.contains(
                    file.pathExtension.lowercased()
                )
                if isAmbiguous {
                    guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue,
                          probedCandidates < MediaContentProbe.maximumCandidatesPerScan else {
                        continue
                    }
                    probedCandidates += 1
                }
                guard kind(for: file) != nil,
                      fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }
                if contains(file, inside: root) {
                    if seen.insert(file.path).inserted { result.insideProject.append(file) }
                    matchedInside = true
                    break
                }
                if outside == nil { outside = file }
            }

            if !matchedInside, let outside, seen.insert(outside.path).inserted {
                result.outsideProject.append(outside)
            }
        }
        return result
    }

    /// The bound on both halves of a scan's work: matching stops here, and each candidate is
    /// proposed against at most two roots, so this is also the ceiling on `stat` calls.
    ///
    /// Comfortably above what any list can hold (`maximumPerSession`), because a candidate is
    /// not yet a file — most of them turn out not to exist — while still bounding the pass over
    /// a buffer whose size is decided by whatever an agent last printed.
    static let maximumCandidatesPerScan = 512

    /// The kind a file is recorded as, or nil for one the pane has nothing to say about.
    ///
    /// Two routes reach `.media`, and the order matters. A **registered** extension is decided by
    /// its name alone, which is why registrations may not claim a reserved one. An **ambiguous**
    /// extension is decided by the bytes: a bare Lottie is a `.json`, and admitting `.json` on its
    /// name would fill the pane with `package.json`. The probe reads a bounded prefix and declines
    /// when the structure is not inside it, so the answer costs one short read of a file the
    /// caller was about to `stat` anyway.
    static func kind(for url: URL) -> SessionAttachmentKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ext == "html" || ext == "htm" { return .html }
        if videoExtensions.contains(ext) { return .video }
        if archiveExtensions.contains(ext) { return .archive }
        if documentExtensions.contains(ext) { return .document }
        if diagramExtensions.contains(ext) { return .diagram }
        if diffExtensions.contains(ext) { return .diff }
        if ext == comparisonExtension { return .comparison }
        if AttachmentMediaTypeRegistry.shared.isRegistered(ext) { return .media }
        if MediaContentProbe.ambiguousExtensions.contains(ext) {
            return admissionHint(for: url) != nil ? .media : nil
        }
        return nil
    }

    /// Whether a name claims to be a movie the platform can play.
    ///
    /// The composer's question, asked before it spends a decoder on a dropped file. A name is a
    /// claim and the decoder answers it — a `.mov` that is not one gives up no poster frame and
    /// falls back to being a path — but the *set* is decided here once, so the composer and the
    /// attachments pane cannot disagree about which files are movies.
    static func isMovie(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// The host-owned hint that admits an otherwise ambiguous file, or nil.
    ///
    /// Only a hint on the host's small admission list gets a row of its own. Other hints may
    /// enrich a kind that was already admitted without becoming admission rules themselves.
    static func admissionHint(for url: URL) -> ExtensionFileContentHint? {
        guard let hint = MediaContentProbe.hint(for: url),
              MediaContentProbe.admissionHints.contains(hint) else { return nil }
        return hint
    }

    static func contains(_ file: URL, inside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath.hasSuffix("/")
            ? rootPath
            : rootPath + "/")
    }

    /// Path-shaped text, deduplicated, and never more than the scan is allowed to consider.
    ///
    /// The cap is enforced *while matching* rather than by trimming the result. `matches(in:)`
    /// materialises every hit before anything can be discarded, so a terminal holding a thousand
    /// paths built a thousand `NSTextCheckingResult`s and a thousand bridged `String`s to keep
    /// the first few hundred — on the main thread, on a debounce, in a window that is drawing.
    /// Enumerating and stopping is the same answer for a fraction of the work.
    static func candidates(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var candidates: [String] = []

        for pattern in patterns {
            guard candidates.count < maximumCandidatesPerScan else { break }
            pattern.enumerateMatches(in: text, range: range) { match, _, stop in
                guard let match else { return }
                let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard capture.location != NSNotFound,
                      let swiftRange = Range(capture, in: text) else { return }
                let candidate = clean(String(text[swiftRange]))
                guard !candidate.isEmpty, seen.insert(candidate).inserted else { return }
                candidates.append(candidate)
                if candidates.count >= maximumCandidatesPerScan { stop.pointee = true }
            }
        }
        return candidates
    }

    private static func proposedURLs(
        for candidate: String,
        projectRoot: URL,
        currentDirectory: URL?
    ) -> [URL] {
        let withoutLocation = candidate.replacingOccurrences(
            of: #":\d+(?::\d+)?$"#,
            with: "",
            options: .regularExpression
        )
        let decoded = withoutLocation.removingPercentEncoding ?? withoutLocation

        if decoded.lowercased().hasPrefix("file://"),
           let url = URL(string: decoded), url.isFileURL {
            return [url]
        }

        let expanded = NSString(string: decoded).expandingTildeInPath
        if NSString(string: expanded).isAbsolutePath {
            return [URL(fileURLWithPath: expanded)]
        }

        var roots: [URL] = []
        if let currentDirectory { roots.append(currentDirectory) }
        roots.append(projectRoot)
        return roots.map { $0.appendingPathComponent(expanded) }
    }

    private static func clean(_ value: String) -> String {
        let unescaped = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\\ "#, with: " ")

        return String(
            unescaped.reversed()
                .drop(while: { ".,;!?".contains($0) })
                .reversed()
        )
    }

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        // These are compile-time-owned patterns. A failed pattern should make detection inert,
        // not take down the session displaying untrusted terminal text.
        try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )
    }
}
