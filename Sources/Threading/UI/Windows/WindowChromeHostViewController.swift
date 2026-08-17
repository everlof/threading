import AppKit

/// The main window's permanent content root: the app-drawn chrome around the workspace.
///
/// Permanent in both dress states on purpose. Assigning a window's `contentViewController`
/// resizes the window to the controller's fitting size (`MainWindowController.applyInitialFrame`
/// records the cost), so the root must never be swapped during a live theme flip — instead the
/// chrome collapses: in native dress the title and command bands are hidden at zero height and the frame inset is
/// zero, which is geometrically identical to the workspace being the root. In takeover the band
/// takes the theme's height and the frame its width, and the workspace sits inside both.
///
/// This also moves the whole chrome tree inside `contentViewController.view`, which is where
/// `ThemeBoundaryAudit` begins — an app-drawn frame is app-owned surface and gets audited like
/// any other, which is the point.
final class WindowChromeHostViewController: NSViewController {

    private let workspaceViewController: NSViewController

    /// Everything the theme's frame surrounds — the band, the command band and the workspace —
    /// held as one thing so a rounded frame can clip them to its *inner* curve. The frame's
    /// margin is `frameWidth` wide on the straight runs, and it has to stay that wide through
    /// the corner: content inset only on its four sides reaches square into a rounded corner and
    /// covers the curved run of the seat `WindowChromeFrameView` draws there. Measured under the
    /// Threading theme's twelve-point frame, the border read as two straight lines that stopped
    /// short of each other, with the band's own rounded edge (the host's clip) between them.
    private let contentWell = NSView()
    private let bandHost = NSView()
    private let commandBandHost = NSView()
    private var installedBandView: WindowTitleBandView?
    private var installedCommandBandView: WindowCommandBandView?
    private var pendingTitle = ""

    /// A native window carries only two zero-height structural slots. App-icon lookup, title-band
    /// fonts and takeover controls do not exist until a theme actually exposes them.
    private(set) var takeoverChromeIsMaterialized = false

    var bandView: WindowTitleBandView {
        materializeTakeoverChromeIfNeeded()
        return installedBandView!
    }

    var commandBandView: WindowCommandBandView {
        materializeTakeoverChromeIfNeeded()
        return installedCommandBandView!
    }

    private let appEvents = AppEventObservations()
    private(set) var isTakeoverActive: Bool

    private var bandHeight: NSLayoutConstraint?
    private var commandBandHeight: NSLayoutConstraint?
    private var wellTop: NSLayoutConstraint?
    private var wellLeading: NSLayoutConstraint?
    private var wellTrailing: NSLayoutConstraint?
    private var wellBottom: NSLayoutConstraint?

    /// Where a covering surface may sit — see `InWindowOverlayHosting`.
    private let overlayAreaGuide = NSLayoutGuide()

    /// Where the wash under that surface may reach — see `InWindowOverlayHosting`.
    private let overlayScrimAreaGuide = NSLayoutGuide()

    // MARK: - Initialization

    init(workspace: NSViewController, initialTakeoverActive: Bool = false) {
        workspaceViewController = workspace
        isTakeoverActive = initialTakeoverActive
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = WindowChromeFrameView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(workspaceViewController)
        let workspace = workspaceViewController.view
        workspace.translatesAutoresizingMaskIntoConstraints = false
        contentWell.translatesAutoresizingMaskIntoConstraints = false
        bandHost.translatesAutoresizingMaskIntoConstraints = false
        commandBandHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentWell)
        contentWell.addSubview(bandHost)
        contentWell.addSubview(commandBandHost)
        contentWell.addSubview(workspace)

        // The frame's inset is the well's; band and workspace fill the well edge to edge.
        let wellTop = contentWell.topAnchor.constraint(equalTo: view.topAnchor)
        let wellLeading = contentWell.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let wellTrailing = contentWell.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let wellBottom = contentWell.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        let bandHeight = bandHost.heightAnchor.constraint(equalToConstant: 0)
        let commandBandHeight = commandBandHost.heightAnchor.constraint(equalToConstant: 0)
        self.wellTop = wellTop
        self.wellLeading = wellLeading
        self.wellTrailing = wellTrailing
        self.wellBottom = wellBottom
        self.bandHeight = bandHeight
        self.commandBandHeight = commandBandHeight

        NSLayoutConstraint.activate([
            wellTop, wellLeading, wellTrailing, wellBottom,
            bandHost.topAnchor.constraint(equalTo: contentWell.topAnchor),
            bandHost.leadingAnchor.constraint(equalTo: contentWell.leadingAnchor),
            bandHost.trailingAnchor.constraint(equalTo: contentWell.trailingAnchor),
            bandHeight,
            commandBandHost.topAnchor.constraint(equalTo: bandHost.bottomAnchor),
            commandBandHost.leadingAnchor.constraint(equalTo: bandHost.leadingAnchor),
            commandBandHost.trailingAnchor.constraint(equalTo: bandHost.trailingAnchor),
            commandBandHeight,
            workspace.topAnchor.constraint(equalTo: commandBandHost.bottomAnchor),
            workspace.leadingAnchor.constraint(equalTo: contentWell.leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: contentWell.trailingAnchor),
            workspace.bottomAnchor.constraint(equalTo: contentWell.bottomAnchor)
        ])

        installOverlayArea(around: workspace)

        // The theme's chrome measures may change while worn — an agent editing the live theme
        // through `update_app_theme` — so the chrome re-measures on every theme event, not
        // only on the flip.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyMeasures()
        }
        applyMeasures()
    }

    private func materializeTakeoverChromeIfNeeded() {
        guard !takeoverChromeIsMaterialized else { return }
        // Accessing `view` is the macOS 13-compatible way to force this controller's
        // programmatic view load (`loadViewIfNeeded` is only available from macOS 14).
        _ = view
        guard !takeoverChromeIsMaterialized else { return }

        let band = WindowTitleBandView()
        let commandBand = WindowCommandBandView()
        band.translatesAutoresizingMaskIntoConstraints = false
        commandBand.translatesAutoresizingMaskIntoConstraints = false
        band.setTitle(pendingTitle)
        band.isHidden = !isTakeoverActive
        commandBand.isHidden = !isTakeoverActive
        bandHost.addSubview(band)
        commandBandHost.addSubview(commandBand)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: bandHost.topAnchor),
            band.bottomAnchor.constraint(equalTo: bandHost.bottomAnchor),
            band.leadingAnchor.constraint(equalTo: bandHost.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: bandHost.trailingAnchor),
            commandBand.topAnchor.constraint(equalTo: commandBandHost.topAnchor),
            commandBand.bottomAnchor.constraint(equalTo: commandBandHost.bottomAnchor),
            commandBand.leadingAnchor.constraint(equalTo: commandBandHost.leadingAnchor),
            commandBand.trailingAnchor.constraint(equalTo: commandBandHost.trailingAnchor)
        ])
        installedBandView = band
        installedCommandBandView = commandBand
        takeoverChromeIsMaterialized = true
    }

    // MARK: - Overlay Area

    /// The area a transient surface may cover, stated as the *greater* of the two edges it has
    /// to clear rather than as whichever dress is on.
    ///
    /// In takeover the band is this window's titlebar — it carries the close, minimize and zoom —
    /// so an overlay starts under it and stays inside the drawn frame. In native dress the band
    /// is zero-height at the very top and the strip to clear is AppKit's own, which is what the
    /// safe area names. Written as two `>=` and a low-priority pull upward, the guide answers
    /// `max` of the two live: a theme flip while a surface is open moves it rather than leaving
    /// it pinned to the dress it opened in.
    private func installOverlayArea(around workspace: NSView) {
        view.addLayoutGuide(overlayAreaGuide)

        let pullUp = overlayAreaGuide.topAnchor.constraint(equalTo: view.topAnchor)
        pullUp.priority = .defaultLow

        NSLayoutConstraint.activate([
            overlayAreaGuide.topAnchor.constraint(greaterThanOrEqualTo: workspace.topAnchor),
            overlayAreaGuide.topAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor
            ),
            pullUp,
            overlayAreaGuide.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            overlayAreaGuide.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            overlayAreaGuide.bottomAnchor.constraint(equalTo: workspace.bottomAnchor)
        ])

        installOverlayScrimArea(around: workspace)
    }

    /// The area the scrim under a transient surface may dim: everything below this window's own
    /// buttons, which is more than the surface itself may cover.
    ///
    /// The band is the only chrome here that must stay reachable — in takeover it carries the
    /// close, minimize and zoom. Everything under it, the command row included, is behind the
    /// modal and dims with the workspace. In native dress the band is zero-height at the very top,
    /// so `bandHost.bottomAnchor` *is* the content view's top and the wash takes the whole of it,
    /// including the strip under AppKit's transparent titlebar that the surface has to clear. The
    /// theme's drawn frame stays out of it: a border dimmed on three sides reads as the window
    /// having lost its edge rather than as something opened in front of it.
    private func installOverlayScrimArea(around workspace: NSView) {
        view.addLayoutGuide(overlayScrimAreaGuide)

        NSLayoutConstraint.activate([
            overlayScrimAreaGuide.topAnchor.constraint(equalTo: bandHost.bottomAnchor),
            overlayScrimAreaGuide.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            overlayScrimAreaGuide.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            overlayScrimAreaGuide.bottomAnchor.constraint(equalTo: workspace.bottomAnchor)
        ])
    }

    // MARK: - Dress

    /// The coordinator's content-side half: the mask decides what AppKit draws, this decides
    /// what the app draws.
    func setTakeoverActive(_ active: Bool) {
        isTakeoverActive = active
        applyMeasures()
    }

    /// The window controller's title push — the one place the window's name is decided
    /// already calls this beside setting `window.title`.
    func setTitle(_ title: String) {
        pendingTitle = title
        installedBandView?.setTitle(title)
    }

    private func applyMeasures() {
        let resolved = isTakeoverActive ? WindowChromeAppearance.resolve() : nil
        if resolved != nil {
            materializeTakeoverChromeIfNeeded()
        }

        let cornerRadius = resolved?.frameSilhouetteCornerRadius ?? 0
        if cornerRadius > 0 { view.wantsLayer = true }
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = cornerRadius > 0

        let inset = resolved?.frameWidth ?? 0
        wellTop?.constant = inset
        wellLeading?.constant = inset
        wellTrailing?.constant = -inset
        wellBottom?.constant = -inset

        // The margin keeps its width through the corner: the content turns `inset` inside the
        // silhouette, concentric with it, which is exactly the run the frame's seat occupies.
        // Under a square frame — or one whose radius is swallowed by its own width — nothing is
        // clipped, and native dress never grows a layer here at all.
        let wellRadius = max(0, cornerRadius - inset)
        if wellRadius > 0 { contentWell.wantsLayer = true }
        contentWell.layer?.cornerRadius = wellRadius
        contentWell.layer?.masksToBounds = wellRadius > 0

        bandHeight?.constant = resolved?.bandHeight ?? 0
        commandBandHeight?.constant = resolved == nil ? 0 : WindowCommandBandView.bandHeight
        bandHost.isHidden = resolved == nil
        commandBandHost.isHidden = resolved == nil
        installedBandView?.isHidden = resolved == nil
        installedCommandBandView?.isHidden = resolved == nil
        view.needsDisplay = true
    }
}

// MARK: - InWindowOverlayHosting

extension WindowChromeHostViewController: InWindowOverlayHosting {
    var overlayArea: NSLayoutGuide { overlayAreaGuide }
    var overlayScrimArea: NSLayoutGuide { overlayScrimAreaGuide }
}
