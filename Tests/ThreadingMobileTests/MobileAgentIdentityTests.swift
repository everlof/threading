import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

/// The phone's runtime vocabulary. Two defects are pinned here: every chat row drew the terminal
/// glyph and so identified no provider at all, and every runtime that was not Claude was named
/// "Codex" — a two-provider assumption written as `agentKind == "claude" ? … : …` in four places.
final class MobileAgentIdentityTests: XCTestCase {

    func testEveryRuntimeThisBuildKnowsIsNamedAfterItself() {
        XCTAssertEqual(MobileAgentIdentity.resolve("claude").displayName, "Claude Code")
        XCTAssertEqual(MobileAgentIdentity.resolve("codex").displayName, "Codex")
        XCTAssertEqual(MobileAgentIdentity.resolve("grok").displayName, "Grok")
        XCTAssertEqual(MobileAgentIdentity.resolve("opencode").displayName, "OpenCode")
        XCTAssertEqual(MobileAgentIdentity.resolve("cursor").displayName, "Cursor")
    }

    /// A Grok session used to be labelled "Codex UI", because the surface title asked only whether
    /// the runtime was Claude. Nothing may fall back to another runtime's name.
    func testARuntimeThisBuildDoesNotKnowKeepsItsOwnNameRatherThanBorrowingCodex() {
        let identity = MobileAgentIdentity.resolve("someagent")

        XCTAssertEqual(identity, .unknown("someagent"))
        XCTAssertEqual(identity.displayName, "Someagent")
        XCTAssertFalse(identity.originalUITitle.contains("Codex"))
        XCTAssertTrue(identity.originalUITitle.contains("Someagent"))
    }

    func testTheTUITitleNamesTheRuntimeWhoseTUIItIs() {
        XCTAssertTrue(MobileAgentIdentity.resolve("grok").originalUITitle.contains("Grok"))
        XCTAssertTrue(MobileAgentIdentity.resolve("cursor").originalUITitle.contains("Cursor"))
    }

    /// The row's tile carries identity, so it must never be a surface glyph. Claude and OpenAI ship
    /// their own marks; the runtimes we bundle no artwork for fall to a symbol, never to `terminal`.
    func testTheMarkIdentifiesTheRuntimeAndIsNeverATerminalGlyph() {
        XCTAssertEqual(
            MobileAgentIdentity.resolve("claude").mark,
            .brand(asset: MobileAgentMarkAssets.claude, keepsItsOwnColour: true)
        )
        XCTAssertEqual(
            MobileAgentIdentity.resolve("codex").mark,
            .brand(asset: MobileAgentMarkAssets.codex, keepsItsOwnColour: false)
        )

        for kind in ["claude", "codex", "grok", "opencode", "cursor", "someagent"] {
            switch MobileAgentIdentity.resolve(kind).mark {
            case .brand: continue
            case .symbol(let name):
                XCTAssertNotEqual(name, "terminal", "\(kind) took a surface glyph as its identity")
                XCTAssertFalse(name.isEmpty)
            }
        }
    }

    /// OpenAI's knot is monochrome by design and tints with the slot it sits in, which is what keeps
    /// it visible under a light theme. Claude's coral mark is drawn as authored. Losing that
    /// distinction is how the knot went invisible on the Mac before.
    func testOnlyTheMonochromeMarkTintsWithItsSurroundings() {
        guard case .brand(_, let claudeKeepsColour) =
            MobileAgentIdentity.resolve("claude").mark,
            case .brand(_, let codexKeepsColour) =
                MobileAgentIdentity.resolve("codex").mark else {
            return XCTFail("both bundled marks should be brand artwork")
        }

        XCTAssertTrue(claudeKeepsColour)
        XCTAssertFalse(codexKeepsColour)
    }

    // MARK: - Account chip

    func testAnEmojiChipBringsItsOwnColourAndAnInitialChipDoesNot() {
        let emoji = RemoteSessionAccountDTO(
            name: "Sandbox",
            glyph: "🧪",
            isEmoji: true,
            hue: nil
        )
        let initial = RemoteSessionAccountDTO(
            name: "Vera Keller",
            glyph: "V",
            isEmoji: false,
            hue: 0.72
        )

        XCTAssertNil(emoji.hue)
        XCTAssertNotNil(initial.hue)
        XCTAssertEqual(initial.glyph.count, 1, "a chip this small holds one character")
    }
}
