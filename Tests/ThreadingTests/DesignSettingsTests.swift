import XCTest
@testable import Threading

/// The seam that lets `UI/Design/` stop reaching for `AppSettings`.
///
/// The point of these is not that a protocol exists; it is that the design system *actually reads
/// through it*. A seam nothing consults is worse than no seam, because it reads as decoupled while
/// the singleton is still doing the work.
@MainActor
final class DesignSettingsTests: XCTestCase {

    private var previous: DesignSettingsReading!

    override func setUp() async throws {
        try await super.setUp()
        previous = DesignSettings.current
    }

    override func tearDown() async throws {
        DesignSettings.current = previous
        try await super.tearDown()
    }

    func testTheApplicationProviderIsInstalledByDefault() {
        XCTAssertTrue(
            previous is ApplicationDesignSettings,
            "Design should read the application's settings unless a test or story replaces them"
        )
    }

    /// `Design.Typography.scale` is the one number every point size in the design system passes through,
    /// so it is the honest place to prove the seam is load-bearing.
    func testTheTextScaleFollowsTheInstalledProvider() {
        let standard = StubDesignSettings(appTextSize: .standard)
        let large = StubDesignSettings(appTextSize: .large)

        let standardScale = DesignSettings.withSettings(standard) { Design.Typography.scale }
        let largeScale = DesignSettings.withSettings(large) { Design.Typography.scale }

        XCTAssertGreaterThan(
            largeScale,
            standardScale,
            "a larger app text size must reach the design system's one scale"
        )
    }

    func testTheFontOverrideFollowsTheInstalledProvider() {
        let none = StubDesignSettings(chromeFontFamily: nil)
        let named = StubDesignSettings(chromeFontFamily: "Menlo")

        let withoutOverride = DesignSettings.withSettings(none) {
            Design.Typography.heading(surface: .chrome).fontName
        }
        let withOverride = DesignSettings.withSettings(named) {
            Design.Typography.heading(surface: .chrome).fontName
        }

        XCTAssertNotEqual(
            withOverride,
            withoutOverride,
            "a chrome font override must reach the resolved font"
        )
    }

    func testTheProviderIsRestoredEvenWhenTheBodyThrows() {
        let installed = DesignSettings.current
        struct Boom: Error {}
        XCTAssertThrowsError(
            try DesignSettings.withSettings(StubDesignSettings()) { throw Boom() }
        )
        XCTAssertTrue(
            DesignSettings.current is ApplicationDesignSettings,
            "a throwing body must not leave a stub installed for every later test"
        )
        _ = installed
    }

    /// The five values are the whole contract. If one is added, this fails until it is stated,
    /// which is the reminder that the extractable surface just grew.
    func testTheProviderContractIsTheFiveNamedValues() {
        let stub = StubDesignSettings(
            appTextSize: .large,
            chromeFontFamily: "Menlo",
            conversationFontFamily: "Courier",
            promptReturnKey: .sends,
            chatNameMorphStyle: .crossfade
        )
        XCTAssertEqual(stub.appTextSize, .large)
        XCTAssertEqual(stub.chromeFontFamily, "Menlo")
        XCTAssertEqual(stub.conversationFontFamily, "Courier")
        XCTAssertEqual(stub.promptReturnKey, .sends)
        XCTAssertEqual(stub.chatNameMorphStyle, .crossfade)
    }
}

/// Stated preferences, so a test says what it depends on instead of inheriting the developer's.
@MainActor
struct StubDesignSettings: DesignSettingsReading {
    var appTextSize: AppTextSize = .standard
    var chromeFontFamily: String?
    var conversationFontFamily: String?
    var promptReturnKey: PromptReturnKey = .matchesComposer
    var chatNameMorphStyle: ChatNameMorphStyle = MotionPreferencesDefaults.chatNameMorphStyle
}
