import Combine
import SwiftUI
import ThreadingRemoteKit
import UIKit

/// The SwiftUI session router stops at this boundary. Everything that changes while a chat is
/// open is observed and laid out by UIKit, so transcript updates, typing and keyboard changes do
/// not invalidate a hosting-tree transaction.
struct ConversationRemoteView: UIViewControllerRepresentable {
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
    private let attentionButton = UIButton(type: .system)
    private let textView = IntrinsicTextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let navigationTitleView = RemoteConversationNavigationTitleView()

    private lazy var timelineController: RemoteConversationTimelineViewController = {
        let hostID = model.activeHostID
        let saved = hostID.map {
            continuity.state(hostID: $0, sessionID: connection.session.id)
        }
        return RemoteConversationTimelineViewController(
            connection: connection,
            theme: theme,
            initialViewport: saved.map {
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
    private var capabilityKindFilter: String?
    private var preservedSkillArguments: String?
    private var pendingSubmissionID: String?
    private var submissionNotice: String?
    private var lastSubmissionFeedback: RemotePromptSubmissionFeedback?
    private var lastCapabilities: [RemoteComposerCapabilityDTO] = []
    private var initiallyFocused = false

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
            equalTo: view.safeAreaLayoutGuide.bottomAnchor
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
            top: MobileDesign.Spacing.small,
            left: MobileDesign.Spacing.large,
            bottom: MobileDesign.Spacing.small,
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
            controlIcon.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: MobileDesign.Spacing.large),
            controlIcon.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            controlIcon.widthAnchor.constraint(equalToConstant: 18),
            controlIcon.heightAnchor.constraint(equalToConstant: 18),
            controlLabel.leadingAnchor.constraint(equalTo: controlIcon.trailingAnchor, constant: MobileDesign.Spacing.small),
            controlLabel.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: MobileDesign.Spacing.tight),
            controlLabel.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor, constant: -MobileDesign.Spacing.tight),
            requestControlButton.leadingAnchor.constraint(greaterThanOrEqualTo: controlLabel.trailingAnchor, constant: MobileDesign.Spacing.small),
            requestControlButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            requestControlButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MobileDesign.Size.minimumTapTarget),
            controlMenuButton.leadingAnchor.constraint(greaterThanOrEqualTo: requestControlButton.trailingAnchor, constant: MobileDesign.Spacing.tight),
            controlMenuButton.leadingAnchor.constraint(greaterThanOrEqualTo: controlLabel.trailingAnchor, constant: MobileDesign.Spacing.tight),
            controlMenuButton.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -MobileDesign.Spacing.small),
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
        composerStack.alignment = .bottom
        composerStack.spacing = MobileDesign.Spacing.small
        composerShell.addSubview(composerPanel)
        composerPanel.addSubview(composerStack)
        composerOutline.translatesAutoresizingMaskIntoConstraints = false
        composerPanel.addSubview(composerOutline)

        configureCircleButton(
            capabilityButton,
            symbol: "plus",
            accessibilityLabel: MobileL10n.string("Browse commands and skills")
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
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 9),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
        ])

        [capabilityButton, attentionButton, textView, sendButton].forEach(composerStack.addArrangedSubview)
        NSLayoutConstraint.activate([
            composerPanel.leadingAnchor.constraint(equalTo: composerShell.leadingAnchor, constant: MobileDesign.Spacing.inset),
            composerPanel.trailingAnchor.constraint(equalTo: composerShell.trailingAnchor, constant: -MobileDesign.Spacing.inset),
            composerPanel.topAnchor.constraint(equalTo: composerShell.topAnchor, constant: MobileDesign.Spacing.small),
            composerPanel.bottomAnchor.constraint(equalTo: composerShell.bottomAnchor, constant: -MobileDesign.Spacing.small),
            composerStack.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor, constant: MobileDesign.Spacing.medium),
            composerStack.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor, constant: -MobileDesign.Spacing.medium),
            composerStack.topAnchor.constraint(equalTo: composerPanel.topAnchor, constant: MobileDesign.Spacing.small),
            composerStack.bottomAnchor.constraint(equalTo: composerPanel.bottomAnchor, constant: -MobileDesign.Spacing.small),
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
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
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
        capabilityButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            capabilityKindFilter = nil
            preservedSkillArguments = nil
            showsCapabilityCatalog.toggle()
            updateCapabilities()
        }, for: .touchUpInside)
        attentionButton.addAction(UIAction { [weak self] _ in
            self?.presentAttentionRequest()
        }, for: .touchUpInside)
        sendButton.addAction(UIAction { [weak self] _ in
            self?.submitDraft()
        }, for: .touchUpInside)
        requestControlButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            _ = connection.changeInputControl(action: "request")
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
            overlap = max(0, view.bounds.maxY - frameInView.minY - view.safeAreaInsets.bottom)
        } else {
            overlap = 0
        }
        bottomConstraint.constant = -overlap
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
        composerPanel.layer.cornerRadius = theme.panelRadius
        composerOutline.update(
            color: theme.uiBorder,
            radius: theme.panelRadius,
            width: theme.borderWidth,
            glow: theme.glow
        )
        textView.textColor = theme.uiLabel
        textView.tintColor = theme.uiAccent
        placeholderLabel.textColor = theme.uiTertiaryLabel
        capabilityButton.backgroundColor = theme.uiControlResting
        capabilityButton.tintColor = theme.uiLabel
        attentionButton.backgroundColor = theme.uiControlResting
        attentionButton.tintColor = theme.uiLabel
        navigationTitleView.applyTheme(theme)
    }

    private func installNavigationTitle() {
        navigationController?.topViewController?.navigationItem.titleView = navigationTitleView
        updateNavigationTitle()
    }

    private func updateNavigationTitle() {
        navigationTitleView.update(
            title: connection.title,
            status: connectionStatusLabel,
            statusColor: connectionStatusColor,
            reconnect: connection.phase.isFailed ? { [weak connection] in connection?.connect() } : nil
        )
    }

    private var connectionStatusLabel: String {
        switch connection.phase {
        case .connecting: return MobileL10n.string("Connecting to Mac…")
        case .connected:
            return MobileL10n.string(
                connection.capability == .interact ? "Remote control" : "View only"
            )
        case .ended(let reason), .failed(let reason): return reason
        }
    }

    private var connectionStatusColor: UIColor {
        switch connection.phase {
        case .connected: return theme.uiPositive
        case .connecting: return theme.uiWarning
        case .ended, .failed: return theme.uiTertiaryLabel
        }
    }

    private func updatePresence() {
        let people = Array(connection.presence.values)
        let typingNames = uniqueNames(people.filter { $0.state == "typing" })
        let viewingNames = uniqueNames(people)
        let text: String?
        if notifications.typingIndicatorsEnabled, !typingNames.isEmpty {
            text = presenceText(names: typingNames, action: "typing")
        } else if notifications.peoplePresenceEnabled, !viewingNames.isEmpty {
            text = presenceText(names: viewingNames, action: "viewing")
        } else {
            text = nil
        }
        presenceLabel.text = text
        presenceLabel.isHidden = text == nil
    }

    private func updateInputControl() {
        guard connection.supportsFocusedInputControl, let state = connection.inputControl else {
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
            actions.append(controlAction(title: MobileL10n.string("Collaborative"), action: "collaborative"))
        }
        if state.canManage, !state.canWrite {
            actions.append(controlAction(title: MobileL10n.string("Reclaim control"), action: "reclaim"))
        }
        if state.mode == .collaborative, state.canManage {
            actions.append(controlAction(
                title: MobileL10n.string("Focus on me"),
                action: "focused",
                targetID: state.currentParticipantID
            ))
        }
        if state.mode == .focused {
            for participant in state.participants where participant.id != state.controllerID {
                actions.append(controlAction(
                    title: MobileL10n.string("Hand off to %@", participant.displayName),
                    action: "handoff",
                    targetID: participant.id
                ))
            }
        }
        return actions
    }

    private func controlAction(title: String, action: String, targetID: String? = nil) -> UIAction {
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
        textView.isEditable = enabled
        capabilityButton.isEnabled = connection.capability == .interact
            && !connection.composerCapabilities.isEmpty
        attentionButton.isHidden = !(
            connection.phase == .connected
                && connection.capability == .interact
                && connection.supportsAttentionRequests
                && !connection.attentionRecipients.isEmpty
        )
        sendButton.isEnabled = enabled && hasText
        sendButton.backgroundColor = sendButton.isEnabled ? theme.uiAccent : theme.uiControlResting
        sendButton.tintColor = sendButton.isEnabled ? theme.uiGround : theme.uiSecondaryLabel
        placeholderLabel.isHidden = !textView.text.isEmpty
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
                if $0.kind != $1.kind { return $0.kind == "command" }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        } else {
            return []
        }
        guard let capabilityKindFilter else { return items }
        return capabilityKindFilter == "skill"
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
        if let requestID = connection.submit(textView.text) {
            pendingSubmissionID = requestID
            showsCapabilityCatalog = false
            capabilityKindFilter = nil
            preservedSkillArguments = nil
            updateCapabilities()
            updateSubmission()
        }
    }

    private func openSkillCatalog(preserving arguments: String?) {
        guard let skill = connection.composerCapabilities.first(where: \.canBrowseAsSkill)
        else { return }
        preservedSkillArguments = arguments
        textView.text = skill.trigger == "dollar" ? "$" : "/"
        showsCapabilityCatalog = true
        capabilityKindFilter = "skill"
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
            .environment(\.remoteTheme, theme)
            .preferredColorScheme(theme.colorScheme)
        let controller = UIHostingController(rootView: root)
        controller.modalPresentationStyle = .pageSheet
        present(controller, animated: true)
    }

    private func restoreDraft() {
        guard let hostID = model.activeHostID else { return }
        let draft = continuity.draft(
            surface: .conversation,
            hostID: hostID,
            sessionID: connection.session.id
        )
        // Assigning even the same empty string makes UITextView coordinate a selection change
        // and cold-load dictation services. Most conversations have no saved draft, so keep that
        // framework out of first paint without delaying a real draft by one frame.
        if textView.text != draft {
            textView.text = draft
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
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
        ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] == "conversation-keyboard"
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

    private func presenceText(names: [String], action: String) -> String {
        if names.count == 1 {
            return action == "typing"
                ? MobileL10n.string("%@ is typing…", names[0])
                : MobileL10n.string("%@ is here", names[0])
        }
        if names.count == 2 {
            let joined = names.joined(separator: MobileL10n.string(" and "))
            return action == "typing"
                ? MobileL10n.string("%@ are typing…", joined)
                : MobileL10n.string("%@ are here", joined)
        }
        return action == "typing"
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

private final class IntrinsicTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let fittingWidth = max(bounds.width, 1)
        let height = sizeThatFits(CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)).height
        return CGSize(width: UIView.noIntrinsicMetric, height: min(max(height, 44), 132))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let shouldScroll = contentSize.height > 132
        if isScrollEnabled != shouldScroll { isScrollEnabled = shouldScroll }
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
private final class MobileThemeOutlineView: UIView {
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
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let dot = UIView()
    private var reconnect: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let statusStack = UIStackView(arrangedSubviews: [dot, statusLabel])
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = MobileDesign.Spacing.tight
        let stack = UIStackView(arrangedSubviews: [titleLabel, statusStack])
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
            dot.widthAnchor.constraint(equalToConstant: MobileDesign.Size.navigationStatusIndicator),
            dot.heightAnchor.constraint(equalTo: dot.widthAnchor),
        ])
        dot.layer.cornerRadius = MobileDesign.Size.navigationStatusIndicator / 2
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textAlignment = .center
        addAction(UIAction { [weak self] _ in self?.reconnect?() }, for: .touchUpInside)
        accessibilityTraits = .header
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 280, height: 44)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, status: String, statusColor: UIColor, reconnect: (() -> Void)?) {
        titleLabel.text = title
        statusLabel.text = status
        dot.backgroundColor = statusColor
        self.reconnect = reconnect
        isUserInteractionEnabled = reconnect != nil
        accessibilityLabel = [title, status].joined(separator: ", ")
        accessibilityHint = reconnect == nil ? nil : MobileL10n.string("Reconnect")
    }

    func applyTheme(_ theme: RemoteThemePalette) {
        titleLabel.textColor = theme.uiLabel
        statusLabel.textColor = theme.uiSecondaryLabel
    }
}

private extension RemoteSessionConnection.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
