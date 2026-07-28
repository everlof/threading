import AppKit
import SkalmanRemoteKit

/// An approval request shown inline in the conversation it belongs to.
///
/// A modal sheet was the wrong shape for a chat: it seized the whole window for a decision that
/// belongs to one session, and gave no clue which session had asked when several were running.
/// Here the request sits in the thread that raised it, keeps its place in the transcript after
/// it is answered, and — through the sidebar's attention dot — announces itself from a session
/// that is not on screen.
final class PermissionRequestView: NSView {

    // MARK: - Properties

    private let request: PermissionRequest
    private let remoteID = UUID().uuidString
    private var onDecision: ((PermissionDecision) -> Void)?
    private lazy var safeRemoteRequest = makeRemoteRequest()

    private var buttonRow: NSStackView!
    private var resolvedLabel: NSTextField!

    private var isResolved = false

    // MARK: - Initialization

    init(request: PermissionRequest, onDecision: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.onDecision = onDecision
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // An accent border rather than a fill, so a waiting request reads as active without
        // shouting over the conversation around it.
        applySurface(fill: Design.Surface.panel, radius: .control, border: Design.Surface.accent)

        let title = NSTextField(
            labelWithString: L10n.format("Allow %@?", request.toolName)
        )
        title.applyFont(.caption, in: .conversation)
        title.textColor = Design.Text.label
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(wrappingLabelWithString: request.summary)
        detail.applyFont(.code())
        detail.textColor = Design.Text.secondary
        detail.isSelectable = true
        detail.translatesAutoresizingMaskIntoConstraints = false

        resolvedLabel = NSTextField(labelWithString: "")
        resolvedLabel.applyFont(.caption, in: .conversation)
        resolvedLabel.translatesAutoresizingMaskIntoConstraints = false
        resolvedLabel.isHidden = true

        buttonRow = makeButtonRow()

        let column = NSStackView(views: [title, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.tight
        column.translatesAutoresizingMaskIntoConstraints = false

        // An edit is approved on what it changes, so its diff sits between the summary and the
        // buttons — the same view the tool row and the old sheet used.
        if let diff = EditDiff.lines(forTool: request.toolName, input: request.input) {
            column.addArrangedSubview(makeDiffPreview(diff, path: request.filePath))
        }

        addSubview(column)
        addSubview(buttonRow)
        addSubview(resolvedLabel)

        let inset = Design.Spacing.medium
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            buttonRow.topAnchor.constraint(equalTo: column.bottomAnchor, constant: inset),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),

            resolvedLabel.topAnchor.constraint(equalTo: column.bottomAnchor, constant: inset),
            resolvedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
        ])
    }

    private func makeButtonRow() -> NSStackView {
        let allow = makeButton(L10n.string("Allow"), action: #selector(allowOnce))
        allow.keyEquivalent = "\r"  // Return approves, matching the old sheet's default.

        let row = NSStackView(views: [
            allow,
            makeButton(L10n.string("Allow for Session"), action: #selector(allowSession)),
            makeButton(L10n.string("Deny"), action: #selector(deny))
        ])
        row.orientation = .horizontal
        row.spacing = Design.Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeButton(_ title: String, action: Selector) -> ThemedButton {
        let button = ThemedButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// The diff, bounded so a large edit scrolls inside the card rather than growing it without
    /// limit — the buttons must stay reachable.
    private func makeDiffPreview(_ diff: [DiffLine], path: String?) -> NSView {
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let diffView = DiffView(lines: diff, path: path)
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = diffView

        NSLayoutConstraint.activate([
            diffView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            diffView.topAnchor.constraint(equalTo: clip.topAnchor),
            diffView.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: PermissionCardDefaults.maxDiffHeight)
        ])

        return scroll
    }

    // MARK: - Public Methods

    /// Resolves the request without a click, used when the session ends while it is pending.
    func resolve(_ decision: PermissionDecision) {
        settle(decision, note: L10n.string("Denied — session ended."))
    }

    /// The safe, provider-neutral part of the card a paired remote client may render.
    var remoteRequest: RemotePermissionRequestDTO {
        safeRemoteRequest
    }

    private func makeRemoteRequest() -> RemotePermissionRequestDTO {
        let diff = (EditDiff.lines(forTool: request.toolName, input: request.input) ?? [])
            .enumerated()
            .map { index, line in
                let kind: String
                switch line.kind {
                case .context: kind = "context"
                case .added: kind = "addition"
                case .removed: kind = "removal"
                }
                return RemotePermissionDiffLineDTO(
                    id: String(index),
                    kind: kind,
                    text: line.text
                )
            }
        return RemoteConversationWirePolicy.safePermission(RemotePermissionRequestDTO(
            id: remoteID,
            toolName: request.toolName,
            summary: request.summary,
            filePath: request.filePath,
            diff: diff
        ))
    }

    /// Resolves the same card from an authenticated interactive client. It deliberately offers
    /// only one-shot allow or deny; session-wide policy remains a local Mac decision.
    func resolveRemote(id: String, decision: String) -> Bool {
        guard id == remoteID, !isResolved, remoteRequest.canDecide else { return false }
        switch decision {
        case "allow":
            settle(
                .allow(reason: "Approved from a paired Skalman device."),
                note: L10n.string("Allowed remotely.")
            )
        case "deny":
            settle(
                .deny(reason: "The user declined from a paired Skalman device."),
                note: L10n.string("Denied remotely.")
            )
        default:
            return false
        }
        return true
    }

    // MARK: - Actions

    @objc private func allowOnce() {
        settle(.allow(reason: "Approved in Skalman."), note: L10n.string("Allowed."))
    }

    @objc private func allowSession() {
        PermissionBroker.allowAlways(toolName: request.toolName, for: request.sessionID)
        settle(.allow(reason: "Approved in Skalman for the rest of this session."),
               note: L10n.string("Allowed for this session."))
    }

    @objc private func deny() {
        settle(.deny(reason: "The user declined in Skalman."), note: L10n.string("Denied."))
    }

    /// Records the decision, swaps the buttons for a one-line outcome so the transcript keeps a
    /// record of what was chosen, and calls back exactly once.
    private func settle(_ decision: PermissionDecision, note: String) {
        guard !isResolved else { return }
        isResolved = true

        buttonRow.isHidden = true
        resolvedLabel.isHidden = false
        resolvedLabel.stringValue = note
        resolvedLabel.textColor = note.hasPrefix("Denied") ? Design.Status.negative : Design.Text.secondary

        applyLayerBorder(Design.Surface.border)

        // The controller's closure refers back to this card while it advances the queue.
        // Release it before invoking it so a settled card keeps only its visual record, not
        // the callback, the card itself, or the MCP response continuation behind the callback.
        let callback = onDecision
        onDecision = nil
        callback?(decision)
    }
}

// MARK: - Permission Card Defaults

enum PermissionCardDefaults {
    static let maxDiffHeight: CGFloat = 240
}
