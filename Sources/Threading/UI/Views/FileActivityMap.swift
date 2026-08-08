import Foundation
import CoreGraphics

// MARK: - File Activity Map

/// One mark per tracked file, lit as the agent reads and edits — a minimap of the *repo*
/// rather than of a document.
///
/// The universe is `git ls-files` plus anything the session creates: tracked files are the
/// repo's own definition of "the project", and the one that keeps `node_modules` out of a
/// strip that budgets a point or two per file. Order is the spatial structure — paths sort
/// bytewise, the same order git itself lists them, so a directory is a contiguous run and
/// `UI/Design/` becomes a region the eye can learn.
///
/// Pure model, separated from `FileActivityMapView` for the same reason `ConversationMinimap`
/// is separated from its view: the interesting rules — what counts as a touch, how heat
/// fades, when the layout adds a column — are decisions, and decisions should be testable
/// without a window.
struct FileActivityMap {

    // MARK: - Metrics

    enum Metrics {
        /// How long a touch glows before settling at the residual. Long enough to survive a
        /// glance away — a flash is missable, and missable defeats an ambient display.
        static let glowDuration: TimeInterval = 90

        /// The floor a touched file never fades below, so the map also answers "what has
        /// this session been near" after the glow is gone. Zero would make it a live-only
        /// display; full brightness forever would saturate by turn twenty.
        static let residualHeat: Double = 0.18
    }

    // MARK: - Kinds

    /// The two things worth distinguishing. Reads are the novel data — git never sees them —
    /// and edits are the consequential ones.
    typealias Kind = AgentFileActivityKind

    // MARK: - Entries

    /// One file's mark: its repo-relative path and when each kind last touched it.
    struct Entry {
        let path: String

        /// Ordinal of the *parent directory's* run, for the resting alternation that makes
        /// directories legible as regions without spending layout on gaps. The parent, not
        /// the top-level component: `Sources/` is most of a repo and one giant run says
        /// nothing, while leaf directories are the regions a lit mark gets attributed to.
        let runOrdinal: Int

        var lastRead: Date?
        var lastEdit: Date?

        /// Created during the session rather than listed at the start.
        var isNew = false
    }

    private(set) var entries: [Entry] = []
    private var indexByPath: [String: Int] = [:]

    /// The project root, used to relativize the absolute paths tool calls carry. A path
    /// outside it is ignored rather than force-fitted: a read of `/etc/hosts` is real work,
    /// but it is not work *in this repo*, and a mark for it would have to lie about where.
    let root: String?

    // MARK: - Initialization

    init(files: [String], root: String? = nil) {
        self.root = Self.normalizedRoot(root)

        var ordinal = -1
        var previousParent: String?
        var seen = Set<String>()

        // Trimmed before sorting, or `./b.swift` sorts under `.` and lands ahead of `a/`.
        for cleaned in files.map(Self.trimmed).sorted() {
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)

            let parent = Self.parentDirectory(of: cleaned)
            if parent != previousParent {
                ordinal += 1
                previousParent = parent
            }

            indexByPath[cleaned] = entries.count
            entries.append(Entry(path: cleaned, runOrdinal: ordinal))
        }
    }

    // MARK: - Recording

    /// Records a touch, inserting files the session created. Returns the index the touch
    /// landed on, or nil when the path is outside the project and was ignored.
    @discardableResult
    mutating func record(_ kind: Kind, path: String, at date: Date) -> Int? {
        guard let relative = relativized(path) else { return nil }

        let index: Int
        if let existing = indexByPath[relative] {
            index = existing
        } else {
            index = insert(relative)
        }

        switch kind {
        case .read: entries[index].lastRead = date
        case .edit: entries[index].lastEdit = date
        }
        return index
    }

    // MARK: - Heat

    /// A touch's brightness at a given moment: full at the touch, easing to the residual
    /// over `glowDuration`, and holding there. Quadratic so the fade is quick at first and
    /// lingering at the tail — the shape that reads as "cooling" rather than as a dimmer.
    static func heat(since touch: Date?, now: Date) -> Double {
        guard let touch else { return 0 }
        let age = now.timeIntervalSince(touch)
        guard age >= 0 else { return 1 }

        let fade = max(0, 1 - age / Metrics.glowDuration)
        return Metrics.residualHeat + (1 - Metrics.residualHeat) * fade * fade
    }

    func readHeat(at index: Int, now: Date) -> Double {
        Self.heat(since: entries[index].lastRead, now: now)
    }

    func editHeat(at index: Int, now: Date) -> Double {
        Self.heat(since: entries[index].lastEdit, now: now)
    }

    /// Whether anything is still brighter than its residual, which is when a view needs to
    /// keep redrawing and when it may stop.
    func hasActiveGlow(now: Date) -> Bool {
        entries.contains { entry in
            [entry.lastRead, entry.lastEdit].contains { touch in
                guard let touch else { return false }
                return now.timeIntervalSince(touch) < Metrics.glowDuration
            }
        }
    }

    var touchedCount: Int {
        entries.filter { $0.lastRead != nil || $0.lastEdit != nil }.count
    }

    // MARK: - Private Methods

    private mutating func insert(_ path: String) -> Int {
        let index = entries.firstIndex { $0.path > path } ?? entries.count

        // The ordinal follows the neighbourhood the file lands in, so a new file in an
        // existing directory keeps its run's shade rather than starting a new one.
        let parent = Self.parentDirectory(of: path)
        let ordinal: Int
        if index > 0, Self.parentDirectory(of: entries[index - 1].path) == parent {
            ordinal = entries[index - 1].runOrdinal
        } else if index < entries.count, Self.parentDirectory(of: entries[index].path) == parent {
            ordinal = entries[index].runOrdinal
        } else if index > 0 {
            ordinal = entries[index - 1].runOrdinal + 1
        } else {
            ordinal = 0
        }

        entries.insert(Entry(path: path, runOrdinal: ordinal, isNew: true), at: index)
        for later in index..<entries.count {
            indexByPath[entries[later].path] = later
        }
        return index
    }

    private func relativized(_ path: String) -> String? {
        let cleaned = Self.trimmed(path)
        guard cleaned.hasPrefix("/") else { return cleaned.isEmpty ? nil : cleaned }
        guard let root else { return nil }

        if cleaned == root { return nil }
        guard cleaned.hasPrefix(root + "/") else { return nil }
        return String(cleaned.dropFirst(root.count + 1))
    }

    private static func normalizedRoot(_ root: String?) -> String? {
        guard var root, root != "/" else { return nil }
        while root.hasSuffix("/") { root.removeLast() }
        return root.isEmpty ? nil : root
    }

    private static func trimmed(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path
    }

    private static func parentDirectory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

// MARK: - Classification

extension FileActivityMap {

    /// What a tool call means to the map, in both providers' vocabularies.
    ///
    /// Only per-file signals count. A `Grep` or `Glob` names a directory and says nothing
    /// about which files inside it were actually read, and a `Bash` command would need the
    /// shell parsed — both are omitted rather than guessed at, because a mark that might be
    /// wrong poisons the ones that are right.
    static func touches(tool: ToolIdentity, input: [String: Any]) -> [(kind: Kind, path: String)] {
        AgentFileActivityClassifier.signals(tool: tool, input: input).map { ($0.kind, $0.path) }
    }
}

// MARK: - Layout

extension FileActivityMap {

    /// Where every mark goes: files run top-to-bottom, then spill into further columns.
    ///
    /// The pitch adapts to the count rather than the count being capped — a 438-file repo
    /// gets roomy 4pt rows and a 5,000-file one gets 1pt marks, because the map's promise is
    /// the *whole* project, and a map that silently dropped the tail would light up for an
    /// edit it cannot show.
    struct Layout {
        let columnCount: Int
        let rowsPerColumn: Int
        let rowPitch: CGFloat
        let markHeight: CGFloat
        let markWidth: CGFloat
        let columnPitch: CGFloat

        /// The strip is centred in whatever pane holds it; this is the width it actually uses.
        let contentWidth: CGFloat

        enum Metrics {
            /// Narrower than this and a column's marks stop reading as marks.
            static let minimumMarkWidth: CGFloat = 16

            /// A single mark never grows into a slab, however wide the pane.
            static let maximumMarkWidth: CGFloat = 56

            static let columnGap: CGFloat = 6

            /// Roomiest to tightest. The first pitch whose columns fit wins, so small repos
            /// get legible rows and only crowded ones pay in density.
            static let pitches: [CGFloat] = [4, 3, 2, 1.5, 1]
        }

        /// The frame for a mark, in a flipped (top-left origin) coordinate space, relative
        /// to the strip's own content box.
        func rect(at index: Int) -> CGRect {
            let column = index / max(1, rowsPerColumn)
            let row = index % max(1, rowsPerColumn)
            return CGRect(
                x: CGFloat(column) * columnPitch,
                y: CGFloat(row) * rowPitch,
                width: markWidth,
                height: markHeight
            )
        }

        static func compute(count: Int, size: CGSize) -> Layout? {
            guard count > 0, size.width >= Metrics.minimumMarkWidth, size.height > 0 else {
                return nil
            }

            for pitch in Metrics.pitches {
                let capacity = Int(size.height / pitch)
                guard capacity > 0 else { continue }
                let columns = Int((Double(count) / Double(capacity)).rounded(.up))
                let needed = CGFloat(columns) * Metrics.minimumMarkWidth
                    + CGFloat(columns - 1) * Metrics.columnGap
                if needed <= size.width {
                    return layout(count: count, columns: columns, pitch: pitch, size: size)
                }
            }

            // Tighter than the tightest pitch: as many columns as the width holds, and the
            // pitch squeezed to fit — sub-point marks still draw on a retina display, and
            // overlap is honest where omission is not.
            let maxColumns = max(1, Int(
                (size.width + Metrics.columnGap) / (Metrics.minimumMarkWidth + Metrics.columnGap)
            ))
            let rows = Int((Double(count) / Double(maxColumns)).rounded(.up))
            let columns = Int((Double(count) / Double(rows)).rounded(.up))
            return layout(
                count: count,
                columns: columns,
                pitch: size.height / CGFloat(rows),
                size: size
            )
        }

        private static func layout(count: Int, columns: Int, pitch: CGFloat, size: CGSize) -> Layout {
            let available = size.width - CGFloat(columns - 1) * Metrics.columnGap
            let markWidth = min(Metrics.maximumMarkWidth, available / CGFloat(columns))
            let rows = Int((Double(count) / Double(columns)).rounded(.up))

            return Layout(
                columnCount: columns,
                rowsPerColumn: rows,
                rowPitch: pitch,
                markHeight: min(pitch, max(0.8, pitch - 1)),
                markWidth: markWidth,
                columnPitch: markWidth + Metrics.columnGap,
                contentWidth: CGFloat(columns) * markWidth + CGFloat(columns - 1) * Metrics.columnGap
            )
        }
    }
}
