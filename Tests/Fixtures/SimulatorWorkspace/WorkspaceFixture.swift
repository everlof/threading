import UIKit

/// A disposable guest workload for dedicated workspace simulators. Public scene geometry APIs
/// drive real orientation changes; the advancing clock makes stalled frames visible.
@main
final class WorkspaceFixtureApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Workspace", sessionRole: session.role)
        configuration.delegateClass = WorkspaceFixtureScene.self
        return configuration
    }
}

final class WorkspaceFixtureScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let controller = WorkspaceFixtureController()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
    }

}

final class WorkspaceFixtureController: UIViewController {
    private let clock = UILabel()
    private let geometry = UILabel()
    private var displayLink: CADisplayLink?
    private var orientations: UIInterfaceOrientationMask = .portrait
    private var lastOrientationCommand: String?
    private var nextOrientationCheck: CFTimeInterval = 0
    private let orientationFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("orientation.txt")
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientations }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemIndigo
        let title = UILabel()
        title.text = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--label=") }
            .map { String($0.dropFirst(8)) } ?? "Workspace fixture"
        title.numberOfLines = 0
        title.font = .boldSystemFont(ofSize: 26)
        clock.font = .monospacedDigitSystemFont(ofSize: 30, weight: .medium)
        let controls = [button("Portrait", landscape: false), button("Landscape", landscape: true)]
        let stack = UIStackView(arrangedSubviews: [title, clock, geometry] + controls)
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        for label in [title, clock, geometry] { label.textColor = .white }
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.85)
        ])
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 10, preferred: 10)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func button(_ title: String, landscape: Bool) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.orient(landscape: landscape)
        })
    }

    func orient(landscape: Bool) {
        orientations = landscape ? .landscapeLeft : .portrait
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        clock.text = String(format: "%.1f seconds", now)
        geometry.text = "\(Int(view.bounds.width)) × \(Int(view.bounds.height)) points"
        guard now >= nextOrientationCheck else { return }
        nextOrientationCheck = now + 0.5
        // Test input is a tiny command in this disposable app's own container. UIKit still owns
        // the actual orientation transition, and the on-screen buttons use the same method.
        guard let request = try? String(contentsOf: orientationFile, encoding: .utf8),
              request != lastOrientationCommand,
              let command = request.split(separator: "\n").first,
              ["portrait", "landscape"].contains(String(command)) else { return }
        lastOrientationCommand = request
        orient(landscape: command == "landscape")
    }
}
