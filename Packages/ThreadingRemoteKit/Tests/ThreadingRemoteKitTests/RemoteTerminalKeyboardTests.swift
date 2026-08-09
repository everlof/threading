import XCTest
@testable import ThreadingRemoteKit

final class RemoteTerminalKeyboardTests: XCTestCase {

    // MARK: - Encoder: named keys

    func testPlainKeysSpellTheirClassicSequences() {
        XCTAssertEqual(bytes(.named(.escape, [])), [0x1b])
        XCTAssertEqual(bytes(.named(.tab, [])), [0x09])
        XCTAssertEqual(bytes(.named(.enter, [])), [0x0d])
        XCTAssertEqual(bytes(.named(.backspace, [])), [0x7f])
        XCTAssertEqual(bytes(.named(.up, [])), csi("A"))
        XCTAssertEqual(bytes(.named(.down, [])), csi("B"))
        XCTAssertEqual(bytes(.named(.right, [])), csi("C"))
        XCTAssertEqual(bytes(.named(.left, [])), csi("D"))
        XCTAssertEqual(bytes(.named(.home, [])), csi("H"))
        XCTAssertEqual(bytes(.named(.end, [])), csi("F"))
        XCTAssertEqual(bytes(.named(.pageUp, [])), csi("5~"))
        XCTAssertEqual(bytes(.named(.pageDown, [])), csi("6~"))
        XCTAssertEqual(bytes(.named(.forwardDelete, [])), csi("3~"))
    }

    /// The fixed bar this replaces hardcoded normal-mode arrows; a full-screen TUI that
    /// enables DECCKM expects SS3 arrows, and SwiftTerm's own key handling honours that.
    func testApplicationCursorModeSwitchesArrowsHomeAndEndToSS3() {
        XCTAssertEqual(bytes(.named(.up, []), applicationCursor: true), [0x1b, 0x4f, 0x41])
        XCTAssertEqual(bytes(.named(.left, []), applicationCursor: true), [0x1b, 0x4f, 0x44])
        XCTAssertEqual(bytes(.named(.home, []), applicationCursor: true), [0x1b, 0x4f, 0x48])
        XCTAssertEqual(bytes(.named(.end, []), applicationCursor: true), [0x1b, 0x4f, 0x46])
        // Page keys have no SS3 form; they stay CSI in both modes.
        XCTAssertEqual(bytes(.named(.pageUp, []), applicationCursor: true), csi("5~"))
    }

    func testModifiedCursorKeysTakeTheCSIFormInBothModes() {
        XCTAssertEqual(bytes(.named(.up, .control)), csi("1;5A"))
        XCTAssertEqual(bytes(.named(.up, .control), applicationCursor: true), csi("1;5A"))
        XCTAssertEqual(bytes(.named(.right, [.alt])), csi("1;3C"))
        XCTAssertEqual(bytes(.named(.left, [.shift, .control])), csi("1;6D"))
        XCTAssertEqual(bytes(.named(.pageDown, .control)), csi("6;5~"))
    }

    /// The one key Termius cannot put on its bar, and the reason this feature exists for
    /// Claude Code: Shift+Tab is CSI Z.
    func testShiftTabIsBackTab() {
        XCTAssertEqual(bytes(.named(.tab, .shift)), csi("Z"))
    }

    func testFunctionKeysSpellSS3AndTildeForms() {
        XCTAssertEqual(bytes(.named(.f1, [])), [0x1b, 0x4f, 0x50])
        XCTAssertEqual(bytes(.named(.f4, [])), [0x1b, 0x4f, 0x53])
        XCTAssertEqual(bytes(.named(.f1, .control)), csi("1;5P"))
        XCTAssertEqual(bytes(.named(.f5, [])), csi("15~"))
        XCTAssertEqual(bytes(.named(.f12, [])), csi("24~"))
        XCTAssertEqual(bytes(.named(.f12, .shift)), csi("24;2~"))
    }

    // MARK: - Encoder: latched modifiers folding into bar keys

    func testLatchedModifiersFoldIntoANamedKey() {
        XCTAssertEqual(
            RemoteTerminalKeyEncoder.bytes(for: .named(.up, []), latched: .control),
            csi("1;5A")
        )
        XCTAssertEqual(
            RemoteTerminalKeyEncoder.bytes(for: .named(.tab, []), latched: [.shift]),
            csi("Z")
        )
    }

    func testLatchActionProducesNoBytes() {
        XCTAssertNil(RemoteTerminalKeyEncoder.bytes(for: .latch(.control)))
        XCTAssertNil(RemoteTerminalKeyEncoder.bytes(for: .latch(.alt)))
    }

    // MARK: - Encoder: snippets and raw sequences

    func testSnippetTypesItsTextAndOptionallySubmits() {
        XCTAssertEqual(
            bytes(.snippet(text: "git status", submits: false)),
            Array("git status".utf8)
        )
        XCTAssertEqual(
            bytes(.snippet(text: "/compact", submits: true)),
            Array("/compact".utf8) + [0x0d]
        )
    }

    func testRawSequencePassesThroughVerbatim() {
        XCTAssertEqual(bytes(.sequence("\u{1b}[200~")), Array("\u{1b}[200~".utf8))
    }

    // MARK: - Encoder: transforming typed input under a latch

    func testControlLatchFoldsATypedLetterToItsControlByte() {
        XCTAssertEqual(RemoteTerminalKeyEncoder.applyLatched(.control, toTyped: [0x63]), [0x03])
        XCTAssertEqual(RemoteTerminalKeyEncoder.applyLatched(.control, toTyped: [0x43]), [0x03])
        XCTAssertEqual(RemoteTerminalKeyEncoder.applyLatched(.control, toTyped: [0x20]), [0x00])
        XCTAssertEqual(RemoteTerminalKeyEncoder.applyLatched(.control, toTyped: [0x5b]), [0x1b])
    }

    func testAltLatchPrefixesEscapeAndComposesWithControl() {
        XCTAssertEqual(
            RemoteTerminalKeyEncoder.applyLatched([.alt], toTyped: Array("b".utf8)),
            [0x1b, 0x62]
        )
        XCTAssertEqual(
            RemoteTerminalKeyEncoder.applyLatched([.control, .alt], toTyped: Array("c".utf8)),
            [0x1b, 0x03]
        )
    }

    func testUntransformableTypedInputPassesThroughUnchanged() {
        let emoji = Array("🙂".utf8)
        XCTAssertEqual(RemoteTerminalKeyEncoder.applyLatched(.control, toTyped: emoji), emoji)
        let arrow: [UInt8] = [0x1b, 0x5b, 0x41]
        XCTAssertEqual(RemoteTerminalKeyEncoder.applyLatched(.control, toTyped: arrow), arrow)
        let period: [UInt8] = [0x2e]
        XCTAssertEqual(RemoteTerminalKeyEncoder.applyLatched(.control, toTyped: period), period)
    }

    // MARK: - Latch state

    func testATapArmsASecondLocksAndAThirdReleases() {
        var state = RemoteTerminalLatchState()
        state.tap(.control)
        XCTAssertEqual(state.phase(of: .control), .armed)
        state.tap(.control)
        XCTAssertEqual(state.phase(of: .control), .locked)
        state.tap(.control)
        XCTAssertEqual(state.phase(of: .control), .off)
    }

    func testAnArmedModifierSpendsItselfWhereALockedOneHolds() {
        var state = RemoteTerminalLatchState()
        state.tap(.control)
        state.tap(.alt)
        state.tap(.alt)
        XCTAssertEqual(state.heldModifiers, [.control, .alt])
        state.consumeArmed()
        XCTAssertEqual(state.phase(of: .control), .off)
        XCTAssertEqual(state.phase(of: .alt), .locked)
        XCTAssertEqual(state.heldModifiers, [.alt])
        XCTAssertFalse(state.isIdle)
    }

    // MARK: - Layout model

    func testKeyDefinitionRoundTripsThroughJSON() throws {
        let layout = RemoteTerminalKeyboardLayout(keys: [
            RemoteTerminalKeyDefinition(action: .named(.tab, [.shift, .control])),
            RemoteTerminalKeyDefinition(customLabel: "int", action: .sequence("\u{3}")),
            RemoteTerminalKeyDefinition(action: .snippet(text: "/review", submits: true)),
            RemoteTerminalKeyDefinition(action: .latch(.alt)),
        ])
        let decoded = try JSONDecoder().decode(
            RemoteTerminalKeyboardLayout.self,
            from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(decoded, layout)
    }

    /// An action kind this build does not know must refuse to decode — a key that cannot
    /// say what it does has no business on a bar that writes to a PTY.
    func testAnUnknownActionKindFailsToDecode() {
        let payload = Data(#"{"keys":[{"id":"6F1E9C7A-1111-2222-3333-444455556666","action":{"kind":"macro","text":"x"}}]}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(RemoteTerminalKeyboardLayout.self, from: payload)
        )
    }

    func testACustomLabelWinsAndAnEmptyOneDoesNot() {
        XCTAssertEqual(
            RemoteTerminalKeyDefinition(customLabel: "mode", action: .named(.tab, .shift)).label,
            "mode"
        )
        XCTAssertEqual(
            RemoteTerminalKeyDefinition(customLabel: "", action: .named(.tab, .shift)).label,
            "⇧tab"
        )
        XCTAssertEqual(
            RemoteTerminalKeyDefinition(action: .named(.up, .control)).label,
            "⌃↑"
        )
    }

    // MARK: - Standard layouts

    func testEveryStandardLayoutKeepsTheFamiliarCoreAndTheLatches() {
        for kind in ["claude", "codex", "grok", "opencode", "unknown"] {
            let layout = RemoteTerminalKeyboardLayout.standard(forAgentKind: kind)
            let actions = layout.keys.map(\.action)
            XCTAssertEqual(actions.first, .named(.escape, []), "esc leads for \(kind)")
            XCTAssertTrue(actions.contains(.named(.tab, [])), "tab present for \(kind)")
            XCTAssertTrue(actions.contains(.latch(.control)), "⌃ latch present for \(kind)")
            XCTAssertTrue(actions.contains(.latch(.alt)), "⌥ latch present for \(kind)")
            for arrow: RemoteTerminalKeyAction in [
                .named(.up, []), .named(.down, []), .named(.left, []), .named(.right, []),
            ] {
                XCTAssertTrue(actions.contains(arrow), "arrows present for \(kind)")
            }
        }
    }

    func testClaudeAloneLeadsWithThePermissionModeCycle() {
        let claude = RemoteTerminalKeyboardLayout.standard(forAgentKind: "claude")
        XCTAssertEqual(claude.keys[1].action, .named(.tab, .shift))
        for kind in ["codex", "grok", "opencode"] {
            let layout = RemoteTerminalKeyboardLayout.standard(forAgentKind: kind)
            XCTAssertFalse(
                layout.keys.map(\.action).contains(.named(.tab, .shift)),
                "\(kind) has no ⇧⇥ by default"
            )
        }
    }

    // MARK: - Helpers

    private func bytes(
        _ action: RemoteTerminalKeyAction,
        applicationCursor: Bool = false
    ) -> [UInt8]? {
        RemoteTerminalKeyEncoder.bytes(for: action, applicationCursor: applicationCursor)
    }

    private func csi(_ body: String) -> [UInt8] {
        [0x1b, 0x5b] + Array(body.utf8)
    }
}
