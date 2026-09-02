import AppKit

// MARK: - Claim

/// One answer a view gives the pointer: this cursor, over this much of itself.
public struct PointerClaim: Equatable {
    public var rect: NSRect
    public var cursor: NSCursor

    public init(_ rect: NSRect, _ cursor: NSCursor) {
        self.rect = rect
        self.cursor = cursor
    }
}

// MARK: - Claiming

/// What a view tells the pointer over itself, declared rather than registered.
///
/// **Claiming nothing is not the same as claiming the arrow.** Cursor rectangles are a *window's*
/// list, not a view's, so a view that registers none does not fall back to the default cursor —
/// it inherits whatever is registered behind it. That is invisible until something behind claims
/// unusually: `TerminalView` claims an I-beam over the whole of itself, `NSTextField` over the
/// whole of itself, a transcript's text views over theirs. Two bugs on one morning came from it —
/// a search field's own buttons offering to select text, and the corner card's usage row offering
/// to select the terminal underneath — and both were written by people who simply did not know
/// there was a question to answer. See the design-system notes of 2026-08-21.
///
/// So the question is asked as a property. A conformer states the cursor it holds at rest and the
/// parts of itself that answer differently; `registerPointerClaims()` is the only thing that
/// touches AppKit, and `scripts/check_theme_boundaries.sh` fails a build that reaches past it.
///
/// Three things follow from having the claims as a *value* rather than as the side effect of a
/// method, and all three were previously copied from site to site or forgotten:
///
/// - **Overlap becomes impossible.** Claims are resolved specific-first, each carved against what
///   is already claimed, so the case AppKit documents as undefined cannot be constructed here.
///   Three files used to do this arithmetic by hand.
/// - **The resting cursor is a decision somebody made**, visible in review and assertable in a
///   test, rather than the absence of code.
/// - **Staleness has one answer**: `refreshPointerClaims()`, called from `layout()` by the base
///   classes, so a view whose rows moved inside an unchanged frame re-registers.
@MainActor
public protocol PointerClaiming: NSView {

    /// The cursor over everything this view covers that no claim below names.
    ///
    /// `.arrow` for opaque chrome — which is nearly everything, and is what the base classes
    /// default to. **`nil` says the view is not opaque** and means it deliberately lets whatever
    /// is behind it answer: a transparent overlay over a web page, a grip drawn inside a surface
    /// that already claims the pointer for the pair of them. It is a statement, not a shrug.
    var restingPointer: NSCursor? { get }

    /// The parts that answer differently — a seam's corner, a pressable line, a marker — most
    /// specific first. Rectangles are in this view's own coordinates and may safely overlap each
    /// other: an earlier claim wins the ground it shares with a later one.
    var pointerClaims: [PointerClaim] { get }
}

extension PointerClaiming {

    public var restingPointer: NSCursor? { nil }

    public var pointerClaims: [PointerClaim] { [] }

    /// The claims exactly as `registerPointerClaims()` will make them: clipped to the view,
    /// carved so no two overlap, and with the remainder of `bounds` taking the resting cursor.
    ///
    /// Public so a test can ask what a view tells the pointer without a window to register into —
    /// which is also how the tiling invariant is checked.
    public func resolvedPointerClaims() -> [PointerClaim] {
        var taken: [NSRect] = []
        var resolved: [PointerClaim] = []
        for claim in pointerClaims {
            let room = claim.rect.intersection(bounds)
            guard !room.isEmpty else { continue }
            for piece in PointerRectCarving.subtract(taken, from: room) {
                resolved.append(PointerClaim(piece, claim.cursor))
            }
            taken.append(room)
        }
        if let restingPointer {
            for piece in PointerRectCarving.subtract(taken, from: bounds) {
                resolved.append(PointerClaim(piece, restingPointer))
            }
        }
        return resolved
    }

    /// The one call that reaches AppKit. A conformer's `resetCursorRects()` is this line and
    /// nothing else.
    public func registerPointerClaims() {
        for claim in resolvedPointerClaims() {
            addCursorRect(claim.rect, cursor: claim.cursor)
        }
    }

    /// Says the claims have moved. AppKit re-asks a view for its cursor rectangles when the
    /// *view's* geometry changes and at no other time, so a card whose rows changed inside an
    /// unchanged frame, or a field whose trailing controls appeared, has to say so itself.
    public func refreshPointerClaims() {
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - Carving

/// Rectangle subtraction, so no conformer has to write it again.
///
/// A horizontal-band decomposition rather than the four-rectangles-around-one shape it replaces:
/// the simple case gives the same four, and a view with many claims — an annotation overlay's
/// markers — stays bounded instead of splitting each piece against each hole in turn.
public enum PointerRectCarving {

    /// `rect` with every hole removed, as non-overlapping rectangles.
    public static func subtract(_ holes: [NSRect], from rect: NSRect) -> [NSRect] {
        guard !rect.isEmpty else { return [] }
        let holes = holes.compactMap { hole -> NSRect? in
            let clipped = hole.intersection(rect)
            return clipped.isEmpty ? nil : clipped
        }
        guard !holes.isEmpty else { return [rect] }

        var edges = Set([rect.minY, rect.maxY])
        for hole in holes {
            edges.insert(hole.minY)
            edges.insert(hole.maxY)
        }
        let bands = edges.sorted()

        var pieces: [NSRect] = []
        for (low, high) in zip(bands, bands.dropFirst()) where high > low {
            let spans = holes
                .filter { $0.minY < high && $0.maxY > low }
                .map { ($0.minX, $0.maxX) }
                .sorted { $0.0 < $1.0 }
            var x = rect.minX
            for span in spans {
                if span.0 > x {
                    pieces.append(NSRect(x: x, y: low, width: span.0 - x, height: high - low))
                }
                x = max(x, span.1)
            }
            if x < rect.maxX {
                pieces.append(NSRect(x: x, y: low, width: rect.maxX - x, height: high - low))
            }
        }
        return fused(pieces)
    }

    /// Bands that left the same horizontal run are one rectangle, not two stacked. Cosmetic for
    /// correctness and not for it: a claim is registered per rectangle, and a view that hands
    /// AppKit a stack of one-band slivers is paying for the decomposition every reset.
    private static func fused(_ pieces: [NSRect]) -> [NSRect] {
        var fused: [NSRect] = []
        for piece in pieces.sorted(by: { ($0.minX, $0.minY) < ($1.minX, $1.minY) }) {
            if let last = fused.last,
               last.minX == piece.minX,
               last.width == piece.width,
               last.maxY == piece.minY {
                fused[fused.count - 1].size.height += piece.height
                continue
            }
            fused.append(piece)
        }
        return fused
    }
}
