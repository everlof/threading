//
//  CoreGraphicsRenderCacheTests.swift
//  SwiftTermTests
//
//  Production-path bounds for repeated AppKit exposes. macOS can turn a
//  narrow invalidation into a full-view draw; unchanged terminal rows must not
//  rebuild attributed strings, Core Text lines, run metadata, glyph metrics,
//  or contrast samples merely because the dirty rectangle grew.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
@Suite("Core Graphics render cache", .serialized)
struct CoreGraphicsRenderCacheTests {
    private func makeView(cols: Int = 32, rows: Int = 8) -> TerminalView {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 480, height: 200),
            font: nil,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 40))
        view.setFrameSize(CGSize(
            width: view.cellDimension.width * CGFloat(cols) + 1,
            height: view.cellDimension.height * CGFloat(rows) + 1))
        view.suspendsRenderingWhenNotVisible = false
        return view
    }

    @discardableResult
    private func render(_ view: TerminalView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func prepare(_ view: TerminalView) {
        view.frameTick()
    }

    @Test func repeatedFullExposeReusesRowsAndWideGlyphMetrics() throws {
        let view = makeView()
        view.feed(text: String(repeating: "界", count: 12) + "\r\nsteady row")
        prepare(view)
        let visibleRows = view.renderOwner.inspection().rowRevisions.count
        #expect(visibleRows > 1)

        view.resetDiagnostics()
        _ = try render(view)
        let first = view.diagnostics
        #expect(first.coreGraphicsRowsBuilt == visibleRows)
        #expect(first.coreGraphicsGlyphFitLookups > 0)
        #expect(first.coreGraphicsGlyphFitMisses > 0)

        _ = try render(view)
        let second = view.diagnostics
        #expect(second.coreGraphicsRowsBuilt == first.coreGraphicsRowsBuilt)
        #expect(second.coreGraphicsRowsReused >= visibleRows)
        #expect(second.coreGraphicsGlyphFitLookups > first.coreGraphicsGlyphFitLookups)
        #expect(second.coreGraphicsGlyphFitMisses == first.coreGraphicsGlyphFitMisses)
        #expect(second.coreGraphicsGlyphFitHits > first.coreGraphicsGlyphFitHits)
    }

    @Test func oneChangedRowRebuildsOneRowDuringAFullExpose() throws {
        let view = makeView()
        view.feed(text: "first\r\nsecond\r\nthird")
        prepare(view)
        _ = try render(view)
        let visibleRows = view.renderOwner.inspection().rowRevisions.count

        view.resetDiagnostics()
        view.feed(text: "\u{1b}[1;1HX")
        prepare(view)
        _ = try render(view)

        let counters = view.diagnostics
        #expect(counters.coreGraphicsRowsBuilt == 1)
        #expect(counters.coreGraphicsRowsReused >= visibleRows - 1)
    }

    @Test func selectionAndAppearanceInvalidateEveryAffectedRow() throws {
        let view = makeView()
        view.feed(text: "select this\r\nthen recolor this")
        prepare(view)
        _ = try render(view)
        let visibleRows = view.renderOwner.inspection().rowRevisions.count

        view.selection.startSelection(row: 0, col: 0)
        view.selection.dragExtend(bufferPosition: Position(col: 6, row: 0))
        prepare(view)
        view.resetDiagnostics()
        _ = try render(view)
        #expect(view.diagnostics.coreGraphicsRowsBuilt == visibleRows)

        view.nativeForegroundColor = .systemRed
        prepare(view)
        view.resetDiagnostics()
        _ = try render(view)
        #expect(view.diagnostics.coreGraphicsRowsBuilt == visibleRows)
    }

    @Test func bidiParagraphEditRebuildsItsDependenciesButReusesOtherRows() throws {
        let view = makeView(cols: 10, rows: 8)
        view.feed(text: String(repeating: "ב", count: 24) + "\r\nunrelated")
        prepare(view)
        _ = try render(view)

        view.resetDiagnostics()
        view.feed(text: "\u{1b}[2;2Hמ")
        prepare(view)
        _ = try render(view)

        let counters = view.diagnostics
        #expect(counters.coreGraphicsRowsBuilt >= 3)
        #expect(counters.coreGraphicsRowsReused > 0)
    }

    @Test func contrastDetectorScansOnlyAChangedRowThenInvalidatesForAppearance() {
        let view = makeView()
        view.onLowContrastText = { _ in }
        view.feed(text: "first\r\nsecond\r\nthird")
        prepare(view)
        let visibleRows = view.renderOwner.inspection().rowRevisions.count

        view.resetDiagnostics()
        view.feed(text: "x")
        prepare(view)
        let changed = view.diagnostics
        #expect(changed.contrastRowsScanned == 1)
        #expect(changed.contrastRowsReused == visibleRows - 1)

        view.resetDiagnostics()
        view.nativeForegroundColor = .systemPurple
        prepare(view)
        let recolored = view.diagnostics
        #expect(recolored.contrastRowsScanned == visibleRows)
        #expect(recolored.contrastRowsReused == 0)
    }
}
#endif
