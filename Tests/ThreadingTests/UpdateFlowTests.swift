import XCTest
@testable import Threading

/// The update flow's pure decisions: when a download fraction is honest, what a release-notes
/// payload decodes to, and what the found sheet may offer for each shape of appcast item.
/// These are the rules `UpdateUserDriver` and `UpdatePresenter` both lean on, tested without
/// Sparkle or a window anywhere near them.
final class UpdateFlowTests: XCTestCase {

    // MARK: - Download progress

    func testNoExpectedLengthMeansNoFraction() {
        var progress = UpdateDownloadProgress()
        progress.receive(4_096)
        XCTAssertNil(progress.fraction, "a fraction of an unknown total is a made-up number")
    }

    func testFractionFollowsReceivedOverExpected() {
        var progress = UpdateDownloadProgress()
        progress.expect(1_000)
        progress.receive(250)
        XCTAssertEqual(progress.fraction, 0.25)
        progress.receive(250)
        XCTAssertEqual(progress.fraction, 0.5)
    }

    /// Sparkle warns the expected length can be wrong. A bar past its own end is the visible
    /// version of trusting it.
    func testOverdeliveryClampsAtOne() {
        var progress = UpdateDownloadProgress()
        progress.expect(100)
        progress.receive(250)
        XCTAssertEqual(progress.fraction, 1)
    }

    /// Sparkle also warns the expectation may be re-announced mid-download; the bytes already
    /// counted are real and stay.
    func testReannouncedExpectationReplacesTheTotalAndKeepsTheBytes() {
        var progress = UpdateDownloadProgress()
        progress.expect(100)
        progress.receive(50)
        progress.expect(200)
        XCTAssertEqual(progress.fraction, 0.25)
    }

    // MARK: - Release notes decoding

    func testDecodesUTF8WithoutADeclaredEncoding() {
        let text = "## Fixed\n- Emoji draw with backgrounds 🎉"
        let decoded = UpdateReleaseNotesDecoding.text(
            from: Data(text.utf8),
            encodingName: nil
        )
        XCTAssertEqual(decoded, text)
    }

    func testHonoursTheDeclaredEncodingFirst() {
        let text = "Versionen innehåller förbättringar"
        let data = text.data(using: .isoLatin1)!
        XCTAssertEqual(
            UpdateReleaseNotesDecoding.text(from: data, encodingName: "iso-8859-1"),
            text
        )
    }

    /// Latin-1 bytes are invalid UTF-8, and unlabelled feeds exist; bytes that arrived should
    /// render as their most plausible reading rather than as "could not be loaded".
    func testFallsBackThroughUTF8ToLatin1() {
        let text = "räksmörgås"
        let data = text.data(using: .isoLatin1)!
        XCTAssertEqual(
            UpdateReleaseNotesDecoding.text(from: data, encodingName: "not-a-charset"),
            text
        )
    }

    func testReleaseNotesTextIsOnlyTheRenderableCases() {
        XCTAssertEqual(UpdateReleaseNotes.embedded("a").text, "a")
        XCTAssertEqual(UpdateReleaseNotes.downloaded("b").text, "b")
        XCTAssertNil(UpdateReleaseNotes.none.text)
        XCTAssertNil(UpdateReleaseNotes.pending.text)
        XCTAssertNil(UpdateReleaseNotes.unavailable.text)
    }

    // MARK: - Feed routing

    func testOnlyNightlyOverridesTheShippedFeed() {
        XCTAssertEqual(UpdateFeedPolicy.feedOverride(for: .nightly), UpdateFeedPolicy.nightlyFeed)
        XCTAssertNil(UpdateFeedPolicy.feedOverride(for: .release))
        XCTAssertNil(UpdateFeedPolicy.feedOverride(for: .beta))
        XCTAssertNil(UpdateFeedPolicy.feedOverride(for: .dev))
    }

    /// `latest/download` resolves to the newest *release*; the nightly feed must live on the
    /// rolling prerelease tag precisely so the two can never meet.
    func testTheNightlyFeedDoesNotRideTheLatestRelease() {
        XCTAssertFalse(UpdateFeedPolicy.nightlyFeed.contains("/latest/"))
        XCTAssertTrue(UpdateFeedPolicy.nightlyFeed.hasSuffix("appcast.xml"))
    }

    func testScheduledChecksNeedBothTheUserAndARealChannel() {
        XCTAssertTrue(UpdateFeedPolicy.allowsScheduledChecks(on: .release, userChoice: true))
        XCTAssertTrue(UpdateFeedPolicy.allowsScheduledChecks(on: .nightly, userChoice: true))
        XCTAssertTrue(UpdateFeedPolicy.allowsScheduledChecks(on: .beta, userChoice: true))
        XCTAssertFalse(UpdateFeedPolicy.allowsScheduledChecks(on: .release, userChoice: false))
        // A dev build (0.0.0) is outranked by every release forever; a scheduled check would
        // nag daily about an "update" that is just the feed existing.
        XCTAssertFalse(UpdateFeedPolicy.allowsScheduledChecks(on: .dev, userChoice: true))
    }

    /// The shipped plist is the stable feed's single source of truth; this pins it so an
    /// accidental edit fails a test instead of stranding every installed copy.
    func testTheShippedFeedIsTheStableGitHubAppcast() {
        let info = Bundle.main.infoDictionary
        XCTAssertEqual(
            info?["SUFeedURL"] as? String,
            "https://github.com/everlof/threading/releases/latest/download/appcast.xml"
        )
        XCTAssertFalse((info?["SUPublicEDKey"] as? String ?? "").isEmpty)
    }

    // MARK: - What the found sheet may offer

    private func info(
        informational: Bool = false,
        critical: Bool = false,
        infoURL: URL? = nil
    ) -> UpdateVersionInfo {
        UpdateVersionInfo(
            version: "1.2.0",
            isInformational: informational,
            isCritical: critical,
            infoURL: infoURL,
            releaseNotes: .none
        )
    }

    func testAnOrdinaryUpdateOffersInstallAndSkip() {
        let presentation = UpdateFoundPresentation(info: info())
        XCTAssertEqual(presentation.primary, .install)
        XCTAssertTrue(presentation.offersSkip)
    }

    /// Skipping suppresses every future prompt for that version — exactly the memory a
    /// critical fix must not leave behind.
    func testACriticalUpdateOffersNoSkip() {
        let presentation = UpdateFoundPresentation(info: info(critical: true))
        XCTAssertEqual(presentation.primary, .install)
        XCTAssertFalse(presentation.offersSkip)
    }

    /// Sparkle forbids replying Install to an information-only item; the honest offer is
    /// its page.
    func testAnInformationalUpdateOffersItsPageAndNothingElse() {
        let url = URL(string: "https://example.com/notes")!
        let presentation = UpdateFoundPresentation(
            info: info(informational: true, infoURL: url)
        )
        XCTAssertEqual(presentation.primary, .learnMore(url))
        XCTAssertFalse(presentation.offersSkip)
    }

    func testAnInformationalUpdateWithoutAPageOffersNothing() {
        let presentation = UpdateFoundPresentation(info: info(informational: true))
        XCTAssertNil(presentation.primary)
        XCTAssertFalse(presentation.offersSkip)
    }

    // MARK: - The built sheet

    /// The request the presenter actually shows, held to the presentation rules above: the
    /// button order is primary, then skip, and the way out is always Remind Me Later.
    @MainActor
    func testTheFoundRequestCarriesTheOfferInOrder() {
        let (request, notes) = UpdatePresenter.foundRequest(info())
        XCTAssertEqual(request.prompt, .installUpdate)
        XCTAssertEqual(request.options.map(\.title), ["Install Update", "Skip This Version"])
        XCTAssertEqual(request.cancelTitle, "Remind Me Later")
        XCTAssertNil(notes, "an item with no notes gets no accessory claiming otherwise")

        var withNotes = info()
        withNotes.releaseNotes = .embedded("## Fixed\n- A bug")
        let built = UpdatePresenter.foundRequest(withNotes)
        XCTAssertNotNil(built.notes)
        XCTAssertTrue(built.request.accessory === built.notes)
    }

    @MainActor
    func testTheCriticalFoundRequestDropsSkipOnly() {
        let (request, _) = UpdatePresenter.foundRequest(info(critical: true))
        XCTAssertEqual(request.options.map(\.title), ["Install Update"])
        XCTAssertEqual(request.cancelTitle, "Remind Me Later")
    }
}
