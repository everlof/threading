import AppKit
import ThreadingExtensionKit

/// Hosts one read-only semantic document produced through Threading's MCP display surface.
///
/// Extension panels use the same renderer with a live action bridge. An MCP response has no
/// process waiting for later clicks, so this surface deliberately accepts informative nodes only.
@MainActor
final class SemanticDocumentViewController: NSViewController {
  private let root: ExtensionNode
  private let scrollView = ThemedScrollView()
  private let contentStack = NSStackView()

  init(root: ExtensionNode) {
    self.root = root
    super.init(nibName: nil, bundle: nil)
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
      contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])

    do {
      let rendered = try ExtensionNodeRenderer.render(root, onAction: { _ in })
      rendered.setAccessibilityIdentifier("display.semantic-document")
      contentStack.addArrangedSubview(rendered)
      rendered.widthAnchor.constraint(
        equalTo: contentStack.widthAnchor,
        constant: -(Design.Spacing.pane * 2)
      ).isActive = true
    } catch {
      let failure = NSTextField(
        wrappingLabelWithString: L10n.format(
          "This native document could not be rendered: %@",
          error.localizedDescription
        )
      )
      failure.applyFont(.body)
      failure.textColor = Design.Status.negative
      contentStack.addArrangedSubview(failure)
      failure.widthAnchor.constraint(
        equalTo: contentStack.widthAnchor,
        constant: -(Design.Spacing.pane * 2)
      ).isActive = true
    }
  }
}
