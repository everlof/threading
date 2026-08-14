import AppKit
import XCTest
@testable import Threading
@testable import ThreadingExtensionKit

/// Admission and preview for documents Threading has no native renderer for.
///
/// The centre of this file is `.json`. A Lottie *is* a `.json`, so the pane has to admit one
/// without admitting `package.json` — which is why classification is host-owned, structural, and
/// happens *before* the ordinary kind rejection rather than after it.
@MainActor
final class SessionAttachmentMediaTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingAttachmentMedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AttachmentMediaTypeRegistry.shared.removeAll()
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Admission

    func testABareJSONLottieIsProbedAndRecordedAsMedia() throws {
        let url = try write("animations/hero.json", LottieFixture.spinningDot())
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: url), .media)
        XCTAssertEqual(AttachmentReferenceDetector.admissionHint(for: url), .lottie)
    }

    /// The failure this design exists to prevent: a pane full of configuration.
    func testOrdinaryJSONIsNotAdmitted() throws {
        let package = try write("package.json", Data("""
        {"name": "threading", "version": "1.0.0", "scripts": {"build": "swift build"}}
        """.utf8))
        XCTAssertNil(AttachmentReferenceDetector.kind(for: package))

        // A document that merely says `layers` is a map style, a design-token file, or half the
        // configuration formats in a checkout — not an animation.
        let tokens = try write("tokens.json", Data("""
        {"layers": [{"name": "surface"}, {"name": "accent"}]}
        """.utf8))
        XCTAssertNil(AttachmentReferenceDetector.kind(for: tokens))
    }

    /// The probe declines when the structure is not inside its bounded prefix, rather than
    /// reading further to be sure.
    func testASignatureBeyondThePrefixIsNotAdmitted() throws {
        var padded = Data("{\"comment\":\"".utf8)
        padded.append(Data(repeating: UInt8(ascii: "x"), count: MediaContentProbe.prefixBytes))
        padded.append(Data("\",\"fr\":30,\"ip\":0,\"op\":30,\"layers\":[]}".utf8))
        let url = try write("late.json", padded)
        XCTAssertNil(AttachmentReferenceDetector.kind(for: url))
    }

    /// The work ceiling, stated as a count rather than as a hope. Thirty-three candidates in one
    /// buffer must cost thirty-two probes.
    func testAScanProbesNoMoreThanItsCandidateCeiling() throws {
        let total = MediaContentProbe.maximumCandidatesPerScan + 1
        var paths: [String] = []
        for index in 0..<total {
            let name = String(format: "animations/a%03d.json", index)
            _ = try write(name, LottieFixture.spinningDot())
            paths.append(name)
        }
        let text = paths.map { "`\($0)`" }.joined(separator: "\n")

        let resolution = AttachmentReferenceDetector.resolve(
            text: text,
            projectRoot: root,
            currentDirectory: nil
        )
        XCTAssertEqual(
            resolution.insideProject.count,
            MediaContentProbe.maximumCandidatesPerScan,
            "the scan probed past its own ceiling"
        )
    }

    // MARK: - Registration

    func testARegisteredFileTypeIsAdmittedAndLeavesWithItsExtension() throws {
        let url = try write("animations/hero.lottie", try LottieFixture.dotLottie())
        XCTAssertNil(
            AttachmentReferenceDetector.kind(for: url),
            "an unregistered type was admitted"
        )

        AttachmentMediaTypeRegistry.shared.register(
            [ExtensionPreviewableFileType(fileExtension: "lottie", displayName: "Lottie")],
            extensionIdentifier: "codes.threading.lottie-viewer"
        )
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: url), .media)
        XCTAssertEqual(AttachmentMediaTypeRegistry.shared.displayName(for: "lottie"), "Lottie")

        AttachmentMediaTypeRegistry.shared.remove(
            extensionIdentifier: "codes.threading.lottie-viewer"
        )
        XCTAssertNil(AttachmentReferenceDetector.kind(for: url))
    }

    /// Letting an extension own `.json` would let it claim every configuration file in every
    /// session, which is exactly what the host-owned probe exists to prevent.
    func testAReservedExtensionCannotBeRegistered() {
        for reserved in ["json", "png", "pdf", "html", "zip"] {
            let issues = ExtensionPreviewableFileType(
                fileExtension: reserved,
                displayName: "Mine"
            ).validationIssues(path: "type")
            XCTAssertTrue(
                issues.contains { $0.message.contains("cannot be registered") },
                "'\(reserved)' was not reserved"
            )
        }

        AttachmentMediaTypeRegistry.shared.register(
            [ExtensionPreviewableFileType(fileExtension: "json", displayName: "Mine")],
            extensionIdentifier: "codes.threading.greedy"
        )
        XCTAssertFalse(
            AttachmentMediaTypeRegistry.shared.isRegistered("json"),
            "a reserved extension reached the scanner's allow-list"
        )
    }

    func testRegistrationRequiresItsCapability() throws {
        let registration = ExtensionRegistration(
            previewableFileTypes: [
                ExtensionPreviewableFileType(fileExtension: "lottie", displayName: "Lottie")
            ]
        )
        XCTAssertThrowsError(try registration.validate(for: manifest(capabilities: []))) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertTrue(issues.contains { $0.message.contains("attachments.file-types") })
        }
        XCTAssertNoThrow(
            try registration.validate(for: manifest(capabilities: [.attachmentFileTypes]))
        )
    }

    /// First registration wins a contested extension, so an extension enabled later cannot take a
    /// type from one the user already had.
    func testTheFirstRegistrationWinsAContestedExtension() {
        let registry = AttachmentMediaTypeRegistry.shared
        registry.register(
            [ExtensionPreviewableFileType(fileExtension: "lottie", displayName: "First")],
            extensionIdentifier: "codes.threading.first"
        )
        registry.register(
            [ExtensionPreviewableFileType(fileExtension: "lottie", displayName: "Second")],
            extensionIdentifier: "codes.threading.second"
        )
        XCTAssertEqual(registry.displayName(for: "lottie"), "First")

        registry.remove(extensionIdentifier: "codes.threading.first")
        XCTAssertFalse(
            registry.isRegistered("lottie"),
            "the loser's claim quietly took over when the winner left"
        )
    }

    // MARK: - The offer

    func testTheFirstAcceptanceInUserOrderWins() {
        let router = StubPreviewRouter(candidates: ["Alpha", "Beta"])
        router.answers["Alpha"] = .accept(.text("alpha", role: .body))
        router.answers["Beta"] = .accept(.text("beta", role: .body))

        let outcome = offer(through: router)
        XCTAssertEqual(outcome?.extensionName, "Alpha")
        XCTAssertEqual(router.asked, ["Alpha"], "a later candidate was consulted after a winner")
    }

    func testADeclineAdvancesToTheNextCandidate() {
        let router = StubPreviewRouter(candidates: ["Alpha", "Beta"])
        router.answers["Alpha"] = .decline
        router.answers["Beta"] = .accept(.text("beta", role: .body))

        let outcome = offer(through: router)
        XCTAssertEqual(outcome?.extensionName, "Beta")
        XCTAssertEqual(router.asked, ["Alpha", "Beta"])
    }

    /// A timeout, a generation that died mid-offer and an invalid body are all the same answer:
    /// this candidate is not the one showing this row.
    func testATimeoutDeathOrInvalidBodyAdvancesLikeADecline() {
        for failure in [StubPreviewRouter.Answer.timeout, .dead, .invalid] {
            let router = StubPreviewRouter(candidates: ["Alpha", "Beta"])
            router.answers["Alpha"] = failure
            router.answers["Beta"] = .accept(.text("beta", role: .body))
            let outcome = offer(through: router)
            XCTAssertEqual(outcome?.extensionName, "Beta", "\(failure) did not advance")
        }
    }

    func testExhaustingTheCandidatesReachesTheNativeFallback() {
        let router = StubPreviewRouter(candidates: ["Alpha", "Beta"])
        router.answers["Alpha"] = .decline
        router.answers["Beta"] = .decline
        XCTAssertNil(offer(through: router), "a declined offer produced a body anyway")

        let empty = StubPreviewRouter(candidates: [])
        XCTAssertNil(offer(through: empty))
    }

    func testTheOfferIsAbandonedWhenTheSelectionMovesOn() {
        let router = StubPreviewRouter(candidates: ["Alpha"])
        router.answers["Alpha"] = .deferred
        let shell = SessionAttachmentPreviewOffer(router: router)

        var outcomes = 0
        shell.offer(context()) { _ in outcomes += 1 }
        shell.cancel()
        router.flushDeferred(accepting: .text("late", role: .body))

        XCTAssertEqual(outcomes, 0, "a late answer replaced the body of another row")
    }

    /// The contract's own vocabulary is what makes an "invalid body" invalid. Overlay and
    /// `.proceed` are refused because offer and decline happen before one exclusive body is
    /// chosen — there is no native content behind this to proceed into.
    func testThePreviewVocabularyRefusesOverlayAndProceed() {
        for node in [
            ExtensionNode.proceed,
            .overlay(base: .text("a", role: .body), overlay: .text("b", role: .body))
        ] {
            XCTAssertThrowsError(
                try ExtensionAttachmentPreviewContract.constraints.validate(node)
            )
        }
        XCTAssertNoThrow(
            try ExtensionAttachmentPreviewContract.constraints.validate(
                .media(ExtensionMediaDocument(
                    id: "preview",
                    source: .sessionAttachment("attachment-1"),
                    format: .lottie,
                    accessibilityLabel: "Animation"
                ))
            )
        )
    }

    func testAResponseForAnotherAttachmentIsRefused() throws {
        let response = ExtensionAttachmentPreviewResponse(
            requestID: "r1",
            attachmentID: "",
            content: .text("a", role: .body)
        )
        XCTAssertThrowsError(try response.validate())
    }

    // MARK: - The inspector rail

    /// A `.media` row missing from the rail has no visible symptom in the pane: the failure only
    /// appears when someone presses the arrow key.
    func testTheInspectorRailCarriesMediaRowsItCanDraw() throws {
        let lottie = try write("animations/hero.json", LottieFixture.spinningDot())
        let attachment = SessionAttachment(
            sessionID: SessionID(),
            root: root,
            url: lottie,
            relativePath: "animations/hero.json",
            sourcePath: lottie.path,
            kind: .media,
            origin: .agent,
            referencedAt: Date()
        )
        XCTAssertEqual(
            SessionAttachmentsViewController.inspectableMediaFormat(for: attachment),
            .lottie
        )

        // A registered format the host carries no renderer for is a real row in the pane and a
        // rail slot the lightbox would have nothing to put in.
        let unknown = try write("models/scene.usdz", Data("not a model".utf8))
        let unknownAttachment = SessionAttachment(
            sessionID: attachment.sessionID,
            root: root,
            url: unknown,
            relativePath: "models/scene.usdz",
            sourcePath: unknown.path,
            kind: .media,
            origin: .agent,
            referencedAt: Date()
        )
        XCTAssertNil(
            SessionAttachmentsViewController.inspectableMediaFormat(for: unknownAttachment)
        )
    }

    // MARK: - Fixtures

    private func manifest(capabilities: Set<ExtensionCapability>) -> ExtensionManifest {
        ExtensionManifest(
            identifier: "codes.threading.lottie-viewer",
            name: "Lottie Viewer",
            version: "1.0",
            runtime: .webAssembly,
            executable: "bin/viewer.wasm",
            capabilities: capabilities
        )
    }

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

    private func context() -> ExtensionAttachmentContext {
        ExtensionAttachmentContext(
            attachmentID: "attachment-1",
            name: "hero.json",
            kind: "media",
            contentHint: .lottie,
            byteSize: 1_024,
            origin: "agent",
            sessionID: "session-1"
        )
    }

    private func offer(
        through router: StubPreviewRouter
    ) -> SessionAttachmentPreviewOffer.Outcome? {
        let shell = SessionAttachmentPreviewOffer(router: router)
        var result: SessionAttachmentPreviewOffer.Outcome?
        var finished = false
        shell.offer(context()) { outcome in
            result = outcome
            finished = true
        }
        XCTAssertTrue(finished, "the stub router answered asynchronously")
        return result
    }
}

/// Answers a preview offer synchronously, so an ordering test is about ordering rather than
/// about a run loop.
@MainActor
private final class StubPreviewRouter: ExtensionAttachmentPreviewRouting {

    enum Answer {
        case accept(ExtensionNode)
        case decline
        case timeout
        /// The generation went away between the offer and the answer.
        case dead
        case invalid
        /// Held until the test releases it, so cancellation can be exercised.
        case deferred
    }

    private let candidates: [String]
    var answers: [String: Answer] = [:]
    private(set) var asked: [String] = []
    private var deferredCompletion: ((Result<ExtensionAttachmentPreviewResponse, Error>) -> Void)?
    private var deferredAttachmentID = ""

    init(candidates: [String]) {
        self.candidates = candidates
    }

    func attachmentPreviewCandidates() -> [ExtensionAttachmentPreviewCandidate] {
        candidates.map {
            ExtensionAttachmentPreviewCandidate(
                extensionIdentifier: "codes.threading.\($0.lowercased())",
                extensionName: $0,
                processGeneration: "generation-1"
            )
        }
    }

    @discardableResult
    func requestAttachmentPreview(
        extensionIdentifier: String,
        attachment: ExtensionAttachmentContext,
        completion: @escaping @MainActor (Result<ExtensionAttachmentPreviewResponse, Error>) -> Void
    ) -> Bool {
        guard let name = candidates.first(where: {
            "codes.threading.\($0.lowercased())" == extensionIdentifier
        }) else { return false }
        asked.append(name)

        switch answers[name] ?? .decline {
        case .accept(let node):
            completion(.success(ExtensionAttachmentPreviewResponse(
                requestID: "r",
                attachmentID: attachment.attachmentID,
                content: node
            )))
        case .decline:
            completion(.success(ExtensionAttachmentPreviewResponse(
                requestID: "r",
                attachmentID: attachment.attachmentID
            )))
        case .timeout:
            completion(.failure(ExtensionProcessError.actionTimedOut("preview")))
        case .dead:
            return false
        case .invalid:
            // A body about a different attachment: accepted by the transport, refused here.
            completion(.success(ExtensionAttachmentPreviewResponse(
                requestID: "r",
                attachmentID: "some-other-attachment",
                content: .text("wrong", role: .body)
            )))
        case .deferred:
            deferredCompletion = completion
            deferredAttachmentID = attachment.attachmentID
        }
        return true
    }

    func flushDeferred(accepting node: ExtensionNode) {
        deferredCompletion?(.success(ExtensionAttachmentPreviewResponse(
            requestID: "r",
            attachmentID: deferredAttachmentID,
            content: node
        )))
        deferredCompletion = nil
    }
}
