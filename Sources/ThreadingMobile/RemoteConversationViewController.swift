import Combine
import PhotosUI
import SwiftUI
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers

/// Owns the edge treatment for every native conversation host.
///
/// SwiftUI otherwise decides inconsistently whether a hosted UIKit controller stops above the
/// home-indicator safe area. Extending the controller is what lets the composer material reach
/// the physical bottom edge; the controller's own safe-area constraints still keep controls out
/// of that reserved region. Everything that changes while a chat is open remains observed and
/// laid out by the UIKit bridge, so transcript and keyboard updates do not invalidate a hosting
/// tree transaction.
struct ConversationRemoteView: View {
    let connection: RemoteSessionConnection

    var body: some View {
        VStack(spacing: 0) {
            MobileRunPlanDisclosure(connection: connection)
            RemoteConversationViewControllerBridge(connection: connection)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

private struct RemoteConversationViewControllerBridge: UIViewControllerRepresentable {
    let connection: RemoteSessionConnection
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var continuity: MobileSessionContinuityStore
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var inheritedTheme

    func makeUIViewController(context: Context) -> RemoteConversationViewController {
        RemoteConversationViewController(
            connection: connection,
            model: model,
            continuity: continuity,
            notifications: notifications,
            inheritedTheme: inheritedTheme
        )
    }

    func updateUIViewController(
        _ controller: RemoteConversationViewController,
        context: Context
    ) {
        controller.updateInheritedTheme(inheritedTheme)
    }
}

@MainActor
final class RemoteConversationViewController: UIViewController, UITextViewDelegate {
    private let connection: RemoteSessionConnection
    private let model: RemoteAppModel
    private let continuity: MobileSessionContinuityStore
    private let notifications: RemoteNotificationManager
    private var inheritedTheme: RemoteThemePalette
    private var theme: RemoteThemePalette
    private var observations: Set<AnyCancellable> = []
    private var renderScheduled = false
    private var bottomConstraint: NSLayoutConstraint!
    private var composerLeadingConstraint: NSLayoutConstraint!
    private var composerTrailingConstraint: NSLayoutConstraint!
    private var composerTopConstraint: NSLayoutConstraint!
    private var composerBottomConstraint: NSLayoutConstraint!
    private var composerPanelSafeBottomConstraint: NSLayoutConstraint!
    private var composerStackSafeBottomConstraint: NSLayoutConstraint!
    private var composerStackPanelBottomConstraint: NSLayoutConstraint!

    private let bottomStack = UIStackView()
    private let capabilityContainer = UIView()
    private let capabilityScrollView = UIScrollView()
    private let capabilityStack = UIStackView()
    private let capabilityOutline = MobileThemeOutlineView()
    private var capabilityHeightConstraint: NSLayoutConstraint!
    private let presenceLabel = InsetsLabel()
    private let controlBar = UIView()
    private let controlIcon = UIImageView()
    private let controlLabel = UILabel()
    private let requestControlButton = UIButton(type: .system)
    private let controlMenuButton = UIButton(type: .system)
    private let attentionLabel = InsetsLabel()
    private let submissionLabel = InsetsLabel()
    private let composerShell = UIView()
    private let composerPanel = UIView()
    private let composerOutline = MobileThemeOutlineView()
    private let composerStack = UIStackView()
    private let capabilityButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private let attentionButton = UIButton(type: .system)
    /// The strip and the row of controls, stacked. The panel used to hold the control row
    /// directly; attachments needed something above it that scrolls independently of the text.
    private let composerContentStack = UIStackView()
    private let attachmentStrip = ComposerAttachmentStripView()
    /// Created once a client exists, which is why it is not a `let`: the controller is built
    /// before the app model has necessarily resolved one, and a composer with no client simply
    /// shows no attach button.
    private var attachmentTray: ComposerAttachmentTray?
    /// A picker has dismissed before its provider necessarily returns bytes. Send must wait for
    /// that complete bounded selection, or the prompt can leave while its last photo is still
    /// becoming an attachment.
    private var attachmentPicksInFlight = 0
    private let textView = IntrinsicTextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let navigationTitleView = RemoteConversationNavigationTitleView()

    private lazy var timelineController: RemoteConversationTimelineViewController = {
        let hostID = model.activeHostID
        let saved = hostID.map {
            continuity.state(hostID: $0, sessionID: connection.session.id)
        }
#if DEBUG
        let fixtureViewport: (progress: Double?, followsBottom: Bool)? =
            ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "conversation-away-from-latest"
                ? (0.32, false)
                : nil
#else
        let fixtureViewport: (progress: Double?, followsBottom: Bool)? = nil
#endif
        return RemoteConversationTimelineViewController(
            connection: connection,
            theme: theme,
            initialViewport: fixtureViewport ?? saved.map {
                ($0.conversationViewportProgress, $0.conversationFollowsBottom)
            },
            onViewportChange: { [weak model, weak continuity, weak connection] progress, follows in
                guard let hostID = model?.activeHostID,
                      let sessionID = connection?.session.id else { return }
                continuity?.setConversationViewport(
                    progress: progress,
                    followsBottom: follows,
                    hostID: hostID,
                    sessionID: sessionID
                )
            }
        )
    }()

    private var showsCapabilityCatalog = false
    private var capabilityKindFilter: RemoteComposerCapabilityKind?
    private var preservedSkillArguments: String?
    private var pendingSubmissionID: String?
    private var submissionNotice: String?
    private var lastSubmissionFeedback: RemotePromptSubmissionFeedback?
    private var lastCapabilities: [RemoteComposerCapabilityDTO] = []
    private var initiallyFocused = false
    private var keyboardIsVisible = false

    init(
        connection: RemoteSessionConnection,
        model: RemoteAppModel,
        continuity: MobileSessionContinuityStore,
        notifications: RemoteNotificationManager,
        inheritedTheme: RemoteThemePalette
    ) {
        self.connection = connection
        self.model = model
        self.continuity = continuity
        self.notifications = notifications
        self.inheritedTheme = inheritedTheme
        theme = connection.theme.map(RemoteThemePalette.init) ?? inheritedTheme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureActions()
        restoreDraft()
        observeState()
        renderState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installNavigationTitle()
        guard initiallyFocusesComposer, !initiallyFocused else { return }
        initiallyFocused = true
        if textView.text.isEmpty {
            textView.text = MobileL10n.string(
                "Check the final layout with the keyboard open and a longer prompt."
            )
            textDidChange()
        }
        textView.becomeFirstResponder()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installNavigationTitle()
    }

    func updateInheritedTheme(_ inheritedTheme: RemoteThemePalette) {
        guard self.inheritedTheme != inheritedTheme else { return }
        self.inheritedTheme = inheritedTheme
        renderState()
    }

    private func configureHierarchy() {
        view.backgroundColor = theme.uiGround

        addChild(timelineController)
        view.addSubview(timelineController.view)
        timelineController.view.translatesAutoresizingMaskIntoConstraints = false
        timelineController.didMove(toParent: self)

        bottomStack.axis = .vertical
        bottomStack.spacing = 0
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomStack)

        configureCapabilityList()
        configureBanner(presenceLabel)
        configureControlBar()
        configureBanner(attentionLabel)
        configureBanner(submissionLabel)
        configureComposer()

        [
            capabilityContainer,
            presenceLabel,
            controlBar,
            attentionLabel,
            submissionLabel,
            composerShell,
        ].forEach(bottomStack.addArrangedSubview)

        bottomConstraint = bottomStack.bottomAnchor.constraint(
            equalTo: view.bottomAnchor
        )
        NSLayoutConstraint.activate([
            timelineController.view.topAnchor.constraint(equalTo: view.topAnchor),
            timelineController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            timelineController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            timelineController.view.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ])
    }

    private func configureCapabilityList() {
        capabilityContainer.translatesAutoresizingMaskIntoConstraints = false
        capabilityScrollView.translatesAutoresizingMaskIntoConstraints = false
        capabilityStack.translatesAutoresizingMaskIntoConstraints = false
        capabilityStack.axis = .vertical
        capabilityStack.spacing = MobileDesign.Spacing.hairline

        capabilityContainer.addSubview(capabilityScrollView)
        capabilityScrollView.addSubview(capabilityStack)
        capabilityOutline.translatesAutoresizingMaskIntoConstraints = false
        capabilityContainer.addSubview(capabilityOutline)
        capabilityHeightConstraint = capabilityContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            capabilityHeightConstraint,
            capabilityScrollView.leadingAnchor.constraint(
                equalTo: capabilityContainer.leadingAnchor,
                constant: MobileDesign.Spacing.inset
            ),
            capabilityScrollView.trailingAnchor.constraint(
                equalTo: capabilityContainer.trailingAnchor,
                constant: -MobileDesign.Spacing.inset
            ),
            capabilityScrollView.topAnchor.constraint(
                equalTo: capabilityContainer.topAnchor,
                constant: MobileDesign.Spacing.small
            ),
            capabilityScrollView.bottomAnchor.constraint(equalTo: capabilityContainer.bottomAnchor),
            capabilityOutline.leadingAnchor.constraint(equalTo: capabilityScrollView.leadingAnchor),
            capabilityOutline.trailingAnchor.constraint(equalTo: capabilityScrollView.trailingAnchor),
            capabilityOutline.topAnchor.constraint(equalTo: capabilityScrollView.topAnchor),
            capabilityOutline.bottomAnchor.constraint(equalTo: capabilityScrollView.bottomAnchor),
            capabilityStack.leadingAnchor.constraint(equalTo: capabilityScrollView.contentLayoutGuide.leadingAnchor),
            capabilityStack.trailingAnchor.constraint(equalTo: capabilityScrollView.contentLayoutGuide.trailingAnchor),
            capabilityStack.topAnchor.constraint(equalTo: capabilityScrollView.contentLayoutGuide.topAnchor),
            capabilityStack.bottomAnchor.constraint(equalTo: capabilityScrollView.contentLayoutGuide.bottomAnchor),
            capabilityStack.widthAnchor.constraint(equalTo: capabilityScrollView.frameLayoutGuide.widthAnchor),
        ])
        capabilityContainer.isHidden = true
    }

    private func configureBanner(_ label: InsetsLabel) {
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.insets = UIEdgeInsets(
            top: MobileDesign.Spacing.medium,
            left: MobileDesign.Spacing.large,
            bottom: MobileDesign.Spacing.medium,
            right: MobileDesign.Spacing.large
        )
        label.isHidden = true
    }

    private func configureControlBar() {
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlIcon.translatesAutoresizingMaskIntoConstraints = false
        controlIcon.preferredSymbolConfiguration = .init(textStyle: .caption1)
        controlLabel.translatesAutoresizingMaskIntoConstraints = false
        controlLabel.font = .preferredFont(forTextStyle: .caption1)
        controlLabel.adjustsFontForContentSizeCategory = true
        controlLabel.numberOfLines = 0
        requestControlButton.translatesAutoresizingMaskIntoConstraints = false
        requestControlButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        requestControlButton.setTitle(MobileL10n.string("Request control"), for: .normal)
        controlMenuButton.translatesAutoresizingMaskIntoConstraints = false
        controlMenuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        controlMenuButton.showsMenuAsPrimaryAction = true
        controlMenuButton.accessibilityLabel = MobileL10n.string("Input control options")

        [controlIcon, controlLabel, requestControlButton, controlMenuButton].forEach(controlBar.addSubview)
        NSLayoutConstraint.activate([
            controlBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            controlIcon.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: MobileDesign.Spacing.large),
            controlIcon.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            controlIcon.widthAnchor.constraint(equalToConstant: 18),
            controlIcon.heightAnchor.constraint(equalToConstant: 18),
            controlLabel.leadingAnchor.constraint(equalTo: controlIcon.trailingAnchor, constant: MobileDesign.Spacing.small),
            controlLabel.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: MobileDesign.Spacing.small),
            controlLabel.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor, constant: -MobileDesign.Spacing.small),
            requestControlButton.leadingAnchor.constraint(greaterThanOrEqualTo: controlLabel.trailingAnchor, constant: MobileDesign.Spacing.small),
            requestControlButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            requestControlButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget),
            controlMenuButton.leadingAnchor.constraint(greaterThanOrEqualTo: requestControlButton.trailingAnchor, constant: MobileDesign.Spacing.tight),
            controlMenuButton.leadingAnchor.constraint(greaterThanOrEqualTo: controlLabel.trailingAnchor, constant: MobileDesign.Spacing.tight),
            controlMenuButton.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -MobileDesign.Spacing.medium),
            controlMenuButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            controlMenuButton.widthAnchor.constraint(equalToConstant: MobileDesign.Size.minimumTapTarget),
            controlMenuButton.heightAnchor.constraint(equalToConstant: MobileDesign.Size.minimumTapTarget),
        ])
        controlBar.isHidden = true
    }

    private func configureComposer() {
        composerShell.translatesAutoresizingMaskIntoConstraints = false
        composerPanel.translatesAutoresizingMaskIntoConstraints = false
        composerStack.translatesAutoresizingMaskIntoConstraints = false
        composerStack.axis = .horizontal
        // Multiline prompts grow down from a stable top row. Bottom alignment made both action
        // buttons appear to fall away from the first line and produced a different silhouette at
        // every prompt length.
        composerStack.alignment = .top
        composerStack.spacing = MobileDesign.Spacing.small
        composerShell.addSubview(composerPanel)
        composerPanel.layer.cornerCurve = .continuous
        composerPanel.clipsToBounds = true
        composerOutline.translatesAutoresizingMaskIntoConstraints = false
        composerPanel.addSubview(composerOutline)

        configureCircleButton(
            capabilityButton,
            symbol: "plus",
            accessibilityLabel: MobileL10n.string("Browse commands and skills")
        )
        configureCircleButton(
            attachButton,
            symbol: "paperclip",
            accessibilityLabel: MobileL10n.string("Attach a photo or file")
        )
        configureCircleButton(
            attentionButton,
            title: "@",
            accessibilityLabel: MobileL10n.string("Ask a person for input")
        )
        attentionButton.accessibilityHint = MobileL10n.string("Sends a human-only notification")
        configureCircleButton(
            sendButton,
            symbol: "arrow.up",
            accessibilityLabel: MobileL10n.string("Send feedback")
        )

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = false
        textView.returnKeyType = .send
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = MobileL10n.string("Add feedback…")
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.lineBreakMode = .byTruncatingTail
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 9),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: textView.widthAnchor, constant: -18),
        ])

        [capabilityButton, attachButton, attentionButton, textView, sendButton]
            .forEach(composerStack.addArrangedSubview)

        // The panel now holds a column: staged files above, controls below. The strip hides
        // itself when nothing is attached, so a composer with an empty tray keeps exactly the
        // silhouette it had before attachments existed.
        composerContentStack.translatesAutoresizingMaskIntoConstraints = false
        composerContentStack.axis = .vertical
        composerContentStack.alignment = .fill
        composerContentStack.spacing = MobileDesign.Spacing.tight
        composerContentStack.addArrangedSubview(attachmentStrip)
        composerContentStack.addArrangedSubview(composerStack)
        attachmentStrip.isHidden = true
        composerPanel.addSubview(composerContentStack)
        composerLeadingConstraint = composerPanel.leadingAnchor.constraint(
            equalTo: composerShell.leadingAnchor,
            constant: MobileDesign.Spacing.small
        )
        composerTrailingConstraint = composerPanel.trailingAnchor.constraint(
            equalTo: composerShell.trailingAnchor,
            constant: -MobileDesign.Spacing.small
        )
        composerBottomConstraint = composerPanel.bottomAnchor.constraint(
            equalTo: composerShell.bottomAnchor,
            constant: -MobileDesign.Spacing.small
        )
        composerPanelSafeBottomConstraint = composerPanel.bottomAnchor.constraint(
            equalTo: composerShell.safeAreaLayoutGuide.bottomAnchor,
            constant: -MobileDesign.Spacing.small
        )
        composerStackSafeBottomConstraint = composerContentStack.bottomAnchor.constraint(
            equalTo: composerShell.safeAreaLayoutGuide.bottomAnchor,
            constant: -MobileDesign.Spacing.small
        )
        composerStackSafeBottomConstraint.priority = .defaultHigh
        composerStackPanelBottomConstraint = composerContentStack.bottomAnchor.constraint(
            equalTo: composerPanel.bottomAnchor,
            constant: -MobileDesign.Spacing.composerVertical
        )
        composerTopConstraint = composerPanel.topAnchor.constraint(
            equalTo: composerShell.topAnchor,
            constant: MobileDesign.Spacing.small
        )
        NSLayoutConstraint.activate([
            composerLeadingConstraint,
            composerTrailingConstraint,
            composerTopConstraint,
            composerBottomConstraint,
            composerContentStack.leadingAnchor.constraint(
                equalTo: composerPanel.leadingAnchor,
                constant: MobileDesign.Spacing.composerHorizontal
            ),
            composerContentStack.trailingAnchor.constraint(
                equalTo: composerPanel.trailingAnchor,
                constant: -MobileDesign.Spacing.composerHorizontal
            ),
            composerContentStack.topAnchor.constraint(
                equalTo: composerPanel.topAnchor,
                constant: MobileDesign.Spacing.composerVertical
            ),
            composerStackSafeBottomConstraint,
            composerContentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: composerPanel.bottomAnchor,
                constant: -MobileDesign.Spacing.composerVertical
            ),
            composerOutline.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor),
            composerOutline.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor),
            composerOutline.topAnchor.constraint(equalTo: composerPanel.topAnchor),
            composerOutline.bottomAnchor.constraint(equalTo: composerPanel.bottomAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget),
        ])
    }

    private func configureCircleButton(
        _ button: UIButton,
        symbol: String? = nil,
        title: String? = nil,
        accessibilityLabel: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        if let symbol {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            // A symbol stays inside its fixed tap target at accessibility text sizes.
            button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(
                pointSize: MobileDesign.Size.minimumTapTarget - 2 * MobileDesign.Spacing.medium,
                weight: .semibold
            ), forImageIn: .normal)
        }
        if let title {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        }
        button.accessibilityLabel = accessibilityLabel
        button.layer.cornerRadius = MobileDesign.Size.minimumTapTarget / 2
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MobileDesign.Size.minimumTapTarget),
            button.heightAnchor.constraint(equalToConstant: MobileDesign.Size.minimumTapTarget),
        ])
    }

    private func configureActions() {
        [
            capabilityButton,
            attachButton,
            attentionButton,
            sendButton,
            requestControlButton,
        ].forEach { MobileButtonHaptics.install(on: $0) }
        MobileButtonHaptics.install(
            on: controlMenuButton,
            activationEvent: .menuActionTriggered
        )

        capabilityButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            capabilityKindFilter = nil
            preservedSkillArguments = nil
            showsCapabilityCatalog.toggle()
            updateCapabilities()
        }, for: .touchUpInside)
        attachButton.addAction(UIAction { [weak self] _ in
            self?.presentAttachmentSources()
        }, for: .touchUpInside)
        textView.offersFiles = { ComposerClipboard.general.hasFiles }
        textView.pasteFiles = { [weak self] in self?.stageClipboardFiles() ?? false }
        attachmentStrip.onRemove = { [weak self] id in
            self?.attachmentTray?.remove(id)
        }
        attachmentStrip.onPreview = { [weak self] item in
            self?.presentAttachmentPreview(item)
        }
        attentionButton.addAction(UIAction { [weak self] _ in
            self?.presentAttentionRequest()
        }, for: .touchUpInside)
        sendButton.addAction(UIAction { [weak self] _ in
            self?.submitDraft()
        }, for: .touchUpInside)
        requestControlButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            _ = connection.changeInputControl(action: .request)
        }, for: .touchUpInside)
    }

    private func observeState() {
        connection.objectWillChange.sink { [weak self] _ in
            self?.scheduleRender()
        }.store(in: &observations)
        notifications.objectWillChange.sink { [weak self] _ in
            self?.scheduleRender()
        }.store(in: &observations)
        model.objectWillChange.sink { [weak self] _ in
            self?.scheduleRender()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .sink { [weak self] notification in
                self?.updateKeyboard(from: notification)
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] notification in
                self?.updateKeyboard(from: notification, hiding: true)
            }
            .store(in: &observations)
    }

    private func updateKeyboard(from notification: Notification, hiding: Bool = false) {
        let overlap: CGFloat
        if hiding {
            overlap = 0
        } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect {
            let frameInView = view.convert(frame, from: nil)
            overlap = max(0, view.bounds.maxY - frameInView.minY)
        } else {
            overlap = 0
        }
        keyboardIsVisible = overlap > 0
        bottomConstraint.constant = -overlap
        updateComposerGeometry()
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double ?? 0
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.view.layoutIfNeeded()
        }
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.renderState()
        }
    }

    private func renderState() {
        theme = connection.theme.map(RemoteThemePalette.init) ?? inheritedTheme
        timelineController.updateTheme(theme)
        applyTheme()
        updateNavigationTitle()
        updatePresence()
        updateInputControl()
        updateAttentionActivity()
        updateSubmission()
        updateComposer()
        updateCapabilities()
    }

    private func applyTheme() {
        overrideUserInterfaceStyle = theme.colorScheme == .light ? .light : .dark
        view.backgroundColor = theme.uiGround
        bottomStack.backgroundColor = theme.uiGround
        capabilityContainer.backgroundColor = theme.uiGround
        capabilityScrollView.backgroundColor = theme.uiElevated
        capabilityScrollView.layer.cornerRadius = theme.panelRadius
        capabilityOutline.update(
            color: theme.uiBorder,
            radius: theme.panelRadius,
            width: theme.borderWidth,
            glow: theme.glow
        )
        presenceLabel.backgroundColor = theme.uiSurface
        presenceLabel.textColor = theme.uiSecondaryLabel
        controlBar.backgroundColor = theme.uiSurface
        controlLabel.textColor = theme.uiSecondaryLabel
        controlMenuButton.tintColor = theme.uiAccent
        requestControlButton.tintColor = theme.uiAccent
        attentionLabel.backgroundColor = theme.uiAccentMuted
        attentionLabel.textColor = theme.uiLabel
        submissionLabel.backgroundColor = theme.uiSurface
        composerShell.backgroundColor = theme.uiGround
        composerPanel.backgroundColor = theme.uiPanel
        updateComposerGeometry()
        composerOutline.update(
            color: theme.uiBorder,
            radius: keyboardIsVisible ? 0 : theme.panelRadius,
            width: theme.borderWidth,
            glow: theme.glow
        )
        textView.textColor = theme.uiLabel
        textView.tintColor = theme.uiAccent
        placeholderLabel.textColor = theme.uiTertiaryLabel
        capabilityButton.backgroundColor = theme.uiControlResting
        capabilityButton.tintColor = theme.uiLabel
        attachButton.backgroundColor = theme.uiControlResting
        attachButton.tintColor = theme.uiLabel
        attentionButton.backgroundColor = theme.uiControlResting
        attentionButton.tintColor = theme.uiLabel
        let controlRadius = min(
            MobileDesign.Size.minimumTapTarget / 2,
            max(theme.controlRadius, theme.panelRadius - MobileDesign.Spacing.small)
        )
        [capabilityButton, attachButton, attentionButton, sendButton].forEach {
            $0.layer.cornerRadius = controlRadius
            $0.layer.cornerCurve = .continuous
        }
        navigationTitleView.applyTheme(theme)
    }

    /// Keeps the composer attached to whichever physical edge currently owns text input.
    /// The keyboard is already outside the app's authored chrome, so retaining a decorative
    /// exterior gutter there exposed a strip of the conversation behind the field.
    private func updateComposerGeometry() {
        let fillsBottomEdge = theme.panelRadius <= MobileDesign.Spacing.tight
        let joinsKeyboard = keyboardIsVisible
        let exteriorInset = fillsBottomEdge || joinsKeyboard
            ? 0
            : MobileDesign.Spacing.small
        composerLeadingConstraint.constant = exteriorInset
        composerTrailingConstraint.constant = -exteriorInset
        composerTopConstraint.constant = joinsKeyboard ? 0 : exteriorInset
        composerPanel.layer.cornerRadius = joinsKeyboard ? 0 : theme.panelRadius
        if joinsKeyboard {
            composerPanelSafeBottomConstraint.isActive = false
            composerStackSafeBottomConstraint.isActive = false
            composerBottomConstraint.constant = 0
            composerBottomConstraint.isActive = true
            composerStackPanelBottomConstraint.isActive = true
        } else if fillsBottomEdge {
            composerPanelSafeBottomConstraint.isActive = false
            composerStackPanelBottomConstraint.isActive = false
            composerBottomConstraint.constant = 0
            composerBottomConstraint.isActive = true
            composerStackSafeBottomConstraint.isActive = true
        } else {
            composerBottomConstraint.isActive = false
            composerStackSafeBottomConstraint.isActive = false
            composerPanelSafeBottomConstraint.isActive = true
            composerStackPanelBottomConstraint.isActive = true
        }
    }

    private func installNavigationTitle() {
        navigationController?.topViewController?.navigationItem.titleView = navigationTitleView
        updateNavigationTitle()
    }

    private func updateNavigationTitle() {
        navigationTitleView.update(
            title: MobileSessionChrome.navigationTitle(
                for: connection.session,
                in: model.me,
                liveTitle: connection.mirroredCaption
            ),
            status: connectionStatusLabel,
            statusColor: connectionStatusColor,
            isWorking: connection.isAgentWorking,
            recovery: connection.phase.failure.map { failure in
                (failure.recoveryTitle, { [weak self] in self?.recover(from: failure) })
            }
        )
    }

    private func recover(from failure: RemoteConnectionFailure) {
        switch failure.recovery {
        case .reconnect:
            connection.retryNow()
        case .pairAgain:
            model.isPairing = true
        case .openLocalNetworkSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .openUpdatePage(let url):
            UIApplication.shared.open(url)
        }
    }

    private var connectionStatusLabel: String {
        switch connection.phase {
        case .connecting:
            return MobileSessionChrome.diallingStatus(
                hasEverConnected: connection.hasEverConnected,
                routeWalk: model.routeWalkStatus
            )
        case .connected:
            if connection.conversationStore.state.permission != nil { return MobileL10n.string("Waiting for permission") }
            if connection.isAwaitingUserDecision { return MobileL10n.string("Waiting for your answer") }
            return model.activeHost?.name ?? MobileL10n.string("Connected")
        case .ended(let reason): return reason
        case .failed(let failure): return failure.message
        }
    }

    private var connectionStatusColor: UIColor {
        switch connection.phase {
        case .connected: return connection.isAwaitingUserDecision ? theme.uiWarning : theme.uiPositive
        case .connecting: return theme.uiWarning
        case .ended, .failed: return theme.uiTertiaryLabel
        }
    }

    private func updatePresence() {
        let people = Array(connection.presence.values)
        let typingNames = uniqueNames(people.filter { $0.state == .typing })
        let viewingNames = uniqueNames(people)
        let text: String?
        if notifications.typingIndicatorsEnabled, !typingNames.isEmpty {
            text = presenceText(names: typingNames, action: .typing)
        } else if notifications.peoplePresenceEnabled, !viewingNames.isEmpty {
            text = presenceText(names: viewingNames, action: .viewing)
        } else {
            text = nil
        }
        presenceLabel.text = text
        presenceLabel.isHidden = text == nil
    }

    private func updateInputControl() {
        guard connection.shouldPresentInputControl, let state = connection.inputControl else {
            controlBar.isHidden = true
            return
        }
        controlBar.isHidden = false
        controlIcon.image = UIImage(
            systemName: state.mode == .collaborative ? "person.2" : "hand.raised"
        )
        controlIcon.tintColor = state.canWrite ? theme.uiPositive : theme.uiWarning
        controlLabel.text = inputControlStatus(state)
        requestControlButton.isHidden = !(
            state.mode == .focused && !state.canWrite && !state.canManage
        )
        let actions = inputControlActions(state)
        controlMenuButton.isHidden = actions.isEmpty
        controlMenuButton.menu = actions.isEmpty ? nil : UIMenu(children: actions)
    }

    private func inputControlActions(_ state: RemoteInputControlStateDTO) -> [UIAction] {
        var actions: [UIAction] = []
        if state.canManage, state.mode != .collaborative {
            actions.append(controlAction(title: MobileL10n.string("Collaborative"), action: .collaborative))
        }
        if state.canManage, !state.canWrite {
            actions.append(controlAction(title: MobileL10n.string("Reclaim control"), action: .reclaim))
        }
        if state.mode == .collaborative, state.canManage {
            actions.append(controlAction(
                title: MobileL10n.string("Focus on me"),
                action: .focused,
                targetID: state.currentParticipantID
            ))
        }
        if state.mode == .focused {
            for participant in state.participants where participant.id != state.controllerID {
                actions.append(controlAction(
                    title: MobileL10n.string("Hand off to %@", participant.displayName),
                    action: .handoff,
                    targetID: participant.id
                ))
            }
        }
        return actions
    }

    private func controlAction(
        title: String,
        action: RemoteInputControlAction,
        targetID: String? = nil
    ) -> UIAction {
        UIAction(title: title) { [weak self] _ in
            guard let self else { return }
            _ = connection.changeInputControl(action: action, targetID: targetID)
        }
    }

    private func updateAttentionActivity() {
        guard let event = connection.attentionEvents.last else {
            attentionLabel.isHidden = true
            return
        }
        var text = MobileL10n.string(
            "%@ asked %@ for input",
            event.senderDisplayName,
            event.recipientDisplayName
        )
        if let note = event.note, !note.isEmpty { text += "\n" + note }
        attentionLabel.text = text
        attentionLabel.isHidden = false
    }

    private func updateSubmission() {
        if connection.promptSubmissionFeedback != lastSubmissionFeedback {
            lastSubmissionFeedback = connection.promptSubmissionFeedback
            handleSubmissionFeedback(connection.promptSubmissionFeedback)
        }
        if connection.isPromptSubmissionPending, pendingSubmissionID != nil {
            submissionLabel.text = MobileL10n.string("Sending once…")
            submissionLabel.textColor = theme.uiSecondaryLabel
            submissionLabel.isHidden = false
        } else if let submissionNotice {
            submissionLabel.text = submissionNotice
            submissionLabel.textColor = theme.uiWarning
            submissionLabel.isHidden = false
        } else if let attachmentNotice = attachmentTray?.notice {
            // Attachment refusals share the composer's one notice line: two places to look for
            // "why didn't that work" is one more than anybody checks.
            submissionLabel.text = attachmentNotice
            submissionLabel.textColor = theme.uiWarning
            submissionLabel.isHidden = false
        } else {
            submissionLabel.isHidden = true
        }
    }

    private func updateComposer() {
        let enabled = connection.phase == .connected
            && connection.capability == .interact
            && connection.inputControl?.canWrite != false
            && connection.conversationCanSend
            && !connection.isPromptSubmissionPending
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        textView.setEditableIfNeeded(enabled)
        capabilityButton.isEnabled = connection.capability == .interact
            && !connection.composerCapabilities.isEmpty
        // Hidden rather than disabled when the host does not offer uploads: a guest or view-only
        // connection is never told the feature exists, so a dimmed paperclip would be advertising
        // something this link can never do.
        attachButton.isHidden = !(connection.supportsComposerAttachmentUploads
            && configureAttachmentTray())
        attachButton.isEnabled = enabled && attachmentTray?.canAcceptMore == true
        attentionButton.isHidden = !(
            connection.phase == .connected
                && connection.capability == .interact
                && connection.supportsAttentionRequests
                && !connection.attentionRecipients.isEmpty
        )
        // A picture on its own is a message. Send stays held while one is still travelling,
        // because a prompt naming an upload the Mac has not finished receiving is refused —
        // better to wait a moment than to reject something the person already pressed send on.
        let tray = attachmentTray
        let hasAttachments = tray?.readyUploadIDs.isEmpty == false
        sendButton.isEnabled = enabled
            && attachmentPicksInFlight == 0
            && (hasText || hasAttachments)
            && tray?.isSettling != true
        sendButton.backgroundColor = sendButton.isEnabled ? theme.uiAccent : theme.uiControlResting
        sendButton.tintColor = sendButton.isEnabled ? theme.uiAccentForeground : theme.uiSecondaryLabel
        placeholderLabel.isHidden = !textView.text.isEmpty
        attachmentStrip.update(
            items: tray?.items ?? [],
            theme: theme,
            isRemovalEnabled: enabled
        )
    }

    private func updateCapabilities() {
        let items = completionItems
        guard items != lastCapabilities || capabilityContainer.isHidden != items.isEmpty else { return }
        lastCapabilities = items
        capabilityStack.arrangedSubviews.forEach {
            capabilityStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in items {
            var configuration = UIButton.Configuration.plain()
            configuration.title = item.invocationText
            configuration.subtitle = [item.displayName, item.presentationDetail]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            configuration.titleAlignment = .leading
            configuration.baseForegroundColor = theme.uiLabel
            configuration.contentInsets = .init(
                top: MobileDesign.Spacing.small,
                leading: MobileDesign.Spacing.medium,
                bottom: MobileDesign.Spacing.small,
                trailing: MobileDesign.Spacing.medium
            )
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.chooseCapability(item)
            })
            MobileButtonHaptics.install(on: button)
            button.contentHorizontalAlignment = .leading
            button.backgroundColor = theme.uiElevated
            button.isEnabled = item.isEnabled
            button.alpha = item.isEnabled ? 1 : 0.55
            button.accessibilityLabel = [item.invocationText, item.displayName, item.presentationDetail]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            capabilityStack.addArrangedSubview(button)
        }
        capabilityContainer.isHidden = items.isEmpty
        capabilityHeightConstraint.constant = items.isEmpty
            ? 0
            : min(CGFloat(items.count) * 64 + MobileDesign.Spacing.small, 260)
    }

    private var completionItems: [RemoteComposerCapabilityDTO] {
        let items: [RemoteComposerCapabilityDTO]
        if let query = RemoteComposerCompletionQuery.parse(textView.text) {
            items = query.suggestions(
                from: connection.composerCapabilities,
                matchingKind: capabilityKindFilter
            )
        } else if showsCapabilityCatalog {
            items = connection.composerCapabilities.sorted {
                if $0.kind != $1.kind { return $0.kind == .command }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        } else {
            return []
        }
        guard let capabilityKindFilter else { return items }
        return capabilityKindFilter == .skill
            ? items.filter(\.canBrowseAsSkill)
            : items.filter { $0.kind == capabilityKindFilter }
    }

    private func chooseCapability(_ capability: RemoteComposerCapabilityDTO) {
        guard capability.isEnabled else { return }
        if capability.id == RemoteComposerCatalog.skillsCommandID {
            let existing = RemoteComposerCompletionQuery.parse(textView.text) == nil
                ? textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            openSkillCatalog(preserving: existing.isEmpty ? nil : existing)
            return
        }
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = preservedSkillArguments ?? (
            RemoteComposerCompletionQuery.parse(textView.text) == nil ? trimmed : ""
        )
        textView.text = capability.invocationText + (arguments.isEmpty ? " " : " " + arguments)
        showsCapabilityCatalog = false
        capabilityKindFilter = nil
        preservedSkillArguments = nil
        textDidChange()
    }

    private func submitDraft() {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("/skills") == .orderedSame,
           connection.composerCapabilities.contains(where: {
               $0.id == RemoteComposerCatalog.skillsCommandID
           }) {
            openSkillCatalog(preserving: nil)
            return
        }
        if let requestID = connection.submit(
            textView.text,
            attachmentUploadIDs: attachmentTray?.readyUploadIDs ?? []
        ) {
            pendingSubmissionID = requestID
            showsCapabilityCatalog = false
            capabilityKindFilter = nil
            preservedSkillArguments = nil
            updateCapabilities()
            updateSubmission()
        }
    }

    // MARK: - Attachments

    /// Builds the tray the first time a client exists, and answers whether there is one.
    ///
    /// Called from `updateComposer` rather than only from `viewDidLoad`, because the app model
    /// may still be resolving a client when this controller is created. Doing it once at load
    /// would leave the paperclip permanently hidden on exactly the launch where a session was
    /// restored before pairing finished.
    @discardableResult
    private func configureAttachmentTray() -> Bool {
        if attachmentTray != nil { return true }
        guard let client = model.client else { return false }
        let tray = ComposerAttachmentTray(
            client: client,
            uploadScopeID: connection.session.id
        )
        tray.onChange = { [weak self] in
            guard let self else { return }
            updateComposer()
            updateSubmission()
        }
        attachmentTray = tray
        return true
    }

    private func presentAttachmentPreview(_ item: ComposerAttachmentItem) {
        guard presentedViewController == nil else { return }
        let controller = UIHostingController(rootView:
            ComposerAttachmentQuickView(item: item).mobileTheme(theme)
        )
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    /// Offers the two places a file can come from on a phone.
    ///
    /// Photos and files are deliberately separate entries rather than one combined picker: the
    /// photo library needs `PHPickerViewController` to stay out of the user's whole library
    /// (nothing is granted, and the app never asks for photo permission), while a document needs
    /// the security-scoped file picker. One sheet offering both is the honest shape.
    private func presentAttachmentSources() {
        guard let tray = attachmentTray, tray.canAcceptMore else { return }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        // Read once, here, where somebody has just asked to attach something: the answer decides
        // whether the entry is drawn at all, and asking on every layout pass would be an XPC
        // round trip to the pasteboard server for a menu nobody opened.
        if ComposerClipboard.general.hasFiles {
            sheet.addAction(UIAlertAction(
                title: MobileL10n.string("From Clipboard"),
                style: .default
            ) { [weak self] _ in _ = self?.stageClipboardFiles() })
        }
        sheet.addAction(UIAlertAction(
            title: MobileL10n.string("Photo Library"),
            style: .default
        ) { [weak self] _ in self?.presentPhotoPicker() })
        sheet.addAction(UIAlertAction(
            title: MobileL10n.string("Files"),
            style: .default
        ) { [weak self] _ in self?.presentDocumentPicker() })
        sheet.addAction(UIAlertAction(title: MobileL10n.string("Cancel"), style: .cancel))
        // An action sheet with no anchor is a crash on iPad, not a layout compromise.
        sheet.popoverPresentationController?.sourceView = attachButton
        sheet.popoverPresentationController?.sourceRect = attachButton.bounds
        sheet.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        sheet.view.tintColor = theme.uiAccent
        present(sheet, animated: true)
    }

    /// Stages whatever the clipboard is holding as files, and says whether it held any.
    ///
    /// The same method serves the paste and the menu entry, because they are the same act: one
    /// is reached through the text view's edit menu and the other through the paperclip, and
    /// both mean "the thing I copied belongs in this message".
    @discardableResult
    private func stageClipboardFiles() -> Bool {
        guard configureAttachmentTray(), let tray = attachmentTray, tray.canAcceptMore else {
            return false
        }
        let files = ComposerClipboard.general.files()
        guard !files.isEmpty else { return false }
        for file in files {
            tray.add(data: file.data, name: file.name, type: file.type)
        }
        return true
    }

    private func presentPhotoPicker() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = remainingAttachmentSlots
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        picker.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        // The host takes what its attachments pane can show. Asking for exactly that set here
        // means an unsupported file is greyed out in the picker rather than refused after the
        // person chose it.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: ComposerAttachmentSources.documentTypes,
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = true
        picker.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        present(picker, animated: true)
    }

    private var remainingAttachmentSlots: Int {
        max(1, RemoteAttachmentUploadLimits.maximumPerMessage - (attachmentTray?.items.count ?? 0))
    }

    private func openSkillCatalog(preserving arguments: String?) {
        guard let skill = connection.composerCapabilities.first(where: \.canBrowseAsSkill)
        else { return }
        preservedSkillArguments = arguments
        textView.text = skill.trigger == .dollar ? "$" : "/"
        showsCapabilityCatalog = true
        capabilityKindFilter = .skill
        textDidChange()
    }

    private func handleSubmissionFeedback(_ feedback: RemotePromptSubmissionFeedback?) {
        guard let feedback, feedback.requestID == pendingSubmissionID else { return }
        pendingSubmissionID = nil
        if feedback.status == .accepted {
            if textView.text.trimmingCharacters(in: .whitespacesAndNewlines) == feedback.text {
                textView.text = ""
                textDidChange()
            }
            // Cleared on acceptance and never before: the Mac has claimed these uploads, so the
            // strip is now showing files that no longer exist anywhere the composer can reach.
            // A rejected prompt keeps them, which is what lets the person simply press send again.
            attachmentTray?.clear()
            submissionNotice = nil
            return
        }
        switch feedback.status {
        case .busy:
            submissionNotice = MobileL10n.string(
                "Another composer sent first. Your draft is still here."
            )
        case .rejected:
            submissionNotice = MobileL10n.string(
                "The Mac rejected this prompt. Your draft is still here."
            )
        case .unavailable:
            submissionNotice = MobileL10n.string(
                "The session changed before this prompt could be sent. Your draft is still here."
            )
        case .conflict:
            submissionNotice = MobileL10n.string(
                "This prompt could not be retried safely. Your draft is still here."
            )
        case .accepted:
            break
        }
    }

    private func presentAttentionRequest() {
        let root = AttentionRequestSheet(connection: connection)
            .mobileTheme(theme)
        let controller = UIHostingController(rootView: root)
        controller.modalPresentationStyle = .pageSheet
        present(controller, animated: true)
    }

    private func restoreDraft() {
        // Deterministic fixtures share a simulator data container across captures. They must not
        // inherit whichever draft an earlier fixture happened to persist, or a one-line layout
        // journey silently turns into a multiline one. Production still restores the real draft.
        if let fixtureDraft {
            applyRestoredDraft(fixtureDraft)
            return
        }
        guard let hostID = model.activeHostID else { return }
        let draft = continuity.draft(
            surface: .conversation,
            hostID: hostID,
            sessionID: connection.session.id
        )
        applyRestoredDraft(draft)
    }

    private func applyRestoredDraft(_ draft: String) {
        // Assigning even the same empty string makes UITextView coordinate a selection change
        // and cold-load dictation services. Most conversations have no saved draft, so keep that
        // framework out of first paint without delaying a real draft by one frame.
        // Compare visible values: UIKit imports this property as optional even though an unset
        // text view presents an empty string. There is no reason for nil and "" to cross the
        // expensive mutation boundary differently.
        if (textView.text ?? "") != draft {
#if DEBUG
            MobileConversationPerformanceProbe.restoredDraftWillAssign()
#endif
            textView.text = draft
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private var fixtureDraft: String? {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let mode = environment[MobileDemoScene.environmentKey]
        if mode == "conversation-cold-stress"
            || mode == "conversation-reconnect-stress"
            || mode == "conversation-scroll-stress" {
            return ""
        }
        guard environment["THREADING_MOBILE_UI_EVIDENCE_ID"] != nil else { return nil }
        switch mode {
        case "conversation", "conversation-collaboration":
            return MobileL10n.string("Check the final layout.")
        case "permission", "conversation-keyboard":
            return MobileL10n.string(
                "Check the final layout with the keyboard open and a longer prompt."
            )
        default:
            return nil
        }
#else
        return nil
#endif
    }

    private func textDidChange() {
        submissionNotice = nil
        connection.reportTyping(!textView.text.isEmpty)
        if let hostID = model.activeHostID {
            continuity.setDraft(
                textView.text,
                surface: .conversation,
                hostID: hostID,
                sessionID: connection.session.id
            )
        }
        if RemoteComposerCompletionQuery.parse(textView.text) == nil, !textView.text.isEmpty {
            showsCapabilityCatalog = false
            capabilityKindFilter = nil
            preservedSkillArguments = nil
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
        textView.invalidateIntrinsicContentSize()
        updateComposer()
        updateCapabilities()
    }

    func textViewDidChange(_ textView: UITextView) {
        textDidChange()
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text == "\n" {
            submitDraft()
            return false
        }
        return true
    }

    private var initiallyFocusesComposer: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey] == "conversation-keyboard"
#else
        false
#endif
    }

    private func uniqueNames(_ people: [RemotePresenceDTO]) -> [String] {
        Array(Set(people.map(presenceDisplayName))).sorted()
    }

    private func presenceDisplayName(_ presence: RemotePresenceDTO) -> String {
        guard let deviceName = presence.deviceName,
              !deviceName.isEmpty,
              deviceName != presence.displayName else { return presence.displayName }
        return MobileL10n.string("%@ on %@", presence.displayName, deviceName)
    }

    private func presenceText(names: [String], action: RemotePresenceState) -> String {
        if names.count == 1 {
            return action == .typing
                ? MobileL10n.string("%@ is typing…", names[0])
                : MobileL10n.string("%@ is here", names[0])
        }
        if names.count == 2 {
            let joined = names.joined(separator: MobileL10n.string(" and "))
            return action == .typing
                ? MobileL10n.string("%@ are typing…", joined)
                : MobileL10n.string("%@ are here", joined)
        }
        return action == .typing
            ? MobileL10n.string("%lld people are typing…", Int64(names.count))
            : MobileL10n.string("%lld people are here", Int64(names.count))
    }

    private func inputControlStatus(_ state: RemoteInputControlStateDTO) -> String {
        if state.mode == .collaborative {
            return MobileL10n.string("Collaborative · everyone can send")
        }
        if state.canWrite {
            return MobileL10n.string("You are controlling · others are watching")
        }
        return MobileL10n.string(
            "%@ is controlling · your draft stays here",
            state.controllerDisplayName ?? MobileL10n.string("Another participant")
        )
    }
}

/// One stable TextKit shape for a line that shares its row with fixed controls. Exclusion paths
/// describe occupied area, but they do not describe the one jump this layout needs: after one
/// narrowed line, the next line starts below the controls and regains the whole width.
private final class FirstLineAccessoryTextContainer: NSTextContainer {
    var firstLineLeftInset: CGFloat = 0
    var firstLineRightInset: CGFloat = 0
    var nextLineMinimumY: CGFloat = 0

    override func lineFragmentRect(
        forProposedRect proposedRect: CGRect,
        at characterIndex: Int,
        writingDirection baseWritingDirection: NSWritingDirection,
        remaining remainingRect: UnsafeMutablePointer<CGRect>?
    ) -> CGRect {
        guard nextLineMinimumY > 0,
              firstLineLeftInset > 0 || firstLineRightInset > 0 else {
            return super.lineFragmentRect(
                forProposedRect: proposedRect,
                at: characterIndex,
                writingDirection: baseWritingDirection,
                remaining: remainingRect
            )
        }

        if proposedRect.minY < 0.5 {
            var firstLine = super.lineFragmentRect(
                forProposedRect: proposedRect,
                at: characterIndex,
                writingDirection: baseWritingDirection,
                remaining: remainingRect
            )
            firstLine.origin.x += firstLineLeftInset
            firstLine.size.width = max(
                0,
                firstLine.width - firstLineLeftInset - firstLineRightInset
            )
            // The space beside the centre fragment belongs to controls, not to another text
            // fragment on the same typographic line.
            remainingRect?.pointee = .zero
            return firstLine
        }

        if proposedRect.minY < nextLineMinimumY {
            var fullWidthLine = proposedRect
            fullWidthLine.origin.y = nextLineMinimumY
            return super.lineFragmentRect(
                forProposedRect: fullWidthLine,
                at: characterIndex,
                writingDirection: baseWritingDirection,
                remaining: remainingRect
            )
        }

        return super.lineFragmentRect(
            forProposedRect: proposedRect,
            at: characterIndex,
            writingDirection: baseWritingDirection,
            remaining: remainingRect
        )
    }
}

/// The composer's own text view: it measures itself, and it knows that a paste is not always
/// text. The clipboard itself is deliberately not reachable from here — the composer that owns
/// the attachment tray answers both questions — so this stays a view with no opinion about
/// where a file goes.
class IntrinsicTextView: UITextView, @MainActor NSLayoutManagerDelegate {
    /// Whether the clipboard is holding something only the attachment strip could take.
    var offersFiles: () -> Bool = { false }
    /// Takes such a paste, and answers whether it did.
    var pasteFiles: () -> Bool = { false }
    /// Reports whether the document has outgrown the first-line accessory footprints: laid out
    /// with them in place, it would exceed the viewport cap. The new-session shell uses it to
    /// move its fixed controls out of the viewport once they can no longer stay attached to the
    /// document's first line. The answer is always measured against those footprints — never
    /// against whichever placement is currently applied — because the placement is this report's
    /// consequence: deciding from the applied geometry moved the controls out, refitted the
    /// document to its regained width, brought them back, and flickered forever at any prompt
    /// within a line of the cap.
    var onFirstLineAccessoryOverflowChange: ((Bool) -> Void)? {
        didSet {
            // UIKit can lay the view out while its representable is still configuring TextKit.
            // Replay the standing answer when the shell installs its observer afterward.
            if let reportedAccessoryOverflow {
                onFirstLineAccessoryOverflowChange?(reportedAccessoryOverflow)
            } else {
                setNeedsLayout()
            }
        }
    }

    /// The reply composer uses a full tap target; the compact pre-session draft shares its
    /// first line with Start. Both still use this same native editor and paste contract.
    var minimumIntrinsicHeight = MobileDesign.Size.minimumTapTarget {
        didSet { invalidateIntrinsicContentSize() }
    }
    var maximumIntrinsicHeight: CGFloat = 132 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// Space occupied by controls floating over the first text line. Later lines deliberately
    /// receive the whole text container: a multiline composer should wrap underneath its
    /// paperclip and send controls instead of inheriting two empty columns for its full height.
    var firstLineLeadingAccessoryWidth: CGFloat = 0 {
        didSet {
            guard firstLineLeadingAccessoryWidth != oldValue else { return }
            firstLineAccessoryLayoutChanged()
        }
    }
    var firstLineTrailingAccessoryWidth: CGFloat = 0 {
        didSet {
            guard firstLineTrailingAccessoryWidth != oldValue else { return }
            firstLineAccessoryLayoutChanged()
        }
    }
    var firstLineAccessoryHeight: CGFloat = 0 {
        didSet {
            guard firstLineAccessoryHeight != oldValue else { return }
            firstLineAccessoryLayoutChanged()
        }
    }
    /// Whether those footprints are currently stationed over the first line. The draft shell
    /// answers an overflow report by moving its controls into a fixed row; the footprints stay
    /// stated so the overflow decision keeps its one geometry, and this flag alone releases the
    /// first line's width to the document.
    var firstLineAccessoriesInline = true {
        didSet {
            guard firstLineAccessoriesInline != oldValue else { return }
            firstLineAccessoryLayoutChanged()
        }
    }
    /// A compact editor may opt into a shorter insertion mark than UIKit's full typographic line
    /// box. Nil preserves the native caret everywhere else that shares this text view.
    var preferredCaretHeight: CGFloat?

    /// Changes the input contract only when its availability actually changed.
    ///
    /// `textViewDidChange` refreshes the chat composer after every edit. Reapplying `isEditable`
    /// from the first Backspace callback interrupts UIKit's held-key transaction, so the system
    /// keyboard deletes once instead of continuing its native repeat. UIKit still owns deletion,
    /// marked text and composed characters; this method only keeps an unchanged editing session
    /// untouched.
    @discardableResult
    func setEditableIfNeeded(_ editable: Bool) -> Bool {
        guard isEditable != editable else { return false }
        isEditable = editable
        return true
    }

    private var measuredWidth: CGFloat = 0
    private var appliedFirstLineAccessoryLayout: [CGFloat] = []
    private var reportedAccessoryOverflow: Bool?
    private var inlineOverflowAnswer: (key: InlineOverflowKey, overflows: Bool)?
    private let inlineOverflowMeasurement = InlineAccessoryOverflowMeasurement()

    /// Offers Paste for a clipboard holding only files.
    ///
    /// `UITextView` asks whether it can insert *text*, so a picture-only clipboard left the edit
    /// menu with no Paste in it at all — and a picture copied out of a web page or a message is
    /// in neither of the composer's other two doors until somebody saves it somewhere first.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), offersFiles() { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Takes a pasted picture or file as an attachment, and leaves text alone.
    ///
    /// Text keeps the text view's own paste — insertion point, undo, smart substitution and all.
    /// This runs inside the system's own paste command, which is also what keeps the read of the
    /// pasteboard exempt from the "allow paste" prompt.
    override func paste(_ sender: Any?) {
        if pasteFiles() { return }
        super.paste(sender)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        guard let preferredCaretHeight,
              preferredCaretHeight > 0,
              preferredCaretHeight < rect.height else {
            return rect
        }
        rect.origin.y += (rect.height - preferredCaretHeight) / 2
        rect.size.height = preferredCaretHeight
        return rect
    }

    override var intrinsicContentSize: CGSize {
        // Auto Layout asks for an intrinsic height once before the horizontal stack has a width.
        // Measuring against one point at that stage makes even a short prompt look like a
        // six-line prompt. Start compact, then invalidate once layout supplies the real width.
        guard bounds.width > 0 else {
            return CGSize(
                width: UIView.noIntrinsicMetric,
                height: minimumIntrinsicHeight
            )
        }
        let fittingWidth = bounds.width
        let height = sizeThatFits(CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)).height
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: min(max(height, minimumIntrinsicHeight), maximumIntrinsicHeight)
        )
    }

    override func layoutSubviews() {
        updateFirstLineAccessoryExclusions(for: bounds.width)
        super.layoutSubviews()
        if bounds.width > 0, abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        // Each UIKit measurement is authoritative in one mode only. Before scrolling starts,
        // `contentSize` is capped to the viewport and `sizeThatFits` exposes the full document.
        // Afterward that reverses: `contentSize` owns the scroll range while `sizeThatFits`
        // answers with the viewport. Switching the source with the mode prevents oscillation.
        let uncappedHeight = isScrollEnabled
            ? contentSize.height
            : sizeThatFits(CGSize(
                width: bounds.width,
                height: .greatestFiniteMagnitude
            )).height
        // This view supplies its own intrinsic height up to `maximumIntrinsicHeight`. During that
        // growth UIKit legitimately lays it out at several shorter intermediate heights. Those
        // are not scroll viewports: comparing against one made an empty new-session draft report
        // overflow and permanently move its actions into a separate row. Scrolling begins only
        // when the document exceeds the same authored cap used by intrinsic sizing.
        let shouldScroll = uncappedHeight > maximumIntrinsicHeight + 0.5
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
            if shouldScroll {
                layoutManager.ensureLayout(for: textContainer)
            }
        }
        // The accessory-placement report is a separate question from `isScrollEnabled`, on a
        // separate geometry: whether the document would exceed the cap with the accessory
        // footprints in place. Deciding it from `shouldScroll` tied it to the applied geometry
        // and oscillated; see `onFirstLineAccessoryOverflowChange`.
        if onFirstLineAccessoryOverflowChange != nil, bounds.width > 0 {
            let overflows = inlineAccessoryGeometryOverflows(viewWidth: bounds.width)
            if reportedAccessoryOverflow != overflows {
                reportedAccessoryOverflow = overflows
                onFirstLineAccessoryOverflowChange?(overflows)
            }
        }
    }

    /// `UIViewRepresentable.sizeThatFits` measures before the view necessarily owns its proposed
    /// bounds, so the bridge prepares the same first-line geometry against that proposed width.
    func updateFirstLineAccessoryExclusions(for viewWidth: CGFloat) {
        let containerWidth = max(
            0,
            viewWidth - textContainerInset.left - textContainerInset.right
        )
        let leadingWidth = min(
            max(0, firstLineAccessoriesInline ? firstLineLeadingAccessoryWidth : 0),
            containerWidth
        )
        let trailingWidth = min(
            max(0, firstLineAccessoriesInline ? firstLineTrailingAccessoryWidth : 0),
            max(0, containerWidth - leadingWidth)
        )
        let lineHeight = font?.lineHeight ?? 0
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        if let accessoryContainer = textContainer as? FirstLineAccessoryTextContainer {
            let leftWidth = isRightToLeft ? trailingWidth : leadingWidth
            let rightWidth = isRightToLeft ? leadingWidth : trailingWidth
            let nextLineMinimumY = max(
                lineHeight,
                firstLineAccessoryHeight - textContainerInset.top
            )
            let signature = [
                containerWidth,
                leftWidth,
                rightWidth,
                lineHeight,
                nextLineMinimumY,
            ]
            guard signature != appliedFirstLineAccessoryLayout else { return }
            appliedFirstLineAccessoryLayout = signature
            accessoryContainer.firstLineLeftInset = containerWidth > 0 ? leftWidth : 0
            accessoryContainer.firstLineRightInset = containerWidth > 0 ? rightWidth : 0
            accessoryContainer.nextLineMinimumY = lineHeight > 0 ? nextLineMinimumY : 0
            firstLineTextLayoutChanged()
            return
        }

        // The compact new-session editor keeps its established exclusion/delegate geometry.
        // Its controls can move into a separate row at the scrolling threshold; replacing its
        // TextKit stack during that SwiftUI transition feeds sizing back into the transition.
        let signature = [
            containerWidth,
            leadingWidth,
            trailingWidth,
            lineHeight,
            isRightToLeft ? 1 : 0,
        ]
        guard signature != appliedFirstLineAccessoryLayout else { return }
        appliedFirstLineAccessoryLayout = signature

        guard containerWidth > 0, lineHeight > 0,
              leadingWidth > 0 || trailingWidth > 0 else {
            textContainer.exclusionPaths = []
            return
        }

        textContainer.exclusionPaths = [
            leadingWidth > 0
                ? UIBezierPath(rect: CGRect(
                    x: isRightToLeft ? containerWidth - leadingWidth : 0,
                    y: 0,
                    width: leadingWidth,
                    height: lineHeight
                ))
                : nil,
            trailingWidth > 0
                ? UIBezierPath(rect: CGRect(
                    x: isRightToLeft ? 0 : containerWidth - trailingWidth,
                    y: 0,
                    width: trailingWidth,
                    height: lineHeight
                ))
                : nil,
        ].compactMap { $0 }
    }

    /// Everything the accessory-placement measurement reads. The applied placement is
    /// deliberately absent: the answer must be the same whichever placement is showing.
    private struct InlineOverflowKey: Equatable {
        let containerWidth: CGFloat
        let text: String
        let fontPointSize: CGFloat
        let leadingWidth: CGFloat
        let trailingWidth: CGFloat
        let accessoryHeight: CGFloat
        let insetTop: CGFloat
        let insetBottom: CGFloat
        let maximumHeight: CGFloat
        let isRightToLeft: Bool
    }

    /// Whether the document, laid out with the first-line accessory footprints in place, exceeds
    /// the editor's cap. This is the placement decision for those accessories, so it is measured
    /// on a spare TextKit stack that always wears the inline footprints — the live container is
    /// wearing whichever placement the last answer chose, and an answer read from there feeds on
    /// its own consequence. The spare stack mirrors the live inline geometry: the same container
    /// width and zero fragment padding, the same exclusion rects, and the same after-first-line
    /// clearance the layout-manager delegate applies.
    private func inlineAccessoryGeometryOverflows(viewWidth: CGFloat) -> Bool {
        guard let font else { return false }
        let insets = textContainerInset
        let containerWidth = max(0, viewWidth - insets.left - insets.right)
        let lineHeight = font.lineHeight
        guard containerWidth > 0, lineHeight > 0 else { return false }
        let key = InlineOverflowKey(
            containerWidth: containerWidth,
            text: text ?? "",
            fontPointSize: font.pointSize,
            leadingWidth: firstLineLeadingAccessoryWidth,
            trailingWidth: firstLineTrailingAccessoryWidth,
            accessoryHeight: firstLineAccessoryHeight,
            insetTop: insets.top,
            insetBottom: insets.bottom,
            maximumHeight: maximumIntrinsicHeight,
            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        if let inlineOverflowAnswer, inlineOverflowAnswer.key == key {
            return inlineOverflowAnswer.overflows
        }
        let overflows = measureInlineOverflow(key: key, font: font, lineHeight: lineHeight)
        inlineOverflowAnswer = (key, overflows)
        return overflows
    }

    /// Bound the scan, not just the result: a paste can be arbitrarily large, and the only
    /// question is whether the document exceeds a viewport a handful of lines tall. More hard
    /// breaks than the viewport has lines settles it without layout, and so does more text than
    /// the narrowest glyphs could fit in those lines — no positive-advance body glyph is
    /// narrower than two points — so only a bounded document ever reaches TextKit.
    private func measureInlineOverflow(
        key: InlineOverflowKey,
        font: UIFont,
        lineHeight: CGFloat
    ) -> Bool {
        let capacityLines = max(1, Int(ceil(key.maximumHeight / lineHeight)))
        let characterCapacity = Int(ceil(key.containerWidth / 2)) * (capacityLines + 1)
        if key.text.utf16.count > characterCapacity { return true }
        var hardBreaks = 0
        for unit in key.text.utf16 where unit == 0x0A {
            hardBreaks += 1
            if hardBreaks >= capacityLines { return true }
        }

        let leadingWidth = min(max(0, key.leadingWidth), key.containerWidth)
        let trailingWidth = min(
            max(0, key.trailingWidth),
            max(0, key.containerWidth - leadingWidth)
        )
        let leftWidth = key.isRightToLeft ? trailingWidth : leadingWidth
        let rightWidth = key.isRightToLeft ? leadingWidth : trailingWidth
        let measurement = inlineOverflowMeasurement
        measurement.container.size = CGSize(
            width: key.containerWidth,
            height: .greatestFiniteMagnitude
        )
        measurement.container.exclusionPaths = [
            leftWidth > 0
                ? UIBezierPath(rect: CGRect(x: 0, y: 0, width: leftWidth, height: lineHeight))
                : nil,
            rightWidth > 0
                ? UIBezierPath(rect: CGRect(
                    x: key.containerWidth - rightWidth,
                    y: 0,
                    width: rightWidth,
                    height: lineHeight
                ))
                : nil,
        ].compactMap { $0 }
        measurement.firstLineFloor = max(0, key.accessoryHeight - key.insetTop)
        measurement.storage.setAttributedString(
            NSAttributedString(string: key.text, attributes: [.font: font])
        )
        measurement.layoutManager.ensureLayout(for: measurement.container)
        let used = measurement.layoutManager.usedRect(for: measurement.container)
        let height = used.maxY + key.insetTop + key.insetBottom
        return height > key.maximumHeight + 0.5
    }

    /// The shared new-session composer still uses the layout-manager clearance paired with its
    /// ordinary text container. The terminal composer has a dedicated container instead, so its
    /// first line's height never depends on the clearance before line two.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        lineSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: CGRect
    ) -> CGFloat {
        guard !(textContainer is FirstLineAccessoryTextContainer),
              firstLineAccessoriesInline,
              firstLineAccessoryHeight > 0,
              rect.minY < 0.5,
              glyphIndex != NSNotFound,
              glyphIndex + 1 < layoutManager.numberOfGlyphs else {
            return 0
        }
        return max(
            0,
            firstLineAccessoryHeight - textContainerInset.top - rect.height
        )
    }

    private func firstLineAccessoryLayoutChanged() {
        appliedFirstLineAccessoryLayout = []
        if textContainer is FirstLineAccessoryTextContainer {
            if layoutManager.delegate === self {
                layoutManager.delegate = nil
            }
        } else if firstLineAccessoryHeight > 0, firstLineAccessoriesInline {
            layoutManager.delegate = self
        } else if layoutManager.delegate === self {
            layoutManager.delegate = nil
        }
        firstLineTextLayoutChanged()
    }

    private func firstLineTextLayoutChanged() {
        layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textStorage.length),
            actualCharacterRange: nil
        )
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }
}

/// The spare TextKit stack `IntrinsicTextView` measures its accessory-placement decision on:
/// an ordinary container wearing the inline exclusions, plus the same after-first-line
/// clearance the live layout-manager delegate applies while the accessories are inline.
@MainActor
private final class InlineAccessoryOverflowMeasurement: NSObject, @MainActor NSLayoutManagerDelegate {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: .zero)
    /// The line-two floor in text-container coordinates: the accessory height less the top
    /// inset, exactly as the live delegate computes its clearance.
    var firstLineFloor: CGFloat = 0

    override init() {
        super.init()
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.delegate = self
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        lineSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: CGRect
    ) -> CGFloat {
        guard firstLineFloor > 0,
              rect.minY < 0.5,
              glyphIndex != NSNotFound,
              glyphIndex + 1 < layoutManager.numberOfGlyphs else {
            return 0
        }
        return max(0, firstLineFloor - rect.height)
    }
}

/// Only the atomic terminal line needs the non-rectangular deterministic container. Keeping the
/// shared draft and conversation editors on UIKit's ordinary stack avoids making an unrelated
/// SwiftUI sizing transition depend on this terminal-only geometry.
final class TerminalLineTextView: IntrinsicTextView {
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let accessoryContainer = FirstLineAccessoryTextContainer(size: .zero)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(accessoryContainer)
        ownedTextStorage = textStorage
        ownedLayoutManager = layoutManager
        super.init(frame: frame, textContainer: accessoryContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class InsetsLabel: UILabel {
    var insets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }
}

/// Draws theme material from its current semantic values instead of freezing a `CGColor` in a
/// layer. The view is transparent to touches so it can sit above a scroll view or composer.
/// A themed stroke drawn from a `UIColor` each time the view draws, rather than a `CGColor`
/// frozen onto a layer — which is the whole point of the mobile theme boundary's border rule: a
/// stored `CGColor` does not follow a live theme change or a trait collection.
///
/// Internal rather than private because the composer's attachment chips need the same stroke.
final class MobileThemeOutlineView: UIView {
    private var color: UIColor = .clear
    private var radius: CGFloat = 0
    private var width: CGFloat = 0
    private var glow: RemoteThemeDTO.Material.Glow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        color: UIColor,
        radius: CGFloat,
        width: CGFloat,
        glow: RemoteThemeDTO.Material.Glow?
    ) {
        self.color = color
        self.radius = radius
        self.width = width
        self.glow = glow
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        if let glow,
           let glowColor = UIColor(remoteHex: glow.color),
           glow.radius > 0,
           glow.opacity > 0 {
            let glowWidth = min(CGFloat(glow.radius), MobileDesign.Spacing.tight)
            let glowInset = glowWidth / 2
            let glowPath = UIBezierPath(
                roundedRect: rect
                    .insetBy(dx: glowInset, dy: glowInset)
                    .offsetBy(
                        dx: CGFloat(glow.offsetX ?? 0),
                        dy: CGFloat(-(glow.offsetY ?? 0))
                    ),
                cornerRadius: max(0, radius - glowInset)
            )
            glowPath.lineWidth = glowWidth
            glowColor.withAlphaComponent(CGFloat(glow.opacity / 6)).setStroke()
            glowPath.stroke()
        }

        let inset = width / 2
        let borderPath = UIBezierPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, radius - inset)
        )
        borderPath.lineWidth = width
        color.setStroke()
        borderPath.stroke()
    }
}

private final class RemoteConversationNavigationTitleView: UIControl {
    private let titleLabel = MobileMorphingTitleLabel()
    /// The mark and the phrase, laid out by the one owner both navigation titles share.
    private let statusLine = MobileConnectionStatusLineView()
    private var titleColor = UIColor.label
    private var titleGroundColor = UIColor.systemBackground
    private var statusLabelColor = UIColor.secondaryLabel
    private var statusColor = UIColor.secondaryLabel
    /// In the status dot's place, not beside the title. Beside the title it took a column of
    /// its own and pushed the name off the bar's centre every time a turn started, and it left
    /// two marks on one line saying two different things at once. Standing where the dot stands
    /// costs no width, and the dot has nothing to add while a turn runs: the orb appears only
    /// on a connected session, which is the one thing a green dot was there to say.
    private let orb = MobileWorkingOrbView(diameter: MobileDesign.Size.navigationWorkingOrb)
    private var reconnect: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        statusLine.workingMark = orb
        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLine])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MobileDesign.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The line is as wide as the title and centres the mark and phrase inside itself,
            // so the phrase's width decides where the mark stands and never how wide the line is.
            statusLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        titleLabel.isAccessibilityElement = false
        addAction(UIAction { [weak self] _ in self?.reconnect?() }, for: .touchUpInside)
        MobileButtonHaptics.install(on: self)
        accessibilityTraits = .header
    }

    /// Stated rather than measured, so a rename cannot move the label its own name morphs in.
    /// See `MobileDesign.Size.navigationTitleWidth`.
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: MobileDesign.Size.navigationTitleWidth,
            height: MobileDesign.Size.navigationTitleHeight
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `recovery` is the whole failure state's one next step, which is not always a retry: a
    /// dead address needs a fresh QR code and a denied Local Network switch needs Settings.
    func update(
        title: String,
        status: String,
        statusColor: UIColor,
        isWorking: Bool,
        recovery: (title: String, action: () -> Void)?
    ) {
        self.statusColor = statusColor
        // Entering work hides the dot before a simultaneous status update can start a fade.
        // Leaving work updates the hidden dot first, then reveals it already settled beside the
        // current phrase. In either direction one mark speaks at a time.
        if isWorking, !statusLine.isWorking {
            orb.prepareForWorking()
            statusLine.isWorking = true
        }
        statusLine.update(
            status: status,
            color: statusColor,
            textColor: statusLabelColor,
            groundColor: titleGroundColor,
            reducesMotion: UIAccessibility.isReduceMotionEnabled
        )
        titleLabel.configure(
            title: title,
            textStyle: .headline,
            weight: .semibold,
            textColor: titleColor,
            groundColor: titleGroundColor,
            alignment: .center,
            reducesMotion: UIAccessibility.isReduceMotionEnabled,
            role: .chatName
        )
        // One mark at a time: the line hides whichever is not speaking and reflows the phrase
        // around the other instead of holding a gap for it.
        if !isWorking, statusLine.isWorking {
            statusLine.isWorking = false
        }
        self.reconnect = recovery?.action
        isUserInteractionEnabled = recovery != nil
        // The orb is a picture of the same fact, so VoiceOver hears it as a word rather than
        // hearing nothing at all.
        accessibilityLabel = [title, status, isWorking ? MobileL10n.string("Working…") : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityHint = recovery?.title
    }

    func applyTheme(_ theme: RemoteThemePalette) {
        titleColor = theme.uiLabel
        titleGroundColor = theme.uiSurface
        statusLabelColor = theme.uiSecondaryLabel
        titleLabel.configure(
            title: titleLabel.stringValue,
            textStyle: .headline,
            weight: .semibold,
            textColor: titleColor,
            groundColor: titleGroundColor,
            alignment: .center,
            reducesMotion: UIAccessibility.isReduceMotionEnabled,
            role: .chatName
        )
        // Restated in the new ink only once there is a status to restate: a theme that lands
        // before the first update must not count as the line's first presentation.
        if let status = statusLine.presentedStatus {
            statusLine.update(
                status: status,
                color: statusColor,
                textColor: statusLabelColor,
                groundColor: titleGroundColor,
                reducesMotion: UIAccessibility.isReduceMotionEnabled
            )
        }
        orb.applyTheme(theme)
    }
}

// MARK: - Attachment Sources

/// What the phone offers to pick from, matched to what the Mac will keep.
enum ComposerAttachmentSources {
    /// The document picker's allow-list, derived from the shared
    /// `RemoteAttachmentUploadLimits.offeredFileExtensions` rather than written out again here.
    ///
    /// Two lists would drift, and the drift is not symmetric: offering a type the host refuses
    /// spends a whole transfer to reach a 400 the person cannot act on. An extension iOS has no
    /// uniform type for is simply dropped, which offers less than the host accepts — the safe
    /// direction.
    static let documentTypes: [UTType] = RemoteAttachmentUploadLimits.offeredFileExtensions
        .compactMap { UTType(filenameExtension: $0) }

    /// Reads no more than one upload can carry, even if a provider changes the file after its
    /// metadata was inspected. `Data(contentsOf:)` reads an attacker- or cloud-sized file in one
    /// allocation before the tray can apply its 24 MB policy; this enforces the policy while the
    /// bytes cross the filesystem boundary.
    static func readFile(at url: URL) -> Data? {
        let maximum = RemoteAttachmentUploadLimits.maximumBytesPerFile
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize, size > maximum {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximum, 64 * 1_024))
        do {
            while data.count <= maximum {
                let remaining = maximum + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard data.count <= maximum else { return nil }
        return data
    }
}

// MARK: - Picking

/// PHPicker documents its delegate delivery and result objects as immutable for the callback,
/// but its pre-concurrency Objective-C declaration does not express that to Swift. This wrapper
/// makes the one transfer explicit; every use is immediately serialized onto the main actor.
private struct SendablePHPickerResults: @unchecked Sendable {
    let values: [PHPickerResult]
}

extension RemoteConversationViewController: PHPickerViewControllerDelegate {
    nonisolated func picker(
        _ picker: PHPickerViewController,
        didFinishPicking results: [PHPickerResult]
    ) {
        let transferredResults = SendablePHPickerResults(values: results)
        Task { @MainActor in
            picker.dismiss(animated: true)
            guard !transferredResults.values.isEmpty else { return }
            attachmentPicksInFlight += 1
            updateComposer()
            defer {
                attachmentPicksInFlight -= 1
                updateComposer()
            }
            for result in transferredResults.values {
                await loadPickedImage(result)
            }
        }
    }

    /// Reads one picked photo as bytes.
    ///
    /// `loadDataRepresentation` rather than `loadObject(ofClass: UIImage.self)`: the latter hands
    /// back a decoded image, which throws away the original encoding and would turn every pick
    /// into a re-encode even when the file was already small enough to send untouched.
    private func loadPickedImage(_ result: PHPickerResult) async {
        let provider = result.itemProvider
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
        guard let identifier, let type = UTType(identifier) else { return }
        let name = provider.suggestedName.map { "\($0).\(type.preferredFilenameExtension ?? "img")" }
            ?? MobileL10n.string("Photo")

        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else {
            attachmentTray?.reportUnreadableFile()
            return
        }
        attachmentTray?.add(data: data, name: name, type: type)
    }
}

extension RemoteConversationViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard !urls.isEmpty else { return }
        attachmentPicksInFlight += 1
        updateComposer()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                attachmentPicksInFlight -= 1
                updateComposer()
            }
            for url in urls.prefix(remainingAttachmentSlots) {
                // `asCopy: true` already put these in the app's own container, so no
                // security-scoped access is needed. Reading is still off the main actor and
                // bounded at the source, since a provider controls the copied file's size.
                let loaded = await Task.detached(priority: .userInitiated) {
                    let data = ComposerAttachmentSources.readFile(at: url)
                    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                        ?? UTType(filenameExtension: url.pathExtension)
                        ?? .data
                    return data.map { ($0, type) }
                }.value
                guard let (data, type) = loaded else {
                    attachmentTray?.reportUnreadableFile()
                    continue
                }
                attachmentTray?.add(data: data, name: url.lastPathComponent, type: type)
            }
        }
    }
}
