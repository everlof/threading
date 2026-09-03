import CryptoKit
import Foundation
import XCTest
@testable import MarketeerPanelPlugin

final class MarketeerProjectTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marketeer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Finding the package

    /// The companion names a folder by the truncated SHA-256 of the Threading project id. Getting
    /// this wrong produces "no source attached" for a project that has one, which reads as the
    /// plugin being broken rather than as a lookup miss, so it is pinned against a digest computed
    /// independently here.
    func testTheDirectoryNameIsTheCompanionsOwnDigestScheme() {
        let projectID = "integration-project"
        let expected = SHA256.hash(data: Data(projectID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(32)
        XCTAssertEqual(MarketeerProjectLocator.directoryName(forProjectID: projectID), String(expected))
    }

    /// The companion is sandboxed, so its Application Support is inside its container. Looking in
    /// the user's own Application Support finds an empty directory that will never fill.
    func testTheProjectsRootIsInsideTheCompanionsSandboxContainer() {
        let path = MarketeerProjectLocator.projectsRoot(
            containers: URL(fileURLWithPath: "/Users/someone/Library/Containers")
        ).path
        XCTAssertTrue(path.contains("codes.threading.marketeer.companion.render"), path)
        XCTAssertTrue(path.hasSuffix("Data/Library/Application Support/ThreadingMarketeer/Projects"), path)
    }

    // MARK: - Reading

    func testAProjectWithNoIDIsAStateRatherThanAnError() {
        guard case .failure(let failure) = MarketeerProjectReader.read(projectID: nil, root: root) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(failure, .noProject)
    }

    func testAnUnattachedProjectSaysSoWithoutLeakingTheWholeDigest() {
        guard case .failure(let failure) = MarketeerProjectReader.read(projectID: "nothing-here", root: root) else {
            return XCTFail("expected a refusal")
        }
        guard case .noPackage(let name) = failure else { return XCTFail("wrong refusal: \(failure)") }
        XCTAssertEqual(name.count, 12, "the message shows a short prefix, not the whole digest")
    }

    func testTheDocumentIsReadIntoSlidesGradientsAndLocales() throws {
        try write(document: Self.sampleDocument, projectID: "p1", name: "Threading")

        guard case .success(let project) = MarketeerProjectReader.read(projectID: "p1", root: root) else {
            return XCTFail("expected the project to read")
        }
        XCTAssertEqual(project.name, "Threading")
        XCTAssertEqual(project.revision, 2)
        XCTAssertEqual(project.appLink?.appName, "Threading Test")
        XCTAssertEqual(project.localizations.map(\.localeCode), ["en-US", "sv"])
        XCTAssertEqual(project.slides.count, 2)

        let first = try XCTUnwrap(project.orderedSlides.first)
        XCTAssertEqual(first.slotPosition, 0)
        XCTAssertEqual(first.canvasSizeID, "6.9")
        XCTAssertEqual(first.background?.type, "linearGradient")
        XCTAssertEqual(first.background?.gradient?.angle, 180)
        XCTAssertEqual(first.elementSummary, "device, 2 text")
    }

    /// Slides are ordered by the slot the App Store will put them in, not by the order they happen
    /// to sit in the file, because the pane is a picture of the finished listing.
    func testSlidesComeOutInSlotOrder() throws {
        try write(document: Self.sampleDocument, projectID: "p2", name: "Threading")
        guard case .success(let project) = MarketeerProjectReader.read(projectID: "p2", root: root) else {
            return XCTFail("expected the project to read")
        }
        XCTAssertEqual(project.orderedSlides.map(\.slotPosition), [0, 1])
    }

    /// A background style this build cannot draw must not empty the pane. A throwing decoder here
    /// would turn one unknown gradient type into "no slides", which is the worst possible reading
    /// of a document that is perfectly fine.
    func testAnUnknownBackgroundStyleStillProducesASlide() throws {
        let document = """
        {"slides":[{"id":"A","slotPosition":0,"canvasSizeID":"6.9",
        "backgroundStyle":{"type":"someFutureStyle","data":{"unrelated":true}},
        "elements":[],"uploadedStates":{}}]}
        """
        try write(document: document, projectID: "p3", name: "Threading")
        guard case .success(let project) = MarketeerProjectReader.read(projectID: "p3", root: root) else {
            return XCTFail("expected the project to read")
        }
        XCTAssertEqual(project.slides.count, 1)
        XCTAssertEqual(project.slides.first?.background?.type, "someFutureStyle")
        XCTAssertNil(project.slides.first?.background?.gradient)
        XCTAssertEqual(project.slides.first?.elementSummary, "empty")
    }

    /// The cap is applied before any view exists, so a generated document cannot ask the pane for
    /// thousands of rows.
    func testSlidesAreCappedBeforeAnythingIsBuilt() throws {
        let slides = (0..<200).map {
            "{\"id\":\"S\($0)\",\"slotPosition\":\($0),\"canvasSizeID\":\"6.9\",\"elements\":[],\"uploadedStates\":{}}"
        }.joined(separator: ",")
        try write(document: "{\"slides\":[\(slides)]}", projectID: "p4", name: "Threading")

        guard case .success(let project) = MarketeerProjectReader.read(projectID: "p4", root: root) else {
            return XCTFail("expected the project to read")
        }
        XCTAssertEqual(project.slides.count, 200)
        XCTAssertEqual(project.orderedSlides.count, MarketeerProject.renderedSlideCap)
        XCTAssertEqual(project.hiddenSlideCount, 200 - MarketeerProject.renderedSlideCap)
    }

    /// The scan is bounded, not just the result: an oversized document is refused by its size on
    /// disk rather than parsed and then trimmed.
    func testAnOversizedDocumentIsRefusedByItsSizeRatherThanParsed() throws {
        let padding = String(repeating: "x", count: MarketeerProjectReader.maximumDocumentBytes + 1)
        try write(document: "{\"note\":\"\(padding)\",\"slides\":[]}", projectID: "p5", name: "Threading")

        guard case .failure(let failure) = MarketeerProjectReader.read(projectID: "p5", root: root) else {
            return XCTFail("expected a refusal")
        }
        guard case .tooLarge = failure else { return XCTFail("wrong refusal: \(failure)") }
    }

    // MARK: - Fixture

    private static let sampleDocument = """
    {
      "appStoreLink": {"appID":"1234567890","bundleID":"codes.threading.test","appName":"Threading Test"},
      "localizations": [
        {"id":"1","displayName":"English (U.S.)","localeCode":"en-US"},
        {"id":"2","displayName":"Swedish","localeCode":"sv"}
      ],
      "slides": [
        {"id":"B","slotPosition":1,"canvasSizeID":"6.9","elements":[],"uploadedStates":{}},
        {"id":"A","slotPosition":0,"canvasSizeID":"6.9",
         "backgroundStyle":{"type":"linearGradient","data":{
            "startColor":{"red":0.2,"green":0.4,"blue":0.9,"opacity":1},
            "endColor":{"red":0.6,"green":0.2,"blue":0.8,"opacity":1},
            "angle":180}},
         "elements":[
            {"id":"e1","payload":{"type":"device","data":{}}},
            {"id":"e2","payload":{"type":"text","data":{}}},
            {"id":"e3","payload":{"type":"text","data":{}}}
         ],
         "uploadedStates":{}}
      ]
    }
    """

    private func write(document: String, projectID: String, name: String) throws {
        let directory = MarketeerProjectLocator.packageDirectory(forProjectID: projectID, root: root)
        let package = directory.appendingPathComponent("Project.marketeer", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(document.utf8).write(to: package.appendingPathComponent("document.json"))
        try Data("{\"projectName\":\"\(name)\",\"projectID\":\"\(projectID)\"}".utf8)
            .write(to: directory.appendingPathComponent("project.json"))
        try Data("{\"revision\":2,\"reason\":\"link-app\",\"fingerprint\":\"abc\"}".utf8)
            .write(to: directory.appendingPathComponent("state.json"))
    }
}
