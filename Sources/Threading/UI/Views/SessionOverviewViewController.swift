import AppKit

/// The two readings that used to occupy separate display-panel tabs.
///
/// The persisted spellings remain `.files` and `.info` so an older build can still restore a
/// layout written by this one. In memory they are one durable surface, and this value records
/// which part of it the user was reading.
enum SessionOverviewSection: String, CaseIterable {
    case activity
    case info

    var title: String {
        switch self {
        case .activity: return L10n.string("Activity")
        case .info: return L10n.string("Info")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .activity: return "session-overview.section.activity"
        case .info: return "session-overview.section.info"
        }
    }
}

/// One session-owned display surface for filesystem work and live runtime information.
///
/// Only the selected child is attached to the window. That is the performance and lifecycle
/// boundary: opening Activity does not build process rows or start Info polling, and switching
/// back removes Info from the window so `SessionInfoViewController` stops its timer. The Activity
/// controller keeps its already-expanded lazy tree, just as its former singleton tab did.
@MainActor
final class SessionOverviewViewController: NSViewController {

    typealias ActivityFactory = @MainActor () -> FileTreeViewController
    typealias InfoFactory = @MainActor () -> SessionInfoViewController

    private let sessionID: SessionID
    private let activityFactory: ActivityFactory
    private let infoFactory: InfoFactory
    private let sectionControl = ThemedSegmentedControl()
    private let contentView = NSView()
    private let separator = SeparatorView()

    private(set) var selectedSection: SessionOverviewSection
    private(set) var activityControllerIfLoaded: FileTreeViewController?
    private(set) var infoControllerIfLoaded: SessionInfoViewController?
    private weak var installedController: NSViewController?
    private var installedConstraints: [NSLayoutConstraint] = []

    /// The display pane persists an ordinary Overview through this callback. A synthetic empty-
    /// pane Overview leaves it nil, so merely opening and closing the pane writes no layout.
    var onSectionChange: ((SessionOverviewSection) -> Void)?

    init(
        sessionID: SessionID,
        initialSection: SessionOverviewSection = .info,
        activityFactory: @escaping ActivityFactory,
        infoFactory: @escaping InfoFactory
    ) {
        self.sessionID = sessionID
        self.selectedSection = initialSection
        self.activityFactory = activityFactory
        self.infoFactory = infoFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.setAccessibilityIdentifier("session-overview")
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        sectionControl.translatesAutoresizingMaskIntoConstraints = false
        sectionControl.configure(
            titles: SessionOverviewSection.allCases.map(\.title),
            selectedIndex: selectedSectionIndex
        )
        sectionControl.setAccessibilityIdentifier("session-overview.sections")
        for (index, section) in SessionOverviewSection.allCases.enumerated() {
            sectionControl.segment(at: index)?.setAccessibilityIdentifier(
                section.accessibilityIdentifier
            )
        }
        sectionControl.onSelect = { [weak self] index in
            guard SessionOverviewSection.allCases.indices.contains(index) else { return }
            self?.select(SessionOverviewSection.allCases[index])
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sectionControl)
        view.addSubview(separator)
        view.addSubview(contentView)

        NSLayoutConstraint.activate([
            sectionControl.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.small
            ),
            sectionControl.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            sectionControl.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),

            separator.topAnchor.constraint(
                equalTo: sectionControl.bottomAnchor,
                constant: Design.Spacing.small
            ),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        installSelectedController()
    }

    /// Selects a part of Overview. Programmatic routes (View ▸ Activity / Session Info) use the
    /// same path as the segmented control, so selection, refresh and persistence cannot drift.
    func select(_ section: SessionOverviewSection) {
        let changed = selectedSection != section
        selectedSection = section

        if isViewLoaded {
            sectionControl.selectedIndex = selectedSectionIndex
            installSelectedController()
            if view.window != nil { refreshSelectedSection() }
        }

        if changed { onSectionChange?(section) }
    }

    /// Returns Activity's controller without requiring its view or filesystem to be loaded.
    @discardableResult
    func selectActivity() -> FileTreeViewController {
        let controller = activityController()
        select(.activity)
        return controller
    }

    /// Returns Info's controller without starting its poll until Overview is actually visible.
    @discardableResult
    func selectInfo() -> SessionInfoViewController {
        let controller = infoController()
        select(.info)
        return controller
    }

    /// Re-reads only what is on screen. The unselected child remains detached and idle.
    func refreshSelectedSection() {
        switch selectedSection {
        case .activity:
            activityController().refresh()
            AgentWorkHydration.hydrate(sessionID: sessionID)
        case .info:
            infoController().refresh()
        }
    }

    /// A turn boundary may change both the checkout and the processes it is running. Refresh the
    /// visible reading only; the other section takes a fresh reading when selected.
    func sessionDidStopWorking() {
        guard isViewLoaded, view.window != nil else { return }
        refreshSelectedSection()
    }

    private var selectedSectionIndex: Int {
        SessionOverviewSection.allCases.firstIndex(of: selectedSection) ?? 0
    }

    private func activityController() -> FileTreeViewController {
        if let activityControllerIfLoaded { return activityControllerIfLoaded }
        let controller = activityFactory()
        addChild(controller)
        activityControllerIfLoaded = controller
        return controller
    }

    private func infoController() -> SessionInfoViewController {
        if let infoControllerIfLoaded { return infoControllerIfLoaded }
        let controller = infoFactory()
        addChild(controller)
        infoControllerIfLoaded = controller
        return controller
    }

    private func installSelectedController() {
        let controller: NSViewController
        switch selectedSection {
        case .activity: controller = activityController()
        case .info: controller = infoController()
        }
        guard installedController !== controller else { return }

        NSLayoutConstraint.deactivate(installedConstraints)
        installedConstraints.removeAll(keepingCapacity: true)
        installedController?.view.removeFromSuperview()
        installedController = controller
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controller.view)
        installedConstraints = [
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(installedConstraints)
    }
}
