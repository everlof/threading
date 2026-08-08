import XCTest
import ThreadingRemoteKit
@testable import Threading

/// The validators every remote message passes through before it reaches the main actor.
///
/// These are the app's network boundary: the values here arrive from a phone over a tunnel, and
/// each `accepts…` / `normalized…` answer decides whether a string becomes a keystroke, a
/// prompt, a device identity, or a row in the Revoke list. The interesting cases are all at the
/// edges — one byte over a cap, a control character hidden in the middle, a limit counted in
/// characters when the field is specified in bytes — so that is what this file is.
///
/// Every limit is stated in **UTF-8 bytes**, which is the point of the multi-byte cases below:
/// `count` and `utf8.count` agree on ASCII and diverge on everything else, so an ASCII-only test
/// cannot tell a correct implementation from one measuring the wrong thing.
final class RemoteInboundPolicyTests: XCTestCase {

    // MARK: - Mutation request id

    /// Printable ASCII only, so the id can be echoed into a log line or a header without
    /// carrying a newline or a terminal escape with it.
    func testMutationRequestIDAcceptsOnlyPrintableASCII() {
        XCTAssertEqual(RemoteInboundPolicy.normalizedMutationRequestID("  abc-123  "), "abc-123")
        XCTAssertEqual(RemoteInboundPolicy.normalizedMutationRequestID("!~"), "!~")

        for rejected in [
            "",                 // empty
            "   ",              // whitespace only
            "has space",        // 0x20 is below the printable floor
            "tab\there",
            "line\nbreak",
            "nul\u{00}byte",
            "bell\u{07}",
            "del\u{7f}",        // 0x7f is above the printable ceiling
            "café",             // non-ASCII
            "emoji😀"
        ] {
            XCTAssertNil(
                RemoteInboundPolicy.normalizedMutationRequestID(rejected),
                "should have been refused: \(rejected.debugDescription)"
            )
        }
        XCTAssertNil(RemoteInboundPolicy.normalizedMutationRequestID(nil))
    }

    func testMutationRequestIDLengthIsCountedInBytesAtTheBoundary() {
        let limit = RemoteAccessDefaults.maximumMutationRequestIDBytes
        XCTAssertNotNil(RemoteInboundPolicy.normalizedMutationRequestID(String(repeating: "a", count: limit)))
        XCTAssertNil(RemoteInboundPolicy.normalizedMutationRequestID(String(repeating: "a", count: limit + 1)))
    }

    // MARK: - Device id

    /// The device id is the bound identity, so its alphabet is a closed list rather than
    /// "whatever is not obviously dangerous".
    func testDeviceIDAcceptsOnlyItsClosedAlphabet() {
        XCTAssertEqual(RemoteInboundPolicy.normalizedDeviceID(" A-z0.9:_ "), "A-z0.9:_")

        for rejected in ["", "  ", "has space", "slash/es", "plus+", "café", "😀", "semi;colon", "at@sign"] {
            XCTAssertNil(
                RemoteInboundPolicy.normalizedDeviceID(rejected),
                "should have been refused: \(rejected.debugDescription)"
            )
        }
        XCTAssertNil(RemoteInboundPolicy.normalizedDeviceID(nil))
    }

    func testDeviceIDLengthIsCountedInBytesAtTheBoundary() {
        let limit = RemoteAccessDefaults.maximumDeviceIDBytes
        XCTAssertNotNil(RemoteInboundPolicy.normalizedDeviceID(String(repeating: "a", count: limit)))
        XCTAssertNil(RemoteInboundPolicy.normalizedDeviceID(String(repeating: "a", count: limit + 1)))
    }

    // MARK: - Member and device names

    /// A display name is shown beside a Revoke button, so control characters are removed rather
    /// than refused, and runs of whitespace collapse to one space.
    ///
    /// **`\n` and `\t` are removed, not turned into spaces**, and that is worth stating because
    /// it is the opposite of what the shape of the code suggests. The control-character test
    /// runs first and ASCII whitespace *is* control-character range, so `line\nbreak` becomes
    /// `linebreak` — words merge rather than separate. It is safe that it does: this value
    /// authorizes nothing (the device id is the bound identity), so two names colliding costs a
    /// person one confusing row in the Revoke list and nothing more.
    func testMemberNameStripsControlsAndCollapsesWhitespace() {
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("  David's   iPhone  "), "David's iPhone")
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("a\u{00}b"), "ab")
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("line\nbreak"), "linebreak")
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("tab\t\tsplit"), "tabsplit")
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("esc\u{1B}[31mred"), "esc[31mred")
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("Café ☕️"), "Café ☕️")

        // The whitespace branch is reachable, just narrower than it looks: it sees the spacing
        // characters that are not also control characters. A no-break space is the common one,
        // and it must not survive into the name as an invisible non-space.
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("a\u{00A0}\u{00A0}b"), "a b")
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName("a\u{3000}b"), "a b")

        // Nothing printable survives, so there is no name to show.
        for empty in ["", "   ", "\n\t ", "\u{00}\u{01}\u{02}"] {
            XCTAssertNil(
                RemoteInboundPolicy.normalizedMemberName(empty),
                "should have been refused: \(empty.debugDescription)"
            )
        }
        XCTAssertNil(RemoteInboundPolicy.normalizedMemberName(nil))
    }

    /// The cap is on the normalized answer, and it is in bytes — so a name of multi-byte
    /// characters is allowed fewer characters than an ASCII one, which is the whole distinction
    /// an ASCII-only test would miss.
    func testMemberNameLengthIsCountedInBytesNotCharacters() {
        let limit = RemoteAccessDefaults.maximumMemberNameBytes
        XCTAssertNotNil(RemoteInboundPolicy.normalizedMemberName(String(repeating: "a", count: limit)))
        XCTAssertNil(RemoteInboundPolicy.normalizedMemberName(String(repeating: "a", count: limit + 1)))

        // "é" is two UTF-8 bytes: half as many fit, and one more than that does not.
        let wide = String(repeating: "é", count: limit / 2)
        XCTAssertEqual(wide.utf8.count, limit)
        XCTAssertNotNil(RemoteInboundPolicy.normalizedMemberName(wide))
        XCTAssertNil(RemoteInboundPolicy.normalizedMemberName(wide + "é"))
    }

    /// Whitespace collapsing happens before the cap, so padding that collapses away is not
    /// counted against a name that is otherwise short enough.
    func testWhitespaceThatCollapsesDoesNotCountAgainstTheCap() {
        let padded = "a" + String(repeating: " ", count: 400) + "b"
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName(padded), "a b")
    }

    /// The work is one `String` per scalar, and the length that decides the answer is the
    /// normalized one — so without an input bound a frame-sized name is normalized in full
    /// before being refused. A megabyte of spaces is the cheapest way to ask for that.
    func testAFrameSizedNameIsRefusedWithoutNormalizingIt() {
        let huge = String(repeating: " ", count: RemoteAccessDefaults.maximumFrameBytes)
        XCTAssertNil(RemoteInboundPolicy.normalizedMemberName(huge))

        let hugeWithContent = "a" + String(repeating: " ", count: RemoteAccessDefaults.maximumFrameBytes) + "b"
        XCTAssertNil(
            RemoteInboundPolicy.normalizedMemberName(hugeWithContent),
            "a frame-sized name must be refused on its input size, not normalized first"
        )

        // The bound is generous enough that ordinary padding still collapses rather than being
        // refused — the two tests together pin where the line sits.
        let tolerated = "a" + String(repeating: " ", count: RemoteAccessDefaults.maximumNameInputBytes - 2) + "b"
        XCTAssertEqual(tolerated.utf8.count, RemoteAccessDefaults.maximumNameInputBytes)
        XCTAssertEqual(RemoteInboundPolicy.normalizedMemberName(tolerated), "a b")
    }

    /// A device's label is held to exactly the member-name rules, and says so by delegating.
    func testDeviceNameFollowsTheMemberNameRules() {
        XCTAssertEqual(RemoteInboundPolicy.normalizedDeviceName("  Pixel\n 9  "), "Pixel 9")
        XCTAssertNil(RemoteInboundPolicy.normalizedDeviceName("   "))
    }

    // MARK: - Size-only ceilings

    /// These fields carry arbitrary text and are bounded only by weight. Empty is meaningful for
    /// some (a keystroke of nothing, a cleared title) and not for others (an id naming nothing),
    /// which is the distinction worth pinning.
    func testSizeCeilingsAndTheirEmptyCases() {
        let cases: [(name: String, limit: Int, allowsEmpty: Bool, accepts: (String) -> Bool)] = [
            ("bearer token", RemoteAccessDefaults.maximumBearerTokenBytes, false,
             RemoteInboundPolicy.acceptsBearerToken),
            ("terminal input", RemoteAccessDefaults.maximumTerminalInputBytes, true,
             RemoteInboundPolicy.acceptsTerminalInput),
            ("prompt", RemoteAccessDefaults.maximumPromptBytes, true,
             RemoteInboundPolicy.acceptsPrompt),
            ("permission id", RemoteAccessDefaults.maximumPermissionIDBytes, false,
             RemoteInboundPolicy.acceptsPermissionID),
            ("conversation row id", RemoteAccessDefaults.maximumPermissionIDBytes, false,
             RemoteInboundPolicy.acceptsConversationRowID),
            ("theme id", RemoteAccessDefaults.maximumThemeIDBytes, false,
             RemoteInboundPolicy.acceptsThemeID),
            ("session title", RemoteAccessDefaults.maximumSessionTitleBytes, true,
             RemoteInboundPolicy.acceptsSessionTitle),
            ("launch identifier", RemoteAccessDefaults.maximumLaunchIdentifierBytes, false,
             RemoteInboundPolicy.acceptsLaunchIdentifier),
            ("repository path", RemoteAccessDefaults.maximumRepositoryPathBytes, false,
             RemoteInboundPolicy.acceptsRepositoryPath)
        ]

        for entry in cases {
            XCTAssertEqual(entry.accepts(""), entry.allowsEmpty, "\(entry.name): empty case")
            XCTAssertTrue(
                entry.accepts(String(repeating: "a", count: entry.limit)),
                "\(entry.name): exactly at the limit must be accepted"
            )
            XCTAssertFalse(
                entry.accepts(String(repeating: "a", count: entry.limit + 1)),
                "\(entry.name): one byte over the limit must be refused"
            )
            // Counted in bytes: a multi-byte string of half the character count still fills it.
            XCTAssertFalse(
                entry.accepts(String(repeating: "é", count: entry.limit)),
                "\(entry.name): the limit is bytes, not characters"
            )
        }
    }

    /// A repository path reaches a file read, so a NUL — which truncates a C string and can make
    /// the byte-level path differ from the one that was checked — is refused outright.
    func testRepositoryPathRefusesEmbeddedNUL() {
        XCTAssertTrue(RemoteInboundPolicy.acceptsRepositoryPath("Sources/App.swift"))
        XCTAssertFalse(RemoteInboundPolicy.acceptsRepositoryPath("Sources/App.swift\u{00}.png"))
        XCTAssertFalse(RemoteInboundPolicy.acceptsRepositoryPath("\u{00}"))
    }

    func testExtensionPanelIdentifiersUseTheSDKAlphabetAndRemoteByteLimit() {
        XCTAssertTrue(RemoteInboundPolicy.acceptsExtensionIdentifier("codes.threading.progress"))
        XCTAssertTrue(RemoteInboundPolicy.acceptsExtensionIdentifier("build-status"))
        for rejected in ["", "Uppercase", "has space", "path/name", "emoji-😀"] {
            XCTAssertFalse(RemoteInboundPolicy.acceptsExtensionIdentifier(rejected))
        }

        let limit = RemoteAccessDefaults.maximumPermissionIDBytes
        XCTAssertTrue(RemoteInboundPolicy.acceptsExtensionIdentifier(
            String(repeating: "a", count: limit)
        ))
        XCTAssertFalse(RemoteInboundPolicy.acceptsExtensionIdentifier(
            String(repeating: "a", count: limit + 1)
        ))
    }

    func testExtensionResourcesAcceptOnlyBoundedSafeRelativePaths() {
        XCTAssertTrue(RemoteInboundPolicy.acceptsExtensionResourcePath("Images/status.png"))
        for rejected in ["", "/tmp/status.png", "../status.png", "Images/../status.png", "a\u{00}b"] {
            XCTAssertFalse(
                RemoteInboundPolicy.acceptsExtensionResourcePath(rejected),
                "should have been refused: \(rejected.debugDescription)"
            )
        }
    }

    // MARK: - Attention requests

    func testAttentionRecipientRefusesControlAndWhitespace() {
        XCTAssertTrue(RemoteInboundPolicy.acceptsAttentionRecipientID("member-7"))
        for rejected in ["", "has space", "tab\there", "line\nbreak", "nul\u{00}"] {
            XCTAssertFalse(
                RemoteInboundPolicy.acceptsAttentionRecipientID(rejected),
                "should have been refused: \(rejected.debugDescription)"
            )
        }
    }

    func testAttentionNoteRefusesNULAndOversize() {
        let limit = RemoteAttentionDefaults.maximumNoteUTF8Bytes
        XCTAssertTrue(RemoteInboundPolicy.acceptsAttentionNote(""))
        XCTAssertTrue(RemoteInboundPolicy.acceptsAttentionNote(String(repeating: "a", count: limit)))
        XCTAssertFalse(RemoteInboundPolicy.acceptsAttentionNote(String(repeating: "a", count: limit + 1)))
        XCTAssertFalse(RemoteInboundPolicy.acceptsAttentionNote("look\u{00}here"))
    }

    /// The note is displayed, so it is normalized like a name — and an oversize note is refused
    /// by the accept check before any of that work happens.
    func testAttentionNoteNormalizesLikeAName() {
        XCTAssertEqual(RemoteInboundPolicy.normalizedAttentionNote("  please   look  "), "please look")
        // Same control-first ordering as a name: the newlines vanish rather than separating.
        XCTAssertEqual(RemoteInboundPolicy.normalizedAttentionNote("please\n\nlook"), "pleaselook")
        XCTAssertNil(RemoteInboundPolicy.normalizedAttentionNote("   "))
        XCTAssertNil(RemoteInboundPolicy.normalizedAttentionNote(nil))
        XCTAssertNil(RemoteInboundPolicy.normalizedAttentionNote("has\u{00}nul"))
        XCTAssertNil(RemoteInboundPolicy.normalizedAttentionNote(
            String(repeating: "a", count: RemoteAttentionDefaults.maximumNoteUTF8Bytes + 1)
        ))
    }
}
