import XCTest
@testable import Threading

/// The diff a tool row shows, built from the call's own arguments before the tool has run.
///
/// Two things are worth pinning. The **alignment** decides what a reader sees as changed: an
/// LCS walk that drifts turns a one-line edit into a whole-block rewrite, which is not wrong so
/// much as unreadable — and it is the same view the permission sheet shows, so it is what an
/// approval is given on. And the **argument reading** is where two providers disagree: Codex
/// states a change as a patch, Claude as two strings, and a rule that reads the tool name first
/// mistakes one for the other.
final class EditDiffTests: XCTestCase {

    // MARK: - Alignment

    private func kinds(_ lines: [DiffLine]) -> [DiffLine.Kind] { lines.map(\.kind) }
    private func texts(_ lines: [DiffLine], _ kind: DiffLine.Kind) -> [String] {
        lines.filter { $0.kind == kind }.map(\.text)
    }

    /// The case that makes the whole alignment worth having: one line changed inside a block
    /// that did not. Everything else must stay context, or a reader has to find the change
    /// themselves in a wall of red and green.
    func testOneChangedLineLeavesTheRestAsContext() {
        let lines = EditDiff.diff(
            "alpha\nbeta\ngamma",
            "alpha\nBETA\ngamma"
        )

        XCTAssertEqual(kinds(lines), [.context, .removed, .added, .context])
        XCTAssertEqual(texts(lines, .removed), ["beta"])
        XCTAssertEqual(texts(lines, .added), ["BETA"])
    }

    func testAnInsertionAddsWithoutRemoving() {
        let lines = EditDiff.diff("alpha\ngamma", "alpha\nbeta\ngamma")

        XCTAssertEqual(kinds(lines), [.context, .added, .context])
        XCTAssertEqual(EditDiff.counts(lines).removed, 0)
    }

    func testADeletionRemovesWithoutAdding() {
        let lines = EditDiff.diff("alpha\nbeta\ngamma", "alpha\ngamma")

        XCTAssertEqual(kinds(lines), [.context, .removed, .context])
        XCTAssertEqual(EditDiff.counts(lines).added, 0)
    }

    /// Identical text is not a diff at all: every line is context and the counters read zero,
    /// which is what makes "+0 −0" an honest answer rather than a rendering accident.
    func testUnchangedTextIsAllContext() {
        let lines = EditDiff.diff("same\ntext", "same\ntext")

        XCTAssertEqual(kinds(lines), [.context, .context])
        XCTAssertEqual(EditDiff.counts(lines).added, 0)
        XCTAssertEqual(EditDiff.counts(lines).removed, 0)
    }

    /// A repeated line must not let the walk pair the *wrong* occurrences, which is the classic
    /// way an LCS diff drifts: the change reads as happening several lines from where it did.
    func testRepeatedLinesDoNotDriftTheAlignment() {
        let lines = EditDiff.diff(
            "x\nx\nx\nend",
            "x\nx\nx\nx\nend"
        )

        XCTAssertEqual(texts(lines, .added), ["x"])
        XCTAssertTrue(texts(lines, .removed).isEmpty, "an insertion was rendered as a rewrite")
        XCTAssertEqual(lines.last?.kind, .context, "the unchanged tail stopped being context")
    }

    /// Past the cap the table is skipped for a plain removed-then-added rendering. Correct, less
    /// tidy, and bounded — the alternative is a quadratic table on a whole-file replacement.
    func testAPairPastTheCapIsRenderedWithoutAligning() {
        let old = (0..<(DiffDefaults.alignmentCap + 1)).map(String.init).joined(separator: "\n")
        let new = old

        let lines = EditDiff.diff(old, new)

        XCTAssertTrue(
            texts(lines, .context).isEmpty,
            "the aligned walk ran on a pair past the cap"
        )
        let counts = EditDiff.counts(lines)
        XCTAssertEqual(counts.removed, DiffDefaults.alignmentCap + 1)
        XCTAssertEqual(counts.added, DiffDefaults.alignmentCap + 1)
    }

    // MARK: - Reading the call

    func testAnEditIsReadFromItsTwoStrings() throws {
        let lines = try XCTUnwrap(EditDiff.lines(
            forTool: "Edit",
            input: ["old_string": "before", "new_string": "after"]
        ))

        XCTAssertEqual(texts(lines, .removed), ["before"])
        XCTAssertEqual(texts(lines, .added), ["after"])
    }

    /// A write has no prior text in its arguments — whatever was there is not in the call — so
    /// every line reads as added rather than as a comparison against something invented.
    func testAWriteIsEntirelyAdded() throws {
        let lines = try XCTUnwrap(
            EditDiff.lines(forTool: "Write", input: ["content": "one\ntwo"])
        )

        XCTAssertEqual(kinds(lines), [.added, .added])
    }

    func testAMultiEditConcatenatesItsHunks() throws {
        let lines = try XCTUnwrap(EditDiff.lines(forTool: "MultiEdit", input: [
            "edits": [
                ["old_string": "a", "new_string": "A"],
                ["old_string": "b", "new_string": "B"]
            ]
        ]))

        XCTAssertEqual(texts(lines, .removed), ["a", "b"])
        XCTAssertEqual(texts(lines, .added), ["A", "B"])
    }

    /// A patch is read *before* the tool name is looked at. Codex's `apply_patch` reaches here
    /// renamed to `Edit` — see `ToolIdentity` — so a rule that switched on the name first would
    /// look for `old_string` in a call that has never carried one and show no diff at all.
    func testAPatchIsPreferredOverTheToolName() throws {
        let patch = """
        *** Begin Patch
        *** Update File: a.txt
        -old line
        +new line
        *** End Patch
        """

        let lines = try XCTUnwrap(EditDiff.lines(forTool: "Edit", input: ["patch": patch]))

        XCTAssertEqual(texts(lines, .removed), ["old line"])
        XCTAssertEqual(texts(lines, .added), ["new line"])
    }

    /// A tool that edits nothing has no diff, and neither does an edit whose arguments are
    /// missing — nil, so the row shows its output instead of an empty diff that claims a file
    /// changed by nothing.
    func testANonEditingOrIncompleteCallHasNoDiff() {
        XCTAssertNil(EditDiff.lines(forTool: "Bash", input: ["command": "ls"]))
        XCTAssertNil(EditDiff.lines(forTool: "Edit", input: ["old_string": "only one side"]))
        XCTAssertNil(EditDiff.lines(forTool: "Write", input: [:]))
    }
}
