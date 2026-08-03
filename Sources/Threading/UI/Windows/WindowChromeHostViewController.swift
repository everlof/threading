import AppKit

/// The main window's permanent content root: the app-drawn chrome around the workspace.
///
/// Permanent in both dress states on purpose. Assigning a window's `contentViewController`
/// resizes the window to the controller's fitting size (`MainWindowController.applyInitialFrame`
/// records the cost), so the root must never be swapped during a live theme flip — instead the
/// chrome collapses: in native dress the band is hidden at zero height and the frame inset is
/// zero, which is geometrically identical to the workspace being the root. In takeover the band
/// takes the theme's height and the frame its width, and the workspace sits inside both.
///
/// This also moves the whole chrome tree inside `contentViewController.view`, which is where
/// `ThemeBoundaryAudit` begins — an app-drawn frame is app-owned surface and gets audited like
/// any other, which is the point.
final class WindowChromeHostViewController: NSViewController {

    private let workspaceViewController: NSViewController
    private(set) lazy var bandView = WindowTitleBandView()

    private let appEvents = AppEventObservations()
    private(set) var isTakeoverActive = false

    private var bandHeight: NSLayoutConstraint?
    private var bandTop: NSLayoutConstraint?
    private var bandLeading: NSLayoutConstraint?
    private var bandTrailing: NSLayoutConstraint?
    private var workspaceLeading: NSLayoutConstraint?
    private var workspaceTrailing: NSLayoutConstraint?
    private var workspaceBottom: NSLayoutConstraint?

    // MARK: - Initialization

    init(workspace: NSViewController) {
        workspaceViewController = workspace
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
        view.addSubview(bandView)
        view.addSubview(workspace)

        let bandTop = bandView.topAnchor.constraint(equalTo: view.topAnchor)
        let bandLeading = bandView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let bandTrailing = bandView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let bandHeight = bandView.heightAnchor.constraint(equalToConstant: 0)
        let workspaceLeading = workspace.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let workspaceTrailing = workspace.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let workspaceBottom = workspace.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        self.bandTop = bandTop
        self.bandLeading = bandLeading
        self.bandTrailing = bandTrailing
        self.bandHeight = bandHeight
        self.workspaceLeading = workspaceLeading
        self.workspaceTrailing = workspaceTrailing
        self.workspaceBottom = workspaceBottom

        NSLayoutConstraint.activate([
            bandTop, bandLeading, bandTrailing, bandHeight,
            workspace.topAnchor.constraint(equalTo: bandView.bottomAnchor),
            workspaceLeading, workspaceTrailing, workspaceBottom
        ])

        bandView.isHidden = true

        // The theme's chrome measures may change while worn — an agent editing the live theme
        // through `update_app_theme` — so the chrome re-measures on every theme event, not
        // only on the flip.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyMeasures()
        }
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
        bandView.setTitle(title)
    }

    private func applyMeasures() {
        let resolved = isTakeoverActive ? WindowChromeAppearance.resolve() : nil

        let inset = resolved?.frameWidth ?? 0
        bandTop?.constant = inset
        bandLeading?.constant = inset
        bandTrailing?.constant = -inset
        workspaceLeading?.constant = inset
        workspaceTrailing?.constant = -inset
        workspaceBottom?.constant = -inset

        bandHeight?.constant = resolved?.bandHeight ?? 0
        bandView.isHidden = resolved == nil
        view.needsDisplay = true
    }
}
