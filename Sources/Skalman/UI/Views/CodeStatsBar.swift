import Foundation

// MARK: - Code Stats Bar

/// The arithmetic of the language-composition bar, apart from its drawing — which languages
/// become segments, what folds into "Other", and how wide each segment draws. Separate so the
/// rules are testable without rendering anything (the `ConversationMinimap` split).
struct CodeStatsBar: Equatable {

    /// One stretch of the bar.
    struct Segment: Equatable {
        let name: String
        let code: Int
        let fraction: CGFloat

        /// Index into `Design.Categorical.ramp`; nil is the "Other" fold, drawn muted.
        let colorIndex: Int?
    }

    /// Largest first; the fold, when present, is always last.
    let segments: [Segment]

    var isEmpty: Bool { segments.isEmpty }

    // MARK: - Building

    /// Folds a reading into at most `maximumSegments` named segments plus "Other".
    ///
    /// The fold only exists when it stands for *more than one* language: with exactly one
    /// language past the cap, "Other" would be a name withheld for nothing, so the language
    /// keeps its own name (and the ramp is one colour deeper than the cap to give it one).
    static func make(
        from stats: CodeStats,
        maximumSegments: Int = CodeStatsBarDefaults.maximumSegments
    ) -> CodeStatsBar {
        let counted = stats.languages.filter { $0.code > 0 }
        let total = counted.reduce(0) { $0 + $1.code }
        guard total > 0 else { return CodeStatsBar(segments: []) }

        func segment(_ language: CodeStats.Language, index: Int?) -> Segment {
            Segment(
                name: language.name,
                code: language.code,
                fraction: CGFloat(language.code) / CGFloat(total),
                colorIndex: index
            )
        }

        if counted.count <= maximumSegments + 1 {
            return CodeStatsBar(
                segments: counted.enumerated().map { segment($1, index: $0) }
            )
        }

        var segments = counted.prefix(maximumSegments).enumerated().map { segment($1, index: $0) }
        let folded = counted.dropFirst(maximumSegments)
        let foldedCode = folded.reduce(0) { $0 + $1.code }
        segments.append(Segment(
            name: CodeStatsBarDefaults.otherName,
            code: foldedCode,
            fraction: CGFloat(foldedCode) / CGFloat(total),
            colorIndex: nil
        ))
        return CodeStatsBar(segments: segments)
    }

    // MARK: - Layout

    /// The drawn width of each segment across `totalWidth`, gaps excluded.
    ///
    /// Every segment gets `minimumWidth` up front and the remainder is split by fraction: a
    /// repository that is 99% one language still has to *show* the others it names, and a
    /// subpixel sliver reads as a rendering artefact. At bar widths the floors are a few
    /// points against hundreds, so the distortion is invisible — and the shape is monotone,
    /// sums exactly, and cannot push anything back under the floor. Degrades to plain
    /// proportion when the floors themselves cannot fit.
    func widths(
        totalWidth: CGFloat,
        gap: CGFloat,
        minimumWidth: CGFloat
    ) -> [CGFloat] {
        guard !segments.isEmpty else { return [] }

        let available = totalWidth - gap * CGFloat(segments.count - 1)
        guard available > 0 else { return segments.map { _ in 0 } }

        let floors = minimumWidth * CGFloat(segments.count)
        guard available >= floors else { return segments.map { $0.fraction * available } }

        let flexible = available - floors
        return segments.map { minimumWidth + $0.fraction * flexible }
    }
}

// MARK: - Code Stats Bar Defaults

enum CodeStatsBarDefaults {
    /// One fewer than the categorical ramp, so the no-fold case can name one language more
    /// than the cap and still give it a colour of its own.
    static let maximumSegments = 5

    static let otherName = "Other"

    static let height: CGFloat = 6
    static let segmentGap: CGFloat = 1
    static let minimumSegmentWidth: CGFloat = 2
}
