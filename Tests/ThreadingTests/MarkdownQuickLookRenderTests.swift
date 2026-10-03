import AppKit
import ThreadingMarkdownKit
import WebKit
import XCTest
@testable import Threading

/// The production provider returns this exact HTML; WebKit is Quick Look's HTML presentation.
@MainActor
final class MarkdownQuickLookRenderTests: XCTestCase {
    func testRendersProductionQuickLookHTML() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua), ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua), ("win98", AppThemeStyles.win98, .aqua)
        ]
        for (name, theme, appearance) in variants {
            AppThemePalette.set(theme)
            let html = MarkdownPreviewHTML.render(
                MarkdownPreviewDocument(source: MarkdownEditorRenderTests.fixture),
                themes: MarkdownQuickLookTheme.snapshot(), title: "GUIDELINES.md", excerptMessage: "Excerpt"
            )
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            web.appearance = NSAppearance(named: appearance)
            let loaded = expectation(description: "Quick Look HTML loaded")
            let navigation = MarkdownQuickLookNavigation(loaded)
            web.navigationDelegate = navigation
            web.loadHTMLString(html, baseURL: nil)
            await fulfillment(of: [loaded], timeout: 20)
            XCTAssertNil(navigation.error)
            let snapshot = try await web.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("quicklook-markdown-\(name).png"))
        }
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/ThreadingMarkdownPreview.appex")
        let bundle = try XCTUnwrap(Bundle(url: extensionURL))
        let configuration = try XCTUnwrap(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        XCTAssertEqual(configuration["NSExtensionPointIdentifier"] as? String, "com.apple.quicklook.preview")
        let attributes = try XCTUnwrap(configuration["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(attributes["QLIsDataBasedPreview"] as? Bool, true)
        XCTAssertTrue((attributes["QLSupportedContentTypes"] as? [String])?.contains(MarkdownFileAssociation.typeIdentifier) == true)
    }
}

@MainActor
private final class MarkdownQuickLookNavigation: NSObject, WKNavigationDelegate {
    private let loaded: XCTestExpectation
    private(set) var error: Error?
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        loaded.fulfill()
    }
}
