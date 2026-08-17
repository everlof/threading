import Foundation

// MARK: - Storage Cleanup Outline

/// What a cleanup proposal looks like once it is laid out to be *read* rather than listed.
///
/// A proposal is a list of absolute paths, and a list of absolute paths is the worst possible
/// shape for the one question the sheet asks: *is this mine to lose?* Six lines beginning
/// `/Users/david/repo/AnotherTerminal/` share their first thirty-four characters, so the part
/// that differs — which checkout, which directory — starts wherever the eye finally gets to.
/// A real proposal from the machine this was built for named 24 directories under
/// `/private/tmp`, and read as a wall.
///
/// So it is folded twice:
///
/// - **By heading**, using `ReclaimableFindings` — the same grouping the Storage page draws, so
///   the two surfaces cannot tell the user two different stories about where a directory
///   belongs. The heading is where the meaning is: a checkout of a project, a project's build
///   cache in a temporary location, or one of the two tiers that name no project.
/// - **By shared path segment** within a heading. What is left after the heading's own root is
///   a set of relative paths, and their common prefixes become branches: eight rows under
///   `claude-501/` become one line with eight children. A branch line carries the total of what
///   is under it, because a branch is also an answer — 20 GB in one temporary directory is the
///   fact somebody approves or refuses.
///
/// Pure, and free of AppKit, so both the drawn accessory and its tests read the same structure.
struct StorageCleanupOutline: Equatable {

    // MARK: - Types

    /// One line under a heading: a directory being removed, or a path segment several of them
    /// share.
    struct Row: Equatable {

        /// How deep beneath the heading this sits. Zero is directly under it.
        let depth: Int

        /// The path fragment this line stands for, relative to the line above it. A chain of
        /// single-child directories collapses into one label (`web/node_modules`) rather than
        /// spending a line on each: a level that names one thing is an indent, not information.
        let label: String

        /// What this line accounts for: a directory's own size, or the sum of what is under it.
        let byteCount: Int64

        /// The one thing about this row that changes the decision — that something is writing
        /// there right now, or which tree a temporary cache was built for. Nil when the heading
        /// has already said it, which is why orphans carry none: their heading is the reason.
        let note: String?

        /// Whether this line is one of the directories being removed. A branch is drawn as the
        /// grouping it is, and never counted as a directory in the sheet's own arithmetic.
        let isDirectory: Bool
    }

    /// One heading and everything under it.
    struct Section: Equatable {
        let heading: String

        /// Where on disk, which is what somebody about to delete gigabytes actually confirms.
        let subheading: String

        let byteCount: Int64
        let rows: [Row]

        /// Directories, not lines: a branch row groups, it does not go.
        var directoryCount: Int { rows.filter(\.isDirectory).count }
    }

    let sections: [Section]

    var byteCount: Int64 { sections.reduce(0) { $0 + $1.byteCount } }
    var directoryCount: Int { sections.reduce(0) { $0 + $1.directoryCount } }

    // MARK: - Building

    /// Lays out the artifacts of one proposal.
    ///
    /// `now` is stated so a test can decide whether a fixture is being written to, rather than
    /// racing the clock the sheet is drawn against.
    static func make(
        from groups: [ReclaimableFindings.Group],
        at now: Date = Date()
    ) -> StorageCleanupOutline {
        StorageCleanupOutline(sections: groups.compactMap { group in
            let rows = self.rows(of: group, at: now)
            guard !rows.isEmpty else { return nil }
            return Section(
                heading: group.title,
                subheading: group.subtitle,
                byteCount: group.byteCount,
                rows: rows
            )
        })
    }

    /// The rows one heading holds, in the order the page reads them: largest first at every
    /// level, so the line worth reading is never below the ones that are not.
    private static func rows(of group: ReclaimableFindings.Group, at now: Date) -> [Row] {
        let root = Node()
        for artifact in group.artifacts {
            root.insert(
                ReclaimableFindings.rowTitle(for: artifact).split(separator: "/").map(String.init),
                artifact: artifact
            )
        }
        return root.rows(depth: 0, attribution: group.attribution, now: now)
    }

    // MARK: - Node

    /// One level of the shared-path fold, built while inserting and read once.
    private final class Node {
        var children: [String: Node] = [:]

        /// Insertion order is kept only so a tie in size is stable rather than dictionary-random.
        var order: [String] = []

        var artifact: ReclaimableArtifact?
        var byteCount: Int64 = 0

        func insert(_ components: [String], artifact: ReclaimableArtifact) {
            byteCount += artifact.byteCount

            guard let head = components.first else {
                // A directory that *is* an ancestor of another finding keeps its own artifact:
                // a proposal naming both `target` and `target/debug` is unusual, and drawing the
                // parent as a branch that removes nothing would be a lie about what goes.
                self.artifact = artifact
                return
            }

            let child = children[head] ?? {
                let node = Node()
                children[head] = node
                order.append(head)
                return node
            }()
            child.insert(Array(components.dropFirst()), artifact: artifact)
        }

        /// Emits this node's children depth-first, collapsing every chain that names one thing.
        func rows(
            depth: Int,
            attribution: ReclaimableFindings.Attribution,
            now: Date
        ) -> [Row] {
            var named: [(name: String, node: Node)] = []
            for name in order {
                guard let child = children[name] else { continue }
                named.append((name, child))
            }
            named.sort { $0.node.byteCount > $1.node.byteCount }

            var rows: [Row] = []
            for entry in named {
                var label = entry.name
                var node = entry.node

                // A level with one child and nothing of its own is an indent that says nothing.
                // Fold it into the label until the path branches or arrives.
                while node.artifact == nil,
                      node.children.count == 1,
                      let only = node.order.first,
                      let next = node.children[only] {
                    label += "/" + only
                    node = next
                }

                var note: String?
                if let artifact = node.artifact {
                    note = StorageCleanupOutline.note(
                        for: artifact,
                        attribution: attribution,
                        now: now
                    )
                }

                rows.append(Row(
                    depth: depth,
                    label: label,
                    byteCount: node.byteCount,
                    note: note,
                    isDirectory: node.artifact != nil
                ))
                rows += node.rows(depth: depth + 1, attribution: attribution, now: now)
            }
            return rows
        }
    }

    // MARK: - Notes

    /// What one row says beyond its path and its size, and deliberately little else.
    ///
    /// Two facts change the decision and nothing else does. **Something is writing there** is
    /// the one that makes an approval regrettable, so it leads. **Which tree a temporary cache
    /// was built for** is the only thing that says which of two identical-looking caches this
    /// is; a checkout's own findings need it never, and an orphan's heading already says its
    /// workspace is gone — repeating it per row would spend the widest column in the sheet on
    /// the fact its heading opens with.
    static func note(
        for artifact: ReclaimableArtifact,
        attribution: ReclaimableFindings.Attribution,
        now: Date
    ) -> String? {
        var parts: [String] = []

        if artifact.isInUse(at: now), let modifiedAt = artifact.modifiedAt {
            parts.append(ReclaimableFindings.Strings.inUse(age(of: modifiedAt, at: now)))
        }

        if let workspace = artifact.workspacePath,
           attribution.isScratch,
           !attribution.namesADeletedWorkspace {
            parts.append(ReclaimableFindings.Strings.builtFor(
                ReclaimableFindings.abbreviate(workspace)
            ))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Reading

    /// The whole outline as text, one line per row, for the accessibility reading of a view that
    /// draws rather than stacks — and for a test that asserts on the shape rather than on pixels.
    func plainText() -> String {
        sections.map { section in
            ([
                "\(section.heading) — \(Self.size(section.byteCount))"
            ] + section.rows.map { row in
                let indent = String(repeating: "  ", count: row.depth + 1)
                let note = row.note.map { " (\($0))" } ?? ""
                return "\(indent)\(row.label)\(note) — \(Self.size(row.byteCount))"
            }).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    // MARK: - Formatters

    /// Foundation's own class method rather than a cached instance: a `ByteCountFormatter` held
    /// in a `static let` is shared mutable state that no actor owns, and this is not a hot enough
    /// path to be worth isolating one.
    static func size(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static func age(of date: Date, at now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
