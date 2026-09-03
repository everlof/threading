import AppKit
import XCTest
@testable import MarketeerPanelPlugin

/// The complaint that started this migration was "I was never satisfied with how it looked", which
/// is not a thing an assertion can hold. So the pane is drawn to a PNG and looked at, the way every
/// other appearance question in this repository is settled.
///
/// `THREADING_RENDER_OUT` redirects the output; without it the pictures go to a temporary folder
/// and the test still proves the pane draws something rather than a blank rectangle.
@MainActor
final class MarketeerPanelRenderTests: XCTestCase {

    func testRendersTheProjectPane() throws {
        let project = MarketeerProject(
            name: "Threading",
            projectID: "threading",
            revision: 7,
            changeReason: "external-edit",
            appLink: MarketeerAppLink(
                appID: "1234567890",
                bundleID: "codes.threading",
                appName: "Threading"
            ),
            localizations: [
                MarketeerLocalization(localeCode: "en-US", displayName: "English (U.S.)"),
                MarketeerLocalization(localeCode: "sv", displayName: "Swedish"),
            ],
            slides: (0..<5).map { index in
                Self.slide(
                    slot: index,
                    start: (0.10 + Double(index) * 0.04, 0.25, 0.55),
                    end: (0.04, 0.11, 0.19),
                    uploaded: index < 2
                )
            }
        )

        let image = try render(MarketeerPanelView(state: .success(project), onRefresh: {}))
        XCTAssertGreaterThan(image.size.width, 0)
        try write(image, named: "marketeer-panel")
    }

    /// The other half of the pane's life, and the one a first-run user sees.
    func testRendersTheUnattachedState() throws {
        let view = MarketeerPanelView(
            state: .failure(.noPackage(directoryName: "f84e603f8386")),
            onRefresh: {}
        )
        try write(try render(view), named: "marketeer-panel-unattached")
    }

    // MARK: - Harness

    private func render(_ view: NSView) throws -> NSImage {
        // An unshown window, which lays out and draws through cacheDisplay while never appearing.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Without an explicit appearance the offscreen pass draws a blank picture.
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: window.contentLayoutRect)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = host

        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func write(_ image: NSImage, named name: String) throws {
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("marketeer-renders")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("rendered \(url.path)")
    }

    private static let titles = [
        "Your Mac keeps working",
        "The real terminal",
        "See the limit coming",
        "Claude Code and Codex",
        "Pair once, forget it",
    ]

    private static func slide(
        slot: Int,
        start: (Double, Double, Double),
        end: (Double, Double, Double),
        uploaded: Bool
    ) -> MarketeerSlide {
        let json = """
        {"id":"S\(slot)","slotPosition":\(slot),"canvasSizeID":"6.9",
         "backgroundStyle":{"type":"linearGradient","data":{
            "startColor":{"red":\(start.0),"green":\(start.1),"blue":\(start.2),"opacity":1},
            "endColor":{"red":\(end.0),"green":\(end.1),"blue":\(end.2),"opacity":1},
            "angle":160}},
         "elements":[
            {"id":"a","x":0.5,"y":0.56,"scale":0.72,"payload":{"type":"device","data":{"deviceModel":"iPhone 17 Pro"}}},
            {"id":"b","x":0.5,"y":0.07,"scale":1,"payload":{"type":"text","data":{
                "text":"\(Self.titles[slot % Self.titles.count])",
                "color":{"red":0.99,"green":0.96,"blue":0.93,"opacity":1}}}},
            {"id":"c","x":0.5,"y":0.15,"scale":1,"payload":{"type":"text","data":{
                "text":"and the subtitle",
                "color":{"red":1,"green":0.6,"blue":0.24,"opacity":1}}}}],
         "uploadedStates":{"en-US":\(uploaded)}}
        """
        // Force-decoded on purpose: a fixture that cannot be decoded is a broken test, and it
        // should say so here rather than by rendering an empty pane later.
        return try! JSONDecoder().decode(MarketeerSlide.self, from: Data(json.utf8))
    }
}
