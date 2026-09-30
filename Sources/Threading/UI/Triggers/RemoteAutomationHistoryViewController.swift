import AppKit
import ThreadingController

@MainActor
final class RemoteAutomationHistoryViewController: NSViewController {
    private let automation: ControllerAutomation
    private let endpoint: RemoteAutomationEndpoint
    private let destination: RemoteHostDestination
    private var page: ControllerPage<ControllerAutomationRunStatus>
    private let detail = ThemedTextView.scrolling()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let next = ThemedButton()
    private var busy = false

    init(automation: ControllerAutomation, endpoint: RemoteAutomationEndpoint,
         destination: RemoteHostDestination, page: ControllerPage<ControllerAutomationRunStatus>) {
        self.automation = automation; self.endpoint = endpoint; self.destination = destination; self.page = page
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let surface = ThemedSurfaceView()
        surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        surface.frame = NSRect(x: 0, y: 0, width: Design.Size.readableWidth + Design.Spacing.pane * 2, height: 540)
        view = surface
        let title = NSTextField(labelWithString: automation.spec.name); title.applyFont(.heading)
        detail.textView.isEditable = false
        status.applyFont(.detail())
        let first = ThemedButton(); first.title = L10n.string("First page"); first.target = self; first.action = #selector(firstPressed)
        next.title = L10n.string("Next"); next.target = self; next.action = #selector(nextPressed)
        let close = ThemedButton(); close.title = L10n.string("Done"); close.target = self; close.action = #selector(closePressed)
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [first, next, NSView(), close]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, detail, status, buttons]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = Design.Spacing.medium; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.pane)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        render()
    }
    private func render() {
        detail.textView.string = page.items.map { item in
            "\(item.run.recordedAt.formatted()) · \(item.workState?.rawValue ?? item.run.admission)\(item.archived ? " · " + L10n.string("Archived") : "")\n\(item.result ?? "")"
        }.joined(separator: "\n\n")
        status.stringValue = page.items.isEmpty ? L10n.string("No activity") : ""
        next.isEnabled = !page.items.isEmpty
        detail.textView.scrollToBeginningOfDocument(nil)
    }
    @objc private func closePressed() { presentingViewController?.dismiss(self) }
    @objc private func firstPressed() { fetch(after: 0) }
    @objc private func nextPressed() { fetch(after: page.next) }
    private func fetch(after cursor: Int64) {
        guard !busy else { return }
        busy = true; next.isEnabled = false
        Task { @MainActor in
            defer { busy = false }
            do {
                let response = try await AutomationCommands.remote(.init(operation: "runs", id: automation.id.description,
                    remote: endpoint, cursor: cursor), destination: destination)
                page = try await Task.detached(priority: .utility) {
                    try JSONDecoder().decode(ControllerPage<ControllerAutomationRunStatus>.self, from: Data(response.utf8))
                }.value
                render()
            } catch { status.stringValue = error.localizedDescription; next.isEnabled = true }
        }
    }
}
