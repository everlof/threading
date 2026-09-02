import AVFoundation
import AppKit
import XCTest
@testable import Threading
@testable import ThreadingExtensionKit

/// Movies in the attachments pane: what is admitted, what the host refuses, and what a row that
/// can be played does that the rest of the list does not.
///
/// The claim under most of this file is that a movie is **not read**. Every other preview in the
/// pane decodes, lays out or renders the whole file, and is bounded by a byte ceiling for exactly
/// that reason; a movie is streamed off disk by the platform, so the ceiling would refuse the
/// ordinary case — a screen recording — to prevent work that never happens.
@MainActor
final class SessionAttachmentVideoTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Admission

    /// The set is the platform's, not the word "video": admitting a container AVFoundation cannot
    /// open would put a row in the pane whose preview could only ever say so.
    func testTheMovieExtensionsAreTheOnesThePlatformPlays() throws {
        for name in ["capture.mov", "recording.mp4", "clip.m4v", "CAPTURE.MOV"] {
            let url = try write(name, Data("not really a movie".utf8))
            XCTAssertEqual(
                AttachmentReferenceDetector.kind(for: url),
                .video,
                "\(name) should be recorded as a movie"
            )
        }
        for name in ["clip.webm", "clip.mkv", "clip.avi"] {
            let url = try write(name, Data("not really a movie".utf8))
            XCTAssertNil(
                AttachmentReferenceDetector.kind(for: url),
                "\(name) is a container this Mac cannot play and must not become a row"
            )
        }
    }

    /// The scan finds a movie the same way it finds a screenshot — the whole point of a kind
    /// rather than a special case.
    func testAMoviePrintedInOutputIsAdmittedFromInsideTheProject() throws {
        let inside = try write("recordings/keyboard.mp4", Data("stub".utf8))
        let resolution = AttachmentReferenceDetector.resolve(
            text: "wrote `recordings/keyboard.mp4` (18 MB)",
            projectRoot: root,
            currentDirectory: nil
        )
        XCTAssertEqual(
            resolution.insideProject.map(\.standardizedFileURL),
            [inside.standardizedFileURL]
        )
    }

    // MARK: - The seam

    /// A file-backed format is asked for a file. Handing it bytes instead — or letting a surface
    /// with no file quietly resolve one — is the confusion the second protocol exists to prevent.
    func testVideoIsCarriedAsAFileBackedFormat() {
        XCTAssertTrue(MediaDocumentRendererRegistry.supports(.video))
        XCTAssertTrue(MediaDocumentRendererRegistry.requiresFile(.video))
        XCTAssertFalse(MediaDocumentRendererRegistry.requiresFile(.lottie))
        XCTAssertFalse(MediaDocumentRendererRegistry.requiresFile(.animatedImage))
    }

    /// Autoplay is host policy stated once. An animation opened by the host plays; a movie has
    /// sound, so opening one playing is the app making a noise in a room it cannot see.
    func testTheHostOpensAnimationsPlayingAndMoviesPaused() {
        XCTAssertTrue(MediaDocumentRendererRegistry.autoplaysWhenHostOpens(.lottie))
        XCTAssertTrue(MediaDocumentRendererRegistry.autoplaysWhenHostOpens(.animatedImage))
        XCTAssertFalse(MediaDocumentRendererRegistry.autoplaysWhenHostOpens(.video))
    }

    func testBytesAreNotAMovieSource() async {
        do {
            _ = try await VideoDocumentRenderer().open(Data("mp4".utf8), limits: .default)
            XCTFail("a movie renderer accepted a buffer of bytes as a document")
        } catch let failure as MediaDocumentFailure {
            XCTAssertEqual(failure, .unresolvedSource)
        } catch {
            XCTFail("unexpected failure: \(error)")
        }
    }

    /// A name is a claim. The decoder is what says whether the claim is true, and a file that is
    /// not a movie is refused with a sentence rather than drawn as a black canvas.
    func testAFileThatIsNotAMovieIsRefusedWithAStatedReason() async throws {
        let url = try write("clip.mp4", Data("this is prose, not a movie".utf8))
        do {
            _ = try await VideoDocumentRenderer.plan(for: url, limits: .default)
            XCTFail("a text file named .mp4 was opened as a movie")
        } catch let failure as MediaDocumentFailure {
            guard case .invalidDocument(let message) = failure else {
                return XCTFail("expected a stated document failure, got \(failure)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testARealMovieReportsItsOwnSizeAndLength() async throws {
        let url = try writeMovie(named: "capture.mov")
        let plan = try await VideoDocumentRenderer.plan(for: url, limits: .default)
        XCTAssertEqual(plan.pixelWidth, Int(Self.movieSize.width))
        XCTAssertEqual(plan.pixelHeight, Int(Self.movieSize.height))
        XCTAssertEqual(plan.duration, Self.movieSeconds, accuracy: 0.35)
        XCTAssertGreaterThan(plan.frameRate, 0)
        XCTAssertFalse(plan.hasAudio, "the fixture writes no audio track")
    }

    /// The natural-size ceiling is a movie's own, well above the one a parsed document is
    /// measured against — refusing 4K would refuse the commonest recording there is.
    func testTheMoviePixelCeilingIsNotTheParsedDocumentOne() {
        XCTAssertGreaterThan(
            MediaDocumentLimits.default.maximumVideoPixelDimension,
            MediaDocumentLimits.default.maximumPixelDimension
        )
        XCTAssertGreaterThanOrEqual(
            MediaDocumentLimits.default.maximumVideoPixelDimension,
            3_840,
            "a 4K screen recording has to be playable"
        )
    }

    // MARK: - The pane

    /// The size gate is about reading, and a movie is never read here. A recording passes the
    /// ceiling before it has finished recording, so applying it would refuse the ordinary case.
    func testTheSizeGateRefusesAnArchiveAndNotAMovie() throws {
        let archive = try sparseFile(named: "release.zip")
        let refused = try laidOutPane(showing: [archive])
        XCTAssertTrue(
            messages(in: refused).contains(L10n.string("This file is too large to preview here.")),
            "an oversized archive was not refused"
        )

        let movie = try sparseFile(named: "recording.mp4")
        let pane = try laidOutPane(showing: [movie])
        XCTAssertFalse(
            messages(in: pane).contains(L10n.string("This file is too large to preview here.")),
            "a movie was refused by a ceiling that bounds reading it never does"
        )
        XCTAssertFalse(
            descendants(of: pane.view).compactMap { $0 as? MediaDocumentPlayerView }.isEmpty,
            "a movie row installed no player"
        )
    }

    /// What the pane asks for: this file, paused, once through, identified by the row so a
    /// refresh that re-selects it does not restart it.
    func testAMovieRowOpensPausedAndPlaysOnce() throws {
        let attachment = videoAttachment(named: "capture.mov")
        let document = SessionAttachmentsViewController.videoDocument(for: attachment)
        XCTAssertEqual(document.format, .video)
        XCTAssertEqual(document.id, attachment.id)
        XCTAssertEqual(document.source, .sessionAttachment(attachment.id))
        XCTAssertFalse(document.playback.isPlaying)
        XCTAssertEqual(document.playback.loop, .once)
        XCTAssertTrue(document.allowsFrameCopy)
    }

    /// A row missing from the rail has no visible symptom in the pane — it only shows up when
    /// somebody presses the arrow key and the movie they were looking at is not there.
    func testTheInspectorRailCarriesMovies() throws {
        let movie = try writeMovie(named: "capture.mov")
        let picture = try writePNG(named: "shot.png")
        let pane = try laidOutPane(showing: [picture, movie])

        let listed = SessionAttachmentStore.shared.attachments(for: pane.sessionID)
        XCTAssertEqual(listed.count, 2)
        let recorded = try XCTUnwrap(listed.first { $0.kind == .video })
        XCTAssertEqual(
            SessionAttachmentsViewController.inspectableMediaFormat(for: recorded),
            .video
        )

        let selection = try XCTUnwrap(pane.mediaInspectorSelection(forRow: 0))
        XCTAssertEqual(selection.items.count, 2, "the movie is missing from the rail")
        XCTAssertTrue(
            selection.items.contains { $0.content == .media(format: .video) },
            "the movie is on the rail as something the lightbox cannot play"
        )
    }

    /// A poster frame is a picture of a moment, and so is a screenshot. In a 26-point well
    /// nothing else tells them apart, so the row that can be played says so.
    func testAMovieRowIsMarkedAsPlayable() throws {
        let movie = try writeMovie(named: "capture.mov")
        let pane = try laidOutPane(showing: [movie])
        let marks = descendants(of: pane.view).filter {
            $0.accessibilityIdentifier() == SessionAttachmentsDefaults.playMarkIdentifier
        }
        XCTAssertEqual(marks.count, 1, "a movie row carries no play mark")
    }

    /// A poster frame is generated once, off the main actor, and answered from memory after
    /// that. The list is reloaded whenever a session prints a path, so a row that opened a
    /// decoder per reload would open one per printed line.
    func testAPosterFrameIsGeneratedOnceAndThenCached() throws {
        let movie = try writeMovie(named: "capture.mov")
        let attachment = SessionAttachment(
            sessionID: SessionID(),
            root: root,
            url: movie,
            relativePath: "capture.mov",
            sourcePath: movie.path,
            kind: .video,
            origin: .agent,
            referencedAt: Date()
        )
        XCTAssertNil(
            SessionAttachmentThumbnails.thumbnail(for: attachment),
            "a movie's frame was taken on the main thread"
        )

        var delivered = 0
        SessionAttachmentThumbnails.requestPosterFrame(for: attachment) { _ in delivered += 1 }
        waitUntil("the poster frame arrives") { delivered > 0 }
        XCTAssertNotNil(SessionAttachmentThumbnails.thumbnail(for: attachment))

        SessionAttachmentThumbnails.requestPosterFrame(for: attachment) { _ in delivered += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(delivered, 1, "a cached poster frame was generated again")
    }

    /// The single most likely defect in the feature, and the one nobody could miss: a movie
    /// still playing behind the row that replaced it.
    func testSelectingAnotherRowStopsTheMovie() throws {
        let movie = try writeMovie(named: "capture.mov")
        let picture = try writePNG(named: "shot.png")
        let pane = try laidOutPane(showing: [movie, picture])
        pane.showAttachment(at: movie)
        let player = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? MediaDocumentPlayerView }.first
        )
        XCTAssertFalse(player.isHidden, "the selected movie installed no visible player")

        pane.showAttachment(at: picture)
        XCTAssertTrue(player.isHidden, "the movie stayed on screen behind another row")
        XCTAssertFalse(player.isClockRunningForTesting)
    }

    // MARK: - Transport

    func testTheTransportOffersNoAudioControlUntilADocumentHasSound() {
        let transport = MediaTransportView(frame: .zero)
        XCTAssertTrue(
            transport.muteButtonForTesting.isHidden,
            "a silent document grew a control that can change nothing"
        )
        transport.showsAudioControl = true
        XCTAssertFalse(transport.muteButtonForTesting.isHidden)
    }

    /// The same rule the play glyph follows: stating the answer does not raise the intent, or a
    /// player mirroring its own state would toggle itself.
    func testMutingRaisesTheIntentAndAssigningDoesNot() {
        let transport = MediaTransportView(frame: .zero)
        transport.showsAudioControl = true
        var toggles = 0
        transport.onToggleMute = { toggles += 1 }

        transport.isMuted = true
        XCTAssertEqual(toggles, 0)

        transport.muteButtonForTesting.onPress?()
        XCTAssertEqual(toggles, 1)
    }

    // MARK: - The player

    /// End to end, without a window: the player resolves the file, the platform opens it, and the
    /// transport is told how long it is — paused, because the pane asked for it paused.
    func testThePlayerOpensAMovieAndStatesItsLength() throws {
        let url = try writeMovie(named: "capture.mov")
        let player = MediaDocumentPlayerView(
            loader: { _ in .failure(.unresolvedSource) },
            fileLoader: { _ in .success(url) }
        )
        let document = ExtensionMediaDocument(
            id: "movie",
            source: .sessionAttachment("movie"),
            format: .video,
            playback: ExtensionMediaPlayback(isPlaying: false, loop: .once),
            accessibilityLabel: "capture.mov"
        )
        player.update(document: document)

        waitUntil("the movie opens") {
            player.transportForTesting.documentDuration > 0 || player.phase == .failed
        }
        XCTAssertEqual(player.phase, .ready, player.messageTextForTesting)
        XCTAssertEqual(
            player.transportForTesting.documentDuration,
            Self.movieSeconds,
            accuracy: 0.35
        )
        XCTAssertFalse(player.transportForTesting.isPlaying)
        XCTAssertFalse(player.isClockRunningForTesting, "a paused movie is running a clock")
        XCTAssertTrue(
            player.transportForTesting.playButtonForTesting.isHidden,
            "the timeline duplicated the movie's centred Play control"
        )
        XCTAssertFalse(player.playbackOverlayForTesting.isHidden)
        XCTAssertTrue(player.playbackOverlayForTesting.isControlVisibleForTesting)
        XCTAssertEqual(player.playbackOverlayForTesting.accessibilityTitle(), L10n.string("Play"))
        XCTAssertTrue(
            player.transportForTesting.muteButtonForTesting.isHidden,
            "a movie with no audio track offered a mute control"
        )

        player.update(document: document)
        XCTAssertTrue(
            player.transportForTesting.isEnabled,
            "re-selecting the loaded movie disabled its timeline"
        )
        XCTAssertTrue(
            player.playbackOverlayForTesting.isEnabled,
            "re-selecting the loaded movie disabled its centred action"
        )

        XCTAssertTrue(player.playbackOverlayForTesting.performPrimaryAction())
        XCTAssertEqual(player.phase, .playing)
        XCTAssertTrue(player.playbackOverlayForTesting.isPlaying)
        XCTAssertEqual(player.playbackOverlayForTesting.accessibilityTitle(), L10n.string("Pause"))

        XCTAssertTrue(player.playbackOverlayForTesting.performPrimaryAction())
        XCTAssertEqual(player.phase, .paused)
    }

    /// The fold owns the preview rectangle. A movie aspect-fits inside it; it cannot impose the
    /// old 120-point canvas floor and make a downward drag stop early. At the smallest useful
    /// preview the centred control remains while the timeline yields, returning on expansion.
    func testTheMovieFollowsTheAttachmentFoldThroughTheCompactHeight() throws {
        AttachmentsListHeight.reset()
        defer { AttachmentsListHeight.reset() }

        let movie = try writeMovie(named: "capture.mov")
        var attachments = [movie]
        for index in 0..<19 {
            attachments.append(try writePNG(named: "shot-\(index).png"))
        }
        let pane = try laidOutPane(
            showing: attachments,
            size: NSSize(width: 353, height: 420)
        )
        pane.showAttachment(at: movie)
        pane.view.layoutSubtreeIfNeeded()

        let player = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? MediaDocumentPlayerView }.first
        )
        let preview = try XCTUnwrap(
            descendants(of: pane.view).first {
                $0.accessibilityIdentifier() == "attachments.preview-host"
            }
        )
        waitUntil("the pane's movie opens") { player.phase == .ready || player.phase == .failed }
        XCTAssertEqual(player.phase, .ready, player.messageTextForTesting)

        pane.foldDragged(by: 1_000)
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            preview.frame.height,
            MediaDocumentPlayerView.Layout.minimumCanvasHeight,
            "the movie's former minimum height stopped the fold"
        )
        XCTAssertEqual(player.minimumCanvasPriorityForTesting, .fittingSizeCompression)
        assertFills(player, preview)
        XCTAssertTrue(player.transportForTesting.isHidden, "a crushed timeline stayed operable")
        XCTAssertFalse(
            player.playbackOverlayForTesting.isHidden,
            "the compact preview lost its remaining playback action"
        )

        let compactHeight = preview.frame.height
        pane.foldDragged(by: -1_000)
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(preview.frame.height, compactHeight)
        assertFills(player, preview)
        XCTAssertFalse(player.transportForTesting.isHidden, "the timeline did not return")
    }

    /// A surface with no file for its sources cannot play a movie, and says so instead of
    /// gaining a filesystem. This is what keeps `attachments.preview@1` from becoming one.
    func testAPlayerWithNoFileResolverRefusesAMovie() throws {
        let player = MediaDocumentPlayerView(loader: { _ in .failure(.unresolvedSource) })
        player.update(document: ExtensionMediaDocument(
            id: "movie",
            source: .extensionResource("assets/clip.mp4"),
            format: .video,
            accessibilityLabel: "clip.mp4"
        ))
        waitUntil("the player refuses") { player.phase == .failed }
        XCTAssertFalse(player.messageTextForTesting.isEmpty)
    }

    // MARK: - Rendered evidence

    /// The shipping attachment pane, not an isolated control: the ordinary paused posture, the
    /// hover-only Pause action while running, and the compact fold where the timeline yields.
    func testRendersAttachmentVideoPlayback() throws {
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        AttachmentsListHeight.reset()
        defer {
            AttachmentsListHeight.reset()
            AppThemePalette.set(.system)
        }

        let movie = try writeMovie(named: "capture.mov")
        var attachments = [movie]
        for index in 0..<11 {
            attachments.append(try writePNG(named: "evidence-shot-\(index).png"))
        }
        let pane = try laidOutPane(
            showing: attachments,
            size: NSSize(width: 420, height: 560)
        )
        pane.showAttachment(at: movie)

        let host = renderHost(
            holding: pane,
            size: NSSize(width: 420, height: 560)
        )

        let player = try XCTUnwrap(
            descendants(of: pane.view).compactMap { $0 as? MediaDocumentPlayerView }.first
        )
        player.windowVisibility = { _ in true }
        player.refreshWindowVisibility()
        waitUntil("the evidence movie opens") {
            player.transportForTesting.documentDuration > 0 || player.phase == .failed
        }
        XCTAssertEqual(player.phase, .ready, player.messageTextForTesting)
        XCTAssertEqual(host.bounds.size, NSSize(width: 420, height: 560))
        XCTAssertEqual(pane.view.bounds.size, host.bounds.size)

        let themes: [(String, AppTheme)] = [
            ("system", .system),
            ("neo-brutalism", AppThemeStyles.neoBrutalism),
            ("cyberpunk", AppThemeStyles.cyberpunk)
        ]
        let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]
        var written = 0

        for (themeName, theme) in themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearance) in appearances {
                pane.foldDidReset()
                if player.playbackOverlayForTesting.isPlaying {
                    _ = player.playbackOverlayForTesting.performPrimaryAction()
                }
                player.playbackOverlayForTesting.mouseExited(
                    with: VideoPointerEventStub(type: .mouseExited)
                )
                layout(host, appearance: appearance)
                try writeRender(
                    host,
                    to: directory,
                    named: "attachment-video-paused-\(themeName)-\(appearanceName)"
                )

                _ = player.playbackOverlayForTesting.performPrimaryAction()
                player.playbackOverlayForTesting.mouseEntered(
                    with: VideoPointerEventStub(type: .mouseEntered)
                )
                layout(host, appearance: appearance)
                try writeRender(
                    host,
                    to: directory,
                    named: "attachment-video-playing-hover-\(themeName)-\(appearanceName)"
                )

                _ = player.playbackOverlayForTesting.performPrimaryAction()
                player.playbackOverlayForTesting.mouseExited(
                    with: VideoPointerEventStub(type: .mouseExited)
                )
                pane.foldDragged(by: 1_000)
                layout(host, appearance: appearance)
                try writeRender(
                    host,
                    to: directory,
                    named: "attachment-video-compact-\(themeName)-\(appearanceName)"
                )
                written += 3
            }
        }

        // Turn grouping is a property of the shipping pane, so keep its evidence beside the
        // pane's existing movie states. Exact identities make the fixture deterministic even
        // though every file was recorded before these synthetic checkpoint dates existed.
        let recorded = SessionAttachmentStore.shared.attachments(for: pane.sessionID)
        let latestFiles = recorded.filter {
            $0.url.standardizedFileURL == movie.standardizedFileURL
                || $0.name == "evidence-shot-0.png"
        }
        let previousFiles = recorded.filter { attachment in
            !latestFiles.contains { $0.id == attachment.id }
        }
        let previous = SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: 1,
            userTurnID: "evidence-previous-turn",
            requestedAt: Date(timeIntervalSince1970: 1)
        )
        let latest = SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: 2,
            userTurnID: "evidence-latest-turn",
            requestedAt: Date(timeIntervalSince1970: 2)
        )
        SessionAttachmentStore.shared.associate(
            attachmentIDs: latestFiles.map(\.id),
            withTurnID: latest.userTurnID,
            for: pane.sessionID
        )
        SessionAttachmentStore.shared.associate(
            attachmentIDs: previousFiles.map(\.id),
            withTurnID: previous.userTurnID,
            for: pane.sessionID
        )
        pane.turnBoundariesProvider = { [previous, latest] in [previous, latest] }
        pane.refresh()
        pane.showAttachment(at: movie)
        pane.foldDidReset()
        AppThemePalette.set(.system)
        pane.tableViewForTesting.scrollRowToVisible(0)
        layout(host, appearance: .aqua)
        try writeRender(
            host,
            to: directory,
            named: "attachment-video-turn-groups-expanded-system-light"
        )

        pane.setTurnSection(.checkpoint(previous.id), expanded: false)
        pane.tableViewForTesting.scrollRowToVisible(0)
        layout(host, appearance: .aqua)
        try writeRender(
            host,
            to: directory,
            named: "attachment-video-turn-groups-collapsed-system-light"
        )
        written += 2

        // No file at all is a different silence from an empty latest turn: the first owns the
        // pane's ordinary explanatory state, while the second must retain the turn chronology.
        AppThemePalette.set(.system)
        let emptyPane = SessionAttachmentsViewController(sessionID: SessionID())
        let emptyHost = renderHost(
            holding: emptyPane,
            size: NSSize(width: 420, height: 560),
            appearance: .aqua
        )
        layout(emptyHost, appearance: .aqua)
        try writeRender(
            emptyHost,
            to: directory,
            named: "attachment-video-turn-empty-pane-system-light"
        )

        let foldedSessionID = SessionID()
        let foldedPreviousID = "evidence-folded-previous"
        let foldedLatestID = "evidence-folded-latest"
        let foldedFile = try writePNG(named: "evidence-folded-previous.png")
        _ = try XCTUnwrap(SessionAttachmentStore.shared.record(
            declared: foldedFile,
            sessionID: foldedSessionID,
            projectRoot: root,
            origin: .user,
            turnID: foldedPreviousID,
            turnPlacement: .next
        ))
        let foldedPrevious = SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: 1,
            userTurnID: foldedPreviousID,
            requestedAt: Date(timeIntervalSince1970: 10)
        )
        let foldedLatest = SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: 2,
            userTurnID: foldedLatestID,
            requestedAt: Date(timeIntervalSince1970: 20)
        )
        AppThemePalette.set(AppThemeStyles.neoBrutalism)
        let foldedPane = SessionAttachmentsViewController(sessionID: foldedSessionID)
        foldedPane.turnBoundariesProvider = { [foldedPrevious, foldedLatest] in
            [foldedPrevious, foldedLatest]
        }
        let foldedHost = renderHost(
            holding: foldedPane,
            size: NSSize(width: 420, height: 560),
            appearance: .aqua
        )
        foldedPane.setTurnSection(.checkpoint(foldedLatest.id), expanded: false)
        foldedPane.setTurnSection(.checkpoint(foldedPrevious.id), expanded: false)
        foldedPane.tableViewForTesting.scrollRowToVisible(0)
        layout(foldedHost, appearance: .aqua)
        realizeVisibleRows(in: foldedPane)
        try writeRender(
            foldedHost,
            to: directory,
            named: "attachment-video-turn-latest-empty-all-collapsed-neo-brutalism-light"
        )

        // One short, dark pane carries the two boundary states exact turn ids cannot name:
        // a prompt waiting for admission and pane-local comparison input between turns.
        let boundarySessionID = SessionID()
        let boundaryLatestID = "evidence-boundary-latest"
        let boundaryLatestFile = try writePNG(named: "evidence-boundary-latest.png")
        let upcomingFile = try writePNG(named: "evidence-boundary-upcoming.png")
        let betweenFile = try writePNG(named: "evidence-boundary-between.png")
        _ = try XCTUnwrap(SessionAttachmentStore.shared.record(
            declared: boundaryLatestFile,
            sessionID: boundarySessionID,
            projectRoot: root,
            origin: .user,
            turnID: boundaryLatestID,
            turnPlacement: .next
        ))
        _ = try XCTUnwrap(SessionAttachmentStore.shared.record(
            declared: upcomingFile,
            sessionID: boundarySessionID,
            projectRoot: root,
            origin: .user,
            turnPlacement: .next
        ))
        _ = try XCTUnwrap(SessionAttachmentStore.shared.record(
            declared: betweenFile,
            sessionID: boundarySessionID,
            projectRoot: root,
            origin: .user,
            turnPlacement: .none
        ))
        let boundaryLatest = SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: 1,
            userTurnID: boundaryLatestID,
            requestedAt: Date(timeIntervalSince1970: 1)
        )
        AppThemePalette.set(.system)
        let boundaryPane = SessionAttachmentsViewController(sessionID: boundarySessionID)
        boundaryPane.turnBoundariesProvider = { [boundaryLatest] in [boundaryLatest] }
        let boundaryHost = renderHost(
            holding: boundaryPane,
            size: NSSize(width: 420, height: 360),
            appearance: .darkAqua
        )
        boundaryPane.showAttachment(at: boundaryLatestFile)
        boundaryPane.tableViewForTesting.scrollRowToVisible(0)
        layout(boundaryHost, appearance: .darkAqua)
        realizeVisibleRows(in: boundaryPane)
        try writeRender(
            boundaryHost,
            to: directory,
            named: "attachment-video-turn-upcoming-between-short-system-dark"
        )

        // Fifty is the durable ledger's real per-session ceiling. Putting one file at each end
        // yields the longest title the shipping chronology can generate ("49 turns ago") and a
        // long filename at the pane's ordinary 200-point opening floor.
        let narrowSessionID = SessionID()
        let narrowBoundaries = (1...GitTurnCheckpointDefaults.maximumPerSession).map { ordinal in
            SessionAttachmentTurnBoundary(
                id: GitTurnCheckpointID(),
                ordinal: ordinal,
                userTurnID: "evidence-narrow-turn-\(ordinal)",
                requestedAt: Date(timeIntervalSince1970: TimeInterval(ordinal))
            )
        }
        let narrowLatestFile = try writePNG(named: "evidence-narrow-latest.png")
        let narrowOldFile = try writePNG(
            named: "this-is-a-deliberately-long-attachment-name-for-the-narrow-pane.png"
        )
        _ = try XCTUnwrap(SessionAttachmentStore.shared.record(
            declared: narrowLatestFile,
            sessionID: narrowSessionID,
            projectRoot: root,
            origin: .user,
            turnID: try XCTUnwrap(narrowBoundaries.last).userTurnID,
            turnPlacement: .next
        ))
        _ = try XCTUnwrap(SessionAttachmentStore.shared.record(
            declared: narrowOldFile,
            sessionID: narrowSessionID,
            projectRoot: root,
            origin: .user,
            turnID: try XCTUnwrap(narrowBoundaries.first).userTurnID,
            turnPlacement: .next
        ))
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let narrowPane = SessionAttachmentsViewController(sessionID: narrowSessionID)
        narrowPane.turnBoundariesProvider = { narrowBoundaries }
        let narrowHost = renderHost(
            holding: narrowPane,
            size: NSSize(width: DisplayPaneDefaults.minWidth, height: 420),
            appearance: .darkAqua
        )
        narrowPane.showAttachment(at: narrowLatestFile)
        narrowPane.tableViewForTesting.scrollRowToVisible(0)
        layout(narrowHost, appearance: .darkAqua)
        realizeVisibleRows(in: narrowPane)
        try writeRender(
            narrowHost,
            to: directory,
            named: "attachment-video-turn-narrow-long-cyberpunk-dark"
        )
        written += 4

        XCTAssertEqual(written, themes.count * appearances.count * 3 + 6)
        print("Rendered attachment video playback to \(directory.path)")
    }

    // MARK: - Fixtures

    private static let movieSize = MovieFixture.size
    private static let movieSeconds = MovieFixture.seconds
    private static let movieFrameRate = MovieFixture.frameRate

    @discardableResult
    private func write(_ relativePath: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    /// A file whose *reported* size is over the preview ceiling and whose bytes were never
    /// written. The gate reads metadata, so paying for 65 MB of zeros would be paying for the
    /// bytes the test exists to prove untouched.
    private func sparseFile(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(
            atOffset: UInt64(SessionAttachmentsDefaults.maximumPreviewFileBytes) + 1
        )
        try handle.close()
        return url
    }

    private func writePNG(named name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw XCTSkip("the fixture image could not be encoded")
        }
        return try write(name, png)
    }

    /// A genuinely decodable movie, because every claim in this file — the size, the length, the
    /// refusal of a file that only looks like one — is a claim about what a decoder says.
    private func writeMovie(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try MovieFixture.write(
            to: url,
            size: Self.movieSize,
            seconds: Self.movieSeconds,
            frameRate: Self.movieFrameRate
        )
        return url
    }

    private func videoAttachment(named name: String) -> SessionAttachment {
        SessionAttachment(
            sessionID: SessionID(),
            root: root,
            url: root.appendingPathComponent(name),
            relativePath: name,
            sourcePath: root.appendingPathComponent(name).path,
            kind: .video,
            origin: .agent,
            referencedAt: Date()
        )
    }

    private func laidOutPane(
        showing urls: [URL],
        size: NSSize = NSSize(width: 353, height: 700)
    ) throws -> SessionAttachmentsViewController {
        let sessionID = SessionID()
        let recorded = SessionAttachmentStore.shared.record(
            urls: urls,
            sessionID: sessionID,
            projectRoot: root
        )
        XCTAssertEqual(recorded.count, urls.count, "a fixture attachment was refused")

        let controller = SessionAttachmentsViewController(sessionID: sessionID)
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.autoresizingMask = []
        controller.view.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func assertFills(
        _ player: MediaDocumentPlayerView,
        _ preview: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(player.frame.minX, preview.bounds.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(player.frame.minY, preview.bounds.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(player.frame.width, preview.bounds.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(player.frame.height, preview.bounds.height, accuracy: 0.5, file: file, line: line)
    }

    private func layout(_ root: NSView, appearance: NSAppearance.Name) {
        let render: @MainActor () -> Void = {
            root.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
        }
        if let resolved = NSAppearance(named: appearance) {
            resolved.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
    }

    private func renderHost(
        holding pane: SessionAttachmentsViewController,
        size: NSSize,
        appearance: NSAppearance.Name? = nil
    ) -> ThemedSurfaceView {
        let host = ThemedSurfaceView()
        // This is the render root, not an arranged child. Keep its explicit product-shell size
        // out of the descendant Auto Layout system's fitting-size calculation.
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: size)
        if let appearance {
            host.appearance = NSAppearance(named: appearance)
        }
        host.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
        // Load and settle the production controller at its real shell size before the host owns
        // it. Loading an AppKit table at a zero-size root can leave its document view with a
        // zero visible rect even after the outer constraints settle; the ordinary pane fixture
        // above follows this same two-pass sizing path for that reason.
        pane.view.frame = NSRect(origin: .zero, size: size)
        pane.view.autoresizingMask = []
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.view.topAnchor.constraint(equalTo: host.topAnchor),
            pane.view.widthAnchor.constraint(equalToConstant: size.width),
            pane.view.heightAnchor.constraint(equalToConstant: size.height)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// An on-screen `NSTableView` asks its delegate for visible rows during display. Evidence
    /// roots are intentionally off-window, so make that same bounded request before caching the
    /// bitmap; otherwise the clip view is truthful but visually empty in the artifact.
    private func realizeVisibleRows(in pane: SessionAttachmentsViewController) {
        let table = pane.tableViewForTesting
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
    }

    private func writeRender(_ view: NSView, to directory: URL, named name: String) throws {
        var png: Data?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            png = rep.representation(using: .png, properties: [:])
        }
        let resolved = try XCTUnwrap(png)
        try resolved.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func messages(in pane: SessionAttachmentsViewController) -> [String] {
        descendants(of: pane.view)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }
            .map(\.stringValue)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Spins the main run loop until a condition holds. The player opens a document
    /// asynchronously by design — parsing and track reading complete off the main actor — so a
    /// test that asserted straight after `update(document:)` would be asserting about a load that
    /// has not started.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 20,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }
}

private final class VideoPointerEventStub: NSEvent {
    private let stubType: NSEvent.EventType

    init(type: NSEvent.EventType) {
        stubType = type
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var type: NSEvent.EventType { stubType }
}
