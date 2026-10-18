import Foundation

// MARK: - Reclaimable Storage Listing

/// One bounded page of `list_reclaimable_storage`.
///
/// The listing used to be every finding on its own line, in project order. Measured on
/// 2026-10-17 with the data volume 99% full: **501 directories and 95,647 characters** — more
/// than an agent's tool result holds, so the agent that had just hit ENOSPC could not read the
/// answer written for it, and 211 of those lines were Python bytecode weighing under 0.1 GB
/// together. The number of findings comes from the disk, not from a schema, so the answer is
/// bounded the way any externally sized list is: the shape first, then a page.
///
/// A page leads with **where the space is** — totals per checkout or scratch tier, which is the
/// question an agent short of room is actually asking — then lists directories in the order one
/// should be proposed: ORPHANED first, since nothing can ever want those back, then largest
/// first. It ends by saying what it left out and how to ask for it, because a silent cut reads
/// as "that is everything".
///
/// Pure: the caller supplies the groups, the freshness label and the line for one directory, so
/// the bound and the order are tested without a scan, a store or a window.
enum ReclaimableStorageListing {

    // MARK: - Bounds

    /// Rows on a page nobody asked to size. Forty lines of the old format is about 7,500
    /// characters — readable in one tool result, and on the measured machine it already covered
    /// everything over 300 MB.
    static let defaultLimit = 40

    /// The most one call may ask for, so a page stays an order of magnitude under the size that
    /// broke the unbounded answer.
    static let maximumLimit = 200

    /// Locations named in the summary before the rest fold into one line.
    static let summaryLocations = 8

    // MARK: - Types

    /// What one call asked for, clamped to the bounds above.
    struct Options: Equatable {
        let limit: Int
        let offset: Int

        /// An absolute path with `~` expanded, in its canonical spelling, or nil for everything.
        let under: String?

        init(limit: Int? = nil, offset: Int? = nil, under: String? = nil) {
            self.limit = min(max(limit ?? defaultLimit, 1), maximumLimit)
            self.offset = max(offset ?? 0, 0)
            self.under = under
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                .map { Self.canonical(($0 as NSString).expandingTildeInPath) }
        }

        init(_ arguments: ListReclaimableStorageArguments) {
            self.init(limit: arguments.limit, offset: arguments.offset, under: arguments.under)
        }

        /// Whether a finding sits at or below `under`, by whole path components.
        func includes(_ artifact: ReclaimableArtifact) -> Bool {
            guard let under else { return true }

            let path = Self.canonical(artifact.url.path)
            return path == under || path.hasPrefix(under == "/" ? under : under + "/")
        }

        /// One spelling per directory, decided lexically. `/tmp`, `/var` and `/etc` are
        /// symlinks into `/private`, and the scanner stores the `/private` form; an agent is as
        /// likely to type either. `resolvingSymlinksInPath()` is not used: it drops a leading
        /// `/private` only when the shorter path exists (see `storage-and-stats.md`), and calling
        /// it per finding would be filesystem work per row on the main actor.
        private static func canonical(_ path: String) -> String {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            for alias in Self.privateAliases
            where standardized == alias || standardized.hasPrefix(alias + "/") {
                return "/private" + standardized
            }
            return standardized
        }

        private static let privateAliases = ["/tmp", "/var", "/etc"]
    }

    // MARK: - Page

    /// The text of one page.
    ///
    /// - Parameters:
    ///   - groups: Every group the findings fall into, as `ReclaimableFindings.groups` orders them.
    ///   - measured: The freshness suffix for the header, empty when nothing says how old it is.
    ///   - line: One directory's line, in the shape its group uses.
    static func page(
        groups: [ReclaimableFindings.Group],
        measured: String,
        options: Options,
        line: (ReclaimableArtifact, ReclaimableFindings.Group) -> String
    ) -> String {
        let locations = groups
            .map { group in (group: group, artifacts: group.artifacts.filter(options.includes)) }
            .filter { !$0.artifacts.isEmpty }

        let rows = locations
            .flatMap { location in location.artifacts.map { (artifact: $0, group: location.group) } }
            .sorted(by: proposalOrder)

        guard !rows.isEmpty else {
            return options.under.map(Strings.nothingUnder) ?? StorageToolStrings.nothingFound
        }

        let total = rows.reduce(Int64(0)) { $0 + $1.artifact.byteCount }
        var sections = [header(total: total, count: rows.count, measured: measured, under: options.under)]
        sections.append(summary(of: locations))

        let start = min(options.offset, rows.count)
        let end = min(start + options.limit, rows.count)

        guard start < end else {
            sections.append(Strings.pastTheEnd(offset: options.offset, count: rows.count))
            sections.append(StorageToolStrings.listingFooter)
            return sections.joined(separator: "\n\n")
        }

        sections.append(
            ([Strings.rowsHeading(from: start + 1, to: end, of: rows.count)]
                + rows[start..<end].map { line($0.artifact, $0.group) })
                .joined(separator: "\n")
        )

        if end < rows.count {
            let rest = rows[end...].reduce(Int64(0)) { $0 + $1.artifact.byteCount }
            sections.append(Strings.more(count: rows.count - end, size: size(rest), nextOffset: end))
        }

        sections.append(StorageToolStrings.listingFooter)
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Private

    /// ORPHANED first, then largest, then by path so two equal sizes always page the same way.
    private static func proposalOrder(
        _ lhs: (artifact: ReclaimableArtifact, group: ReclaimableFindings.Group),
        _ rhs: (artifact: ReclaimableArtifact, group: ReclaimableFindings.Group)
    ) -> Bool {
        let lhsOrphaned = lhs.group.attribution.namesADeletedWorkspace
        let rhsOrphaned = rhs.group.attribution.namesADeletedWorkspace
        if lhsOrphaned != rhsOrphaned { return lhsOrphaned }
        if lhs.artifact.byteCount != rhs.artifact.byteCount {
            return lhs.artifact.byteCount > rhs.artifact.byteCount
        }
        return lhs.artifact.url.path < rhs.artifact.url.path
    }

    private static func header(total: Int64, count: Int, measured: String, under: String?) -> String {
        let line = StorageToolStrings.header(total: size(total), count: count, measured: measured)
        return under.map { Strings.underPrefix($0) + line } ?? line
    }

    /// Where the space is, one line per location: the orphan tier first whatever its size, then
    /// the rest largest first, folding past `summaryLocations`. Each line carries the location's
    /// path, which is what `under` takes.
    private static func summary(
        of locations: [(group: ReclaimableFindings.Group, artifacts: [ReclaimableArtifact])]
    ) -> String {
        let measured = locations.map { location in
            (
                group: location.group,
                count: location.artifacts.count,
                bytes: location.artifacts.reduce(Int64(0)) { $0 + $1.byteCount }
            )
        }
        let ordered = measured.sorted { lhs, rhs in
            let lhsOrphaned = lhs.group.attribution.namesADeletedWorkspace
            let rhsOrphaned = rhs.group.attribution.namesADeletedWorkspace
            if lhsOrphaned != rhsOrphaned { return lhsOrphaned }
            return lhs.bytes > rhs.bytes
        }

        var lines = [Strings.summaryHeading]
        lines += ordered.prefix(summaryLocations).map { location in
            Strings.location(
                size: size(location.bytes),
                title: location.group.title,
                path: location.group.subtitle,
                count: location.count
            )
        }

        let folded = ordered.dropFirst(summaryLocations)
        if !folded.isEmpty {
            lines.append(Strings.moreLocations(
                count: folded.count,
                size: size(folded.reduce(Int64(0)) { $0 + $1.bytes })
            ))
        }

        return lines.joined(separator: "\n")
    }

    private static func size(_ byteCount: Int64) -> String {
        StorageCleanupOutline.size(byteCount)
    }

    // MARK: - Strings

    enum Strings {
        static let summaryHeading = "Where it is:"

        static func location(size: String, title: String, path: String, count: Int) -> String {
            "  \(size) · \(title) · \(path) · \(count) \(count == 1 ? "directory" : "directories")"
        }

        static func moreLocations(count: Int, size: String) -> String {
            "  …and \(count) more \(count == 1 ? "location" : "locations") holding \(size)."
        }

        static func rowsHeading(from: Int, to: Int, of count: Int) -> String {
            "Directories \(from)–\(to) of \(count), ORPHANED first, then largest:"
        }

        /// The cut, said out loud. Without it a page reads as the whole answer.
        static func more(count: Int, size: String, nextOffset: Int) -> String {
            """
            \(count) more \(count == 1 ? "directory" : "directories") holding \(size) \
            \(count == 1 ? "is" : "are") not shown. Call again with offset \(nextOffset) for the \
            next page, or with under set to a path above to list one location.
            """
        }

        static func pastTheEnd(offset: Int, count: Int) -> String {
            "There is nothing past offset \(offset): the listing has \(count) directories."
        }

        static func underPrefix(_ path: String) -> String {
            "Under \(path): "
        }

        static func nothingUnder(_ path: String) -> String {
            """
            Nothing reclaimable is listed under \(path). Call list_reclaimable_storage without \
            under to see every location, or suggest_reclaimable_location if you believe a \
            directory there is reclaimable.
            """
        }
    }
}
