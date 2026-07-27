import AppKit
import SkalmanExtensionKit

/// A production host for one extension panel inside a session's display-pane tab.
///
/// The tab retains only stable extension/panel identifiers. Live panel values are accepted from
/// the currently registered process generation, and every AppKit view is rebuilt by Skalman's
/// semantic renderer. If that generation disappears, the tab remains as a recoverable place and
/// shows an unavailable state until the same contribution returns.
@MainActor
final class ExtensionPanelViewController: NSViewController {
    let extensionIdentifier: String
    let panelID: String

    private let context: ExtensionCommandContext
    private weak var router: ExtensionPanelRouting?
    private let fallbackTitle: String
    private let events = AppEventObservations()

    private var panel: ExtensionPanel?
    private var extensionName: String?
    private var processGeneration: String?
    private var loadedProcessGeneration: String?
    private var statusMessage: String?
    private var remoteFailureMessage: String?
    private var actionSequence = 0
    private var remoteSurfaceView: ExtensionRemoteSurfaceView?
    private var isPanelVisible = false

    private let scrollView = ThemedScrollView()
    private let contentStack = NSStackView()

    var onChange: (() -> Void)?

    var panelTitle: String {
        panel?.title ?? fallbackTitle
    }

    init(
        extensionIdentifier: String,
        panelID: String,
        title: String,
        context: ExtensionCommandContext,
        router: ExtensionPanelRouting
    ) {
        self.extensionIdentifier = extensionIdentifier
        self.panelID = panelID
        self.fallbackTitle = title
        self.context = context
        self.router = router
        super.init(nibName: nil, bundle: nil)

        events.observe(ExtensionsDidChange.self) { [weak self] _ in
            self?.refreshRegistration()
        }
        refreshRegistration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Design.Spacing.medium
        contentStack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.pane,
            left: Design.Spacing.pane,
            bottom: Design.Spacing.pane,
            right: Design.Spacing.pane
        )
        scrollView.documentView = contentStack
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
        render()
        loadPanelIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        isPanelVisible = true
        remoteSurfaceView?.setPresentationVisible(true)
    }

    override func viewDidDisappear() {
        isPanelVisible = false
        remoteSurfaceView?.setPresentationVisible(false)
        super.viewDidDisappear()
    }

    private func refreshRegistration() {
        let item = router?.registeredPanel(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        )

        if let item {
            extensionName = item.extensionName
            if processGeneration != item.processGeneration {
                disconnectRemoteSurface()
                processGeneration = item.processGeneration
                loadedProcessGeneration = nil
                panel = item.panel
                statusMessage = nil
                remoteFailureMessage = nil
                actionSequence += 1
            }
        } else {
            disconnectRemoteSurface()
            processGeneration = nil
            loadedProcessGeneration = nil
            panel = nil
            statusMessage = nil
            remoteFailureMessage = nil
            actionSequence += 1
        }

        if isViewLoaded {
            render()
            loadPanelIfNeeded()
        }
        onChange?()
    }

    /// Loads context-dependent content once per process generation. A response panel may also
    /// carry `loadActionID`; generation tracking deliberately prevents that replacement from
    /// recursively loading itself.
    private func loadPanelIfNeeded() {
        guard let generation = processGeneration,
              loadedProcessGeneration != generation,
              let actionID = panel?.loadActionID else {
            return
        }
        loadedProcessGeneration = generation
        invoke(actionID, pendingMessage: "Loading…")
    }

    private func render() {
        for arranged in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }

        if let statusMessage {
            let status = NSTextField(wrappingLabelWithString: statusMessage)
            status.applyFont(.detail())
            status.textColor = Design.Text.secondary
            status.setAccessibilityIdentifier("extension.panel.status")
            contentStack.addArrangedSubview(status)
            status.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        guard let panel else {
            disconnectRemoteSurface()
            scrollView.isHidden = false
            let owner = extensionName ?? extensionIdentifier
            let unavailable = NSTextField(
                wrappingLabelWithString:
                    "“\(fallbackTitle)” is unavailable because \(owner) is not running "
                    + "or no longer registers this panel."
            )
            unavailable.applyFont(.body)
            unavailable.textColor = Design.Text.tertiary
            unavailable.setAccessibilityIdentifier("extension.panel.unavailable")
            contentStack.addArrangedSubview(unavailable)
            unavailable.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            return
        }

        if panel.remoteSurface != nil, remoteFailureMessage == nil,
           renderRemoteSurface() {
            scrollView.isHidden = true
            return
        }
        if panel.remoteSurface == nil {
            disconnectRemoteSurface()
        }
        scrollView.isHidden = false
        remoteSurfaceView?.isHidden = true

        if let remoteFailureMessage {
            let failure = NSTextField(wrappingLabelWithString: remoteFailureMessage)
            failure.applyFont(.detail())
            failure.textColor = Design.Text.secondary
            failure.setAccessibilityIdentifier("extension.remote-surface.fallback")
            contentStack.addArrangedSubview(failure)
            failure.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        do {
            let rendered = try ExtensionNodeRenderer.render(
                panel.root,
                imageResolver: { [weak self] reference in
                    self?.resolveImage(reference)
                },
                onAction: { [weak self] actionID in
                    self?.invoke(actionID)
                }
            )
            rendered.setAccessibilityIdentifier(
                "extension.panel.\(extensionIdentifier).\(panelID)"
            )
            contentStack.addArrangedSubview(rendered)
            rendered.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        } catch {
            let failure = NSTextField(
                wrappingLabelWithString: "This extension panel could not be rendered: "
                    + error.localizedDescription
            )
            failure.applyFont(.body)
            failure.textColor = Design.Status.negative
            failure.setAccessibilityIdentifier("extension.panel.render-error")
            contentStack.addArrangedSubview(failure)
            failure.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func renderRemoteSurface() -> Bool {
        guard panel?.remoteSurface != nil else { return false }
        let surfaceView: ExtensionRemoteSurfaceView
        if let existing = remoteSurfaceView {
            surfaceView = existing
        } else {
            let created = ExtensionRemoteSurfaceView()
            created.translatesAutoresizingMaskIntoConstraints = false
            created.onDisconnect = { [weak self] message in
                guard let self else { return }
                self.remoteFailureMessage = message
                self.render()
            }
            view.addSubview(created)
            NSLayoutConstraint.activate([
                created.topAnchor.constraint(equalTo: view.topAnchor),
                created.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                created.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                created.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            remoteSurfaceView = created
            surfaceView = created
        }
        surfaceView.isHidden = false
        guard surfaceView.subscription == nil else {
            surfaceView.setPresentationVisible(isPanelVisible)
            return true
        }

        let presentationID = UUID().uuidString.lowercased()
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let viewport = ExtensionRemoteSurfaceViewport(
            presentationID: presentationID,
            width: Double(max(0, view.bounds.width)),
            height: Double(max(0, view.bounds.height)),
            scale: Double(scale),
            isVisible: isPanelVisible
        )
        guard let subscription = router?.connectRemoteSurface(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            context: context,
            initialViewport: viewport,
            consumer: surfaceView
        ) else {
            remoteFailureMessage = "The declared remote surface is unavailable. "
                + "Showing the extension's semantic fallback."
            surfaceView.isHidden = true
            return false
        }
        surfaceView.install(subscription: subscription)
        surfaceView.setPresentationVisible(isPanelVisible)
        return true
    }

    private func disconnectRemoteSurface() {
        remoteSurfaceView?.subscription?.cancel()
        remoteSurfaceView?.removeFromSuperview()
        remoteSurfaceView = nil
    }

    private func resolveImage(_ reference: ExtensionImageReference) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .extensionResource(let path):
            guard let url = router?.extensionImageResourceURL(
                extensionIdentifier: extensionIdentifier,
                relativePath: path
            ) else { return nil }
            return NSImage(contentsOf: url)
        case .hostAsset:
            // Host assets are scoped to documented component contracts. A standalone panel
            // receives semantic snapshots and package resources instead of private view assets.
            return nil
        }
    }

    private func invoke(_ actionID: String, pendingMessage: String? = nil) {
        actionSequence += 1
        let sequence = actionSequence
        statusMessage = pendingMessage ?? "Running “\(actionID)”…"
        render()

        guard router?.invokePanelAction(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            actionID: actionID,
            context: context,
            completion: { [weak self] result in
                guard let self, self.actionSequence == sequence else { return }
                self.present(result)
            }
        ) == true else {
            statusMessage = "The extension panel is no longer available."
            render()
            return
        }
    }

    private func present(_ result: Result<ExtensionActionResponse, Error>) {
        switch result {
        case .failure(let error):
            statusMessage = error.localizedDescription

        case .success(let response):
            if let error = response.error {
                statusMessage = error
            } else {
                if let panel = response.panel {
                    if self.panel?.remoteSurface != panel.remoteSurface {
                        disconnectRemoteSurface()
                        remoteFailureMessage = nil
                    }
                    self.panel = panel
                }
                statusMessage = response.message
            }
        }
        render()
        onChange?()
    }
}
