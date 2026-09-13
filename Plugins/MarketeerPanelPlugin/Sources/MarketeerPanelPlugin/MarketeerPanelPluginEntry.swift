import AppKit
import CoreGraphics
import ThreadingDesignKit
import ThreadingPluginKit

/// Marketeer's pane, as a native plugin.
///
/// The Wasm extension keeps its 21 tools, its App Store credentials and its companion; this
/// replaces only the panel, which is the part that could not be made to look like the application
/// it sits in. The two tiers coexist because they register through different seams.
@objc(MarketeerPanelPlugin)
public final class MarketeerPanelPlugin: NSObject, ThreadingNativePlugin {

    // This is deliberately a literal so an older host cannot make a newer plugin report the
    // older host framework's generation.
    public static let pluginAPIVersion = 5

    public var pluginIdentifier: String { "codes.threading.marketeer.panel" }

    private var pane: MarketeerPanelView?
    private var container: NSView?
    private var projectID: String?

    public override required init() {
        super.init()
    }

    // MARK: - Drawing

    public func makePaneView(context: PluginContext) -> NSView {
        // `projectID` is what the host now names, and it is the whole reason this pane can find
        // anything: the companion keys its packages on the Threading project id, so without it a
        // plugin would have to ask the user to locate a folder it could already have known.
        projectID = context.argument("projectID")

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.container = container
        reload()
        return container
    }

    public func apply(theme: PluginTheme) {
        // The design system resolves every role itself once the host's theme is installed, which
        // is why this hands over the encoded theme rather than painting from the seven tokens.
        if let encoded = theme.encodedTheme { try? HostThemeHandoff.install(encoded: encoded) }
        pane?.applyTheme()
    }

    /// Re-read the package and rebuild.
    ///
    /// Wholesale rather than incremental, and that is a considered bound rather than laziness: a
    /// document is capped at sixty rendered slides before any view exists, and a rebuild happens
    /// only when someone asks for one. See `MarketeerProject.renderedSlideCap`.
    ///
    /// Exactly twice, when there is artwork to decode. The pane goes up immediately with the
    /// miniatures drawn from the document, then once more when the exports have been decoded off
    /// the main actor — never once per picture, which is sixty layout passes for a folder of
    /// screenshots.
    private func reload() {
        let state = MarketeerProjectReader.read(projectID: projectID)
        install(state, thumbnails: [:])

        guard case .success(let project) = state, !project.exports.isEmpty else { return }
        let exports = project.exports
        Task.detached(priority: .userInitiated) {
            // A screenshot is 1290×2796. ImageIO downsamples during the decode, so the full-size
            // pixels are never materialized, and this stays off the main actor because file
            // reading and image decoding both belong there.
            var decoded: [Int: CGImage] = [:]
            for (slot, url) in exports {
                if let image = MarketeerExports.thumbnail(at: url) { decoded[slot] = image }
            }
            guard !decoded.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.install(self.lastState ?? state, thumbnails: decoded)
            }
        }
    }

    /// The state the pane was last built from, so the second pass redraws the same project rather
    /// than whatever is on disk by the time the decodes finish.
    private var lastState: Result<MarketeerProject, MarketeerReadFailure>?

    private func install(
        _ state: Result<MarketeerProject, MarketeerReadFailure>,
        thumbnails: [Int: CGImage]
    ) {
        guard let container else { return }
        lastState = state
        container.subviews.forEach { $0.removeFromSuperview() }

        let pane = MarketeerPanelView(state: state, thumbnails: thumbnails) { [weak self] in
            self?.reload()
        }
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.topAnchor.constraint(equalTo: container.topAnchor),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.pane = pane
    }

    // MARK: - Tools

    /// One tool for now: re-read the package, so an agent that has just changed the source can put
    /// the result on screen without the user pressing anything.
    public var pluginTools: [PluginTool] {
        [
            PluginTool(
                name: "refresh",
                title: "Marketeer",
                detail: "Re-read the Marketeer source for this project.",
                symbol: "arrow.clockwise",
                summary: "Re-reads the Marketeer project package and redraws the pane. Call after "
                    + "changing the source so the pane matches what is on disk.",
                inputSchemaJSON: #"{"type":"object","properties":{}}"#
            ),
        ]
    }

    public func invokeTool(
        named name: String,
        argumentsJSON: String,
        completion: @escaping (String, Bool) -> Void
    ) {
        guard name == "refresh" else { return completion("no such tool: \(name)", true) }
        reload()
        switch MarketeerProjectReader.read(projectID: projectID) {
        case .success(let project):
            completion(
                "\(project.name): \(project.slides.count) slides, "
                    + "\(project.localizations.count) locales"
                    + (project.revision.map { ", revision \($0)" } ?? ""),
                false
            )
        case .failure(let failure):
            completion(failure.description, true)
        }
    }
}
