#if os(Linux)
import AppKit
import Glibc
import LinuxWindowBridge
@testable import CoreSlice

@MainActor
private final class SettingsMenuSession: LinuxThemedMenuSession {
    private weak var source: NSView?
    private let surface: ThemedMenuSurfaceView
    private let entries: [ThemedMenuEntry]
    private let desiredSize: NSSize
    private let choose: (Int, ThemedMenuItem) -> Void
    private let onDismiss: () -> Void
    private var highlighted: Int?
    private var dismissed = false

    init(source: NSView, surface: ThemedMenuSurfaceView, entries: [ThemedMenuEntry],
         desiredSize: NSSize, selected: Int?,
         choose: @escaping (Int, ThemedMenuItem) -> Void,
         onDismiss: @escaping () -> Void) {
        self.source = source
        self.surface = surface
        self.entries = entries
        self.desiredSize = desiredSize
        self.choose = choose
        self.onDismiss = onDismiss
        highlighted = selected ?? surface.selectableIndices.first
        surface.highlight(highlighted)
        (source as? ThemedMenuPresentationObserving)?
            .themedMenuPresentationDidChange(isPresented: true)
    }

    var frame: NSRect { surface.frame }

    func reposition(in root: NSView) {
        guard let source else { dismiss(); return }
        let anchor = source.convert(source.bounds, to: root)
        surface.frame = ThemedMenuLayout.frame(anchor: anchor, desiredSize: desiredSize,
            in: root.bounds, flipped: root.isFlipped,
            whenClipped: { ThemedMenuMetrics.clippedHeight(for: entries, atMost: $0) })
    }

    func select(_ index: Int) {
        guard surface.selectableIndices.contains(index) else { return }
        highlighted = index
    }

    func move(_ step: Int) {
        let indices = surface.selectableIndices
        guard !indices.isEmpty else { return }
        let position = highlighted.flatMap(indices.firstIndex(of:)) ?? 0
        highlighted = indices[(position + step + indices.count) % indices.count]
        surface.highlight(highlighted)
        print("SETTINGS_POPUP_HIGHLIGHTED entry=\(highlighted ?? -1)")
        fflush(nil)
    }

    func chooseHighlighted() {
        guard let highlighted, let item = surface.row(at: highlighted)?.item else { return }
        dismiss()
        choose(highlighted, item)
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        surface.retireFromAccessibility()
        surface.removeFromSuperview()
        (source as? ThemedMenuPresentationObserving)?
            .themedMenuPresentationDidChange(isPresented: false)
        onDismiss()
    }
}

/// The Settings detour in the workspace. SDL supplies only the viewport; the shared Settings
/// page, row and New Chats structures own the surfaces on both desktop hosts.
@MainActor
final class WorkspaceSettingsPane: WorkspacePane, NSTextFieldDelegate {
    private enum Page: Int, CaseIterable { case general, chats
        var title: String { self == .general ? "General" : "Chats" }
    }
    let chrome = WorkspacePaneChrome(pageName: "Settings", pageIdentity: "settings.general",
                                      onReveal: {})
    var title: String { "Threading - Settings" }
    var needsPolling: Bool { openingMessageWriteDueAt != nil }
    var onDone: (() -> Void)?
    var onRetentionChange: (() -> Void)?
    var onOutsideProjectScopeChange: ((Bool) -> Void)?
    var onPresentationChange: (() -> Void)?
    var onChooseScratchpadFolder: (() -> Void)?
    var onUseDefaultScratchpadFolder: (() -> Void)?

    private let owner = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
    private let root = NSView(frame: .zero)
    private let done = ThemedButton()
    private let chatsDone = ThemedButton()
    private var pageSelectors: [ThemedPopUp] = []
    private let restoreSessionToggle = ThemedToggle()
    private let restorePolicyPopUp = ThemedPopUp(frame: .zero)
    private let restoreWindowPopUp = ThemedPopUp(frame: .zero)
    private let restoreLimitPopUp = ThemedPopUp(frame: .zero)
    private let defaultAgentPopUp = ThemedPopUp(frame: .zero)
    private let permissionModePopUp = ThemedPopUp(frame: .zero)
    private let claudeStartupSpeedPopUp = ThemedPopUp(frame: .zero)
    private let codexStartupSpeedPopUp = ThemedPopUp(frame: .zero)
    private let newChatOpeningPrefixField = ThemedTextField()
    private let newChatOpeningSuffixField = ThemedTextField()
    private var newChatsHelpButtons: [HelpPopoverButton] = []
    private var openingMessageHelpButton: HelpPopoverButton?
    private let attachmentDetectionToggles: [AgentKind: ThemedToggle] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { ($0, ThemedToggle()) })
    private let outsideProjectAttachmentToggle = ThemedToggle()
    private var outsideProjectAttachmentHelpButton: HelpPopoverButton?
    private var attachmentsHelpButton: HelpPopoverButton?
    private let scratchpadChooseButton = ThemedButton()
    private let scratchpadDefaultButton = ThemedButton()
    private var scratchpadHelpButton: HelpPopoverButton?
    private var scratchpadFolderLabel: NSTextField?
    private var openingMessageWriteDueAt: TimeInterval?
    private weak var unsettledOpeningMessageField: ThemedTextField?
    private var generalPage: NSView?
    private var chatsPage: NSView?
    private var activePage: NSView?
    private var pageConstraints: [NSLayoutConstraint] = []
    private var selectedPage: Page = .general
    private var popupSession: SettingsMenuSession?
    private var helpSession: LinuxHelpPopoverSession?
    private var popupFixture: ThemedPopUp?
    private var toggles: [(ConfirmationPrompt, ThemedToggle)] = []
    private var presentedSize = NSSize.zero
    private var displayRevision: UInt64 = 0
    private var needsPresentation = true {
        didSet { if needsPresentation { onPresentationChange?() } }
    }
    private var accessibleViews: [String: NSView] = [:]
    private static let maximumAccessibleControls = 96

    init() {
        LinuxSymbols.install()
        owner.contentView = root
        buildPage()
        setThemeAppearance()
    }

    private func presentPopup(_ presentation: ThemedMenuPresentation, from source: NSView,
                              selected: Int?,
                              onChoose: @escaping (Int, ThemedMenuItem) -> Void,
                              onDismiss: @escaping () -> Void) -> AnyObject? {
        helpSession?.popover.close()
        guard source.window === owner, popupSession == nil else { return nil }
        owner.layoutIfNeeded()
        let entries = presentation.entries
        let width = ThemedMenuMetrics.width(for: entries,
            minimum: presentation.minimumWidth, selectedEntryIndex: selected)
        let desiredSize = NSSize(width: width, height: ThemedMenuMetrics.height(for: entries))
        let frame = ThemedMenuLayout.frame(
            anchor: source.convert(source.bounds, to: root),
            desiredSize: desiredSize,
            in: root.bounds, flipped: root.isFlipped,
            whenClipped: { ThemedMenuMetrics.clippedHeight(for: entries, atMost: $0) })
        let surface = ThemedMenuSurfaceView(
            frame: frame, entries: entries, selectedEntryIndex: selected)
        surface.appearance = LinuxTheme.appearance
        let sourceID = source.accessibilityIdentifier() ?? "unknown"
        for index in entries.indices {
            surface.row(at: index)?.setAccessibilityIdentifier("settings.menu.\(sourceID).\(index)")
        }
        root.addSubview(surface)
        let session = SettingsMenuSession(source: source, surface: surface, entries: entries,
            desiredSize: desiredSize, selected: selected,
            choose: onChoose, onDismiss: { [weak self] in
                self?.popupSession = nil
                self?.needsPresentation = true
                onDismiss()
            })
        surface.onChoose = { [weak session] index, item in
            session?.dismiss()
            onChoose(index, item)
        }
        surface.onHighlight = { [weak session] index in
            session?.select(index)
        }
        popupSession = session
        needsPresentation = true
        print("SETTINGS_POPUP_OPENED rows=\(surface.selectableIndices.count) "
            + "x=\(frame.minX) y=\(frame.minY) width=\(frame.width) height=\(frame.height)")
        fflush(nil)
        return session
    }

    private func presentHelp(_ popover: ThemedPopover, from source: NSView) -> Bool {
        guard source.window === owner, helpSession == nil, popupSession == nil,
              let session = LinuxHelpPopoverSession(popover: popover, source: source,
                                                    root: root, owner: owner) else { return false }
        helpSession = session
        let dismiss = popover.hostDismiss
        popover.hostDismiss = { [weak self] in
            dismiss?()
            self?.helpSession = nil
            self?.needsPresentation = true
            print("SETTINGS_HELP_CLOSED")
            fflush(nil)
        }
        needsPresentation = true
        print("SETTINGS_HELP_OPENED width=\(session.frame.width) height=\(session.frame.height)")
        fflush(nil)
        return true
    }

    func takeInitialViewport() -> (Int, Int)? { nil }

    private func buildPage() {
        done.title = "Done"
        done.setAccessibilityIdentifier("settings.general.done")
        done.emphasis = .secondary
        done.action = { [weak self] in self?.onDone?() }
        restoreSessionToggle.state = LinuxGeneralSettings.restoresLastSession ? .on : .off
        restoreSessionToggle.setAccessibilityIdentifier("settings.general.restore-last-session")
        restoreSessionToggle.action = { [weak self] in
            guard let self else { return }
            LinuxGeneralSettings.restoresLastSession = restoreSessionToggle.state == .on
            print("SETTINGS_RESTORE_CHANGED enabled=\(LinuxGeneralSettings.restoresLastSession)")
            fflush(nil)
            needsPresentation = true
        }
        for policy in SessionRestorePolicy.allCases {
            restorePolicyPopUp.addItem(ThemedMenuItem(title: policy.settingsTitle,
                onChoose: { [weak self] in
                    LinuxGeneralSettings.sessionRestorePolicy = policy
                    print("SETTINGS_POLICY_CHANGED value=\(policy.rawValue)")
                    fflush(nil)
                    self?.needsPresentation = true
                }))
        }
        let initialPolicy = LinuxGeneralSettings.sessionRestorePolicy
        restorePolicyPopUp.selectItem(at: SessionRestorePolicy.allCases.firstIndex(
            of: initialPolicy) ?? 0)
        restorePolicyPopUp.setAccessibilityIdentifier("settings.general.session-restore-policy")
        print("SETTINGS_POLICY_LOADED value=\(initialPolicy.rawValue)")
        for days in SessionRestoreDefaults.windowDayChoices {
            restoreWindowPopUp.addItem(ThemedMenuItem(
                title: SessionRestoreDefaults.windowTitle(days: days), onChoose: { [weak self] in
                    LinuxGeneralSettings.sessionRestoreWindowDays = days
                    self?.onRetentionChange?()
                    self?.needsPresentation = true
                    print("SETTINGS_IDLE_WINDOW_CHANGED days=\(days)")
                    fflush(nil)
                }))
        }
        let initialWindowDays = LinuxGeneralSettings.sessionRestoreWindowDays
        restoreWindowPopUp.selectItem(at: SessionRestoreDefaults.windowDayChoices.firstIndex(
            of: initialWindowDays) ?? 0)
        restoreWindowPopUp.setAccessibilityIdentifier("settings.general.session-restore-window")
        for limit in SessionRestoreDefaults.limitChoices {
            restoreLimitPopUp.addItem(ThemedMenuItem(
                title: SessionRestoreDefaults.limitTitle(limit), onChoose: { [weak self] in
                    LinuxGeneralSettings.sessionRestoreLimit = limit
                    self?.onRetentionChange?()
                    self?.needsPresentation = true
                    print("SETTINGS_IDLE_LIMIT_CHANGED limit=\(limit)")
                    fflush(nil)
                }))
        }
        let initialLimit = LinuxGeneralSettings.sessionRestoreLimit
        restoreLimitPopUp.selectItem(at: SessionRestoreDefaults.limitChoices.firstIndex(
            of: initialLimit) ?? 0)
        restoreLimitPopUp.setAccessibilityIdentifier("settings.general.session-restore-limit")
        print("SETTINGS_IDLE_LOADED days=\(initialWindowDays) limit=\(initialLimit)")
        let choices = ConfirmationPrompt.suppressible.compactMap { prompt -> SettingsConfirmationCard.Choice? in
            guard let copy = prompt.suppression else { return nil }
            let toggle = ThemedToggle()
            toggle.state = LinuxConfirmationSettings.asks(before: prompt) ? .on : .off
            toggle.setAccessibilityIdentifier("settings.general.confirmation.\(prompt.rawValue)")
            toggle.action = { [weak self, weak toggle] in
                guard let toggle else { return }
                let asks = toggle.state == .on
                LinuxConfirmationSettings.setAsks(asks, before: prompt)
                print("SETTINGS_CONFIRMATION_CHANGED \(prompt.rawValue) asks=\(asks)")
                fflush(nil)
                self?.needsPresentation = true
            }
            toggles.append((prompt, toggle))
            return SettingsConfirmationCard.Choice(title: copy.settingsTitle,
                                                   subtitle: copy.settingsSubtitle,
                                                   control: toggle)
        }
        let card = SettingsConfirmationCard.make(choices: choices).card
        let controls = GeneralSettingsPageStructure.Controls(
            startup: .init(restoresSession: restoreSessionToggle, policy: restorePolicyPopUp),
            idleAgents: .init(window: restoreWindowPopUp, limit: restoreLimitPopUp),
            confirmations: card,
            softwareUpdates: nil, agentTools: nil, machine: nil)
        let sections = GeneralSettingsPageStructure.sections(
            controls: controls, machineTitle: "This computer",
            row: { SettingsRowStructure.make(title: $0.title,
                                             subtitle: $0.subtitle, control: $1) },
            section: { title, _, content in
                SettingsPageStructure.section(
                    caption: title.map(SettingsPageStructure.caption), content: content)
            })
        var displayedSections: [NSView] = []
        if ProcessInfo.processInfo.environment["THREADING_LINUX_SETTINGS_POPUP_FIXTURE"] == "1" {
            let popup = ThemedPopUp(frame: .zero)
            for title in ["First choice", "Second choice", "Third choice"] {
                popup.addItem(ThemedMenuItem(title: title, onChoose: {
                    print("SETTINGS_POPUP_CHOSEN \(title)")
                    fflush(nil)
                }))
            }
            popup.setAccessibilityIdentifier("settings.popup.fixture")
            popupFixture = popup
            let fixtureCard = SettingsCard(rows: [SettingsRowStructure.make(
                title: "Pop-up control fixture", subtitle: nil, control: popup)])
            displayedSections.append(SettingsPageStructure.section(
                caption: SettingsPageStructure.caption("Pop-up fixture"),
                content: fixtureCard))
        }
        displayedSections.append(contentsOf: sections)
        let body = SettingsPageStructure.scrolling(displayedSections)
        let header = SettingsPageStructure.header(
            title: "General", summary: nil, actions: [makePageSelector(for: .general), done])
        let page = SettingsPageView(header: header.view,
                                    summaryField: header.summaryField, body: body)
        generalPage = page
        showPage(.general)

        restoreSessionToggle.nextKeyView = restorePolicyPopUp
        restorePolicyPopUp.nextKeyView = restoreWindowPopUp
        restoreWindowPopUp.nextKeyView = restoreLimitPopUp
        restoreLimitPopUp.nextKeyView = toggles.first?.1 ?? popupFixture ?? done
        for index in toggles.indices {
            toggles[index].1.nextKeyView = index + 1 < toggles.count
                ? toggles[index + 1].1 : popupFixture ?? done
        }
        popupFixture?.nextKeyView = done
        done.nextKeyView = restoreSessionToggle
    }

    private func makePageSelector(for current: Page) -> ThemedPopUp {
        let selector = ThemedPopUp(frame: .zero)
        for page in Page.allCases {
            selector.addItem(ThemedMenuItem(title: page.title, onChoose: { [weak self] in
                self?.showPage(page)
            }))
        }
        selector.selectItem(at: current.rawValue)
        selector.setAccessibilityIdentifier("settings.page")
        pageSelectors.append(selector)
        return selector
    }

    private func showPage(_ page: Page) {
        if page == .chats, chatsPage == nil { buildChatsPage() }
        guard let newPage = page == .general ? generalPage : chatsPage else { return }
        NSLayoutConstraint.deactivate(pageConstraints)
        activePage?.removeFromSuperview()
        pageConstraints = SettingsPageCanvasLayout.install(page: newPage, in: root)
        activePage = newPage
        selectedPage = page
        for selector in pageSelectors { selector.selectItem(at: page.rawValue) }
        needsPresentation = true
        print("SETTINGS_PAGE_SELECTED value=\(page.title)")
        fflush(nil)
    }

    private func buildChatsPage() {
        chatsDone.title = "Done"
        chatsDone.setAccessibilityIdentifier("settings.chats.done")
        chatsDone.emphasis = .secondary
        chatsDone.action = { [weak self] in
            self?.finishPendingTextWrites()
            self?.onDone?()
        }
        for kind in [AgentKind.claude, .codex] {
            defaultAgentPopUp.addItem(ThemedMenuItem(title: kind.displayName,
                onChoose: { [weak self] in
                    LinuxGeneralSettings.defaultAgentKind = kind
                    self?.rebuildPermissionModePopUp(for: kind)
                    self?.needsPresentation = true
                    print("SETTINGS_DEFAULT_AGENT_CHANGED value=\(kind.rawValue)")
                    fflush(nil)
                }))
        }
        let initialAgent = LinuxGeneralSettings.defaultAgentKind
        defaultAgentPopUp.selectItem(at: initialAgent == .claude ? 0 : 1)
        defaultAgentPopUp.setAccessibilityIdentifier("settings.chats.default-agent")
        rebuildPermissionModePopUp(for: initialAgent)
        permissionModePopUp.setAccessibilityIdentifier("settings.chats.default-permission-mode")
        print("SETTINGS_DEFAULT_AGENT_LOADED value=\(initialAgent.rawValue)")
        print("SETTINGS_DEFAULT_PERMISSION_LOADED value=\(LinuxGeneralSettings.defaultPermissionMode?.rawValue ?? "inherit")")
        for (kind, popup) in [(AgentKind.claude, claudeStartupSpeedPopUp),
                              (.codex, codexStartupSpeedPopUp)] {
            for speed in AgentStartupSpeed.allCases {
                popup.addItem(ThemedMenuItem(title: speed.settingsTitle, onChoose: { [weak self] in
                    LinuxGeneralSettings.setStartupSpeed(speed, for: kind)
                    self?.needsPresentation = true
                    print("SETTINGS_STARTUP_SPEED_CHANGED kind=\(kind.rawValue) value=\(speed.rawValue)")
                    fflush(nil)
                }))
            }
            let initial = LinuxGeneralSettings.startupSpeed(for: kind)
            popup.selectItem(at: AgentStartupSpeed.allCases.firstIndex(of: initial) ?? 0)
            popup.setAccessibilityIdentifier("settings.chats.\(kind.rawValue)-startup-speed")
            print("SETTINGS_STARTUP_SPEED_LOADED kind=\(kind.rawValue) value=\(initial.rawValue)")
        }
        newChatOpeningPrefixField.placeholderString =
            L10n.string(OpeningMessageSettingsStructure.prefixPlaceholder)
        newChatOpeningPrefixField.stringValue = LinuxGeneralSettings.newChatOpeningPrefix
        newChatOpeningPrefixField.setAccessibilityIdentifier(
            "settings.chats.new-chat-opening-prefix")
        newChatOpeningPrefixField.delegate = self
        newChatOpeningSuffixField.placeholderString =
            L10n.string(OpeningMessageSettingsStructure.suffixPlaceholder)
        newChatOpeningSuffixField.stringValue = LinuxGeneralSettings.newChatOpeningSuffix
        newChatOpeningSuffixField.setAccessibilityIdentifier(
            "settings.chats.new-chat-opening-suffix")
        newChatOpeningSuffixField.delegate = self
        print("SETTINGS_OPENING_LOADED prefixBytes=\(newChatOpeningPrefixField.stringValue.utf8.count) "
            + "suffixBytes=\(newChatOpeningSuffixField.stringValue.utf8.count)")
        let controls = NewChatsSettingsStructure.Controls(agent: defaultAgentPopUp,
            permission: permissionModePopUp,
            claudeSpeed: claudeStartupSpeedPopUp, codexSpeed: codexStartupSpeedPopUp)
        let rows = NewChatsSettingsStructure.rows(controls: controls) { row, control in
            let helpButton = row.help.map { help -> HelpPopoverButton in
                let button = HelpPopoverButton(topic: help.topic)
                button.setAccessibilityIdentifier(
                    "settings.chats.new-chats-help-\(newChatsHelpButtons.count)")
                newChatsHelpButtons.append(button)
                return button
            }
            return SettingsRowStructure.make(title: row.title, subtitle: row.subtitle,
                                             control: control, helpButton: helpButton)
        }
        let card = SettingsCard(rows: rows)
        let openingRows = OpeningMessageSettingsStructure.rows(
            prefixField: newChatOpeningPrefixField,
            suffixField: newChatOpeningSuffixField,
            makeLabelRow: { SettingsRowStructure.make(title: $0.title,
                subtitle: $0.subtitle, control: nil) },
            makeFullRow: SettingsRowStructure.padded)
        let openingHelp = HelpPopoverButton(topic:
            OpeningMessageSettingsStructure.sectionHelpTopic)
        openingHelp.setAccessibilityIdentifier("settings.chats.opening-message-help")
        openingMessageHelpButton = openingHelp
        for kind in AgentKind.allCases {
            guard let toggle = attachmentDetectionToggles[kind] else { continue }
            toggle.state = LinuxGeneralSettings.detectsAttachmentReferences(for: kind)
                ? .on : .off
            toggle.setAccessibilityIdentifier(
                "settings.chats.\(kind.rawValue)-attachment-detection")
            toggle.action = { [weak self, weak toggle] in
                guard let toggle else { return }
                let enabled = toggle.state == .on
                LinuxGeneralSettings.setAttachmentReferenceDetection(
                    for: kind, enabled: enabled)
                self?.needsPresentation = true
                print("SETTINGS_ATTACHMENT_DETECTION_CHANGED kind=\(kind.rawValue) enabled=\(enabled)")
                fflush(nil)
            }
            print("SETTINGS_ATTACHMENT_DETECTION_LOADED kind=\(kind.rawValue) "
                + "enabled=\(toggle.state == .on)")
        }
        outsideProjectAttachmentToggle.state =
            LinuxGeneralSettings.includesAttachmentsOutsideProject ? .on : .off
        print("SETTINGS_OUTSIDE_PROJECT_LOADED enabled=\(outsideProjectAttachmentToggle.state == .on)")
        outsideProjectAttachmentToggle.setAccessibilityIdentifier(
            "settings.chats.outside-project-attachments")
        outsideProjectAttachmentToggle.action = { [weak self] in
            guard let self else { return }
            let enabled = self.outsideProjectAttachmentToggle.state == .on
            LinuxGeneralSettings.includesAttachmentsOutsideProject = enabled
            self.onOutsideProjectScopeChange?(enabled)
            self.needsPresentation = true
            print("SETTINGS_OUTSIDE_PROJECT_CHANGED enabled=\(enabled)")
            fflush(nil)
        }
        let attachmentControls = AttachmentSettingsStructure.Controls(
            detection: attachmentDetectionToggles,
            outsideProject: outsideProjectAttachmentToggle, beforeActionCapture: nil)
        let attachmentsCard = AttachmentSettingsStructure.card(
            controls: attachmentControls) { row, control in
            let helpButton = row.help.map { help -> HelpPopoverButton in
                let button = HelpPopoverButton(topic: help.topic)
                button.setAccessibilityIdentifier("settings.chats.outside-project-help")
                outsideProjectAttachmentHelpButton = button
                return button
            }
            return SettingsRowStructure.make(title: row.title, subtitle: row.subtitle,
                control: control, helpButton: helpButton)
        }
        let attachmentHelp = HelpPopoverButton(
            topic: ChatsSettingsPageStructure.attachmentsHelpTopic)
        attachmentHelp.setAccessibilityIdentifier("settings.chats.attachments-help")
        attachmentsHelpButton = attachmentHelp
        scratchpadChooseButton.action = { [weak self] in
            self?.onChooseScratchpadFolder?()
        }
        scratchpadChooseButton.setAccessibilityIdentifier("settings.chats.scratchpad-choose")
        scratchpadDefaultButton.action = { [weak self] in
            self?.onUseDefaultScratchpadFolder?()
        }
        scratchpadDefaultButton.setAccessibilityIdentifier("settings.chats.scratchpad-default")
        let scratchpadHelp = HelpPopoverButton(topic: ScratchpadSettingsStructure.helpTopic)
        scratchpadHelp.setAccessibilityIdentifier("settings.chats.scratchpad-help")
        scratchpadHelpButton = scratchpadHelp
        let scratchpadRow = ScratchpadSettingsStructure.row(
            path: LinuxGeneralSettings.scratchpadFolderURL.path,
            choose: scratchpadChooseButton, useDefault: scratchpadDefaultButton,
            helpButton: scratchpadHelp)
        scratchpadFolderLabel = scratchpadRow.pathLabel
        updateScratchpadFolder()
        let content = ChatsSettingsPageStructure.Content(
            newChats: card,
            openingMessage: SettingsCard(rows: openingRows),
            attachments: attachmentsCard,
            scratchpad: SettingsCard(rows: [scratchpadRow.view])
        )
        let body = SettingsPageStructure.scrolling(
            ChatsSettingsPageStructure.sections(content,
                openingHelpButton: openingHelp,
                attachmentsHelpButton: attachmentHelp))
        let header = SettingsPageStructure.header(
            title: "Chats", summary: nil, actions: [makePageSelector(for: .chats), chatsDone])
        chatsPage = SettingsPageView(header: header.view,
            summaryField: header.summaryField, body: body)
        let newChatControls: [NSView] = [defaultAgentPopUp, permissionModePopUp,
                                          claudeStartupSpeedPopUp, codexStartupSpeedPopUp]
        var keyboardOrder: [NSView] = []
        for (index, control) in newChatControls.enumerated() {
            keyboardOrder.append(control)
            if index > 0, newChatsHelpButtons.indices.contains(index - 1) {
                keyboardOrder.append(newChatsHelpButtons[index - 1])
            }
        }
        keyboardOrder += [openingHelp, newChatOpeningPrefixField,
                          newChatOpeningSuffixField, attachmentHelp]
        keyboardOrder += AgentKind.allCases.compactMap { attachmentDetectionToggles[$0] }
        keyboardOrder.append(outsideProjectAttachmentToggle)
        if let outsideProjectAttachmentHelpButton {
            keyboardOrder.append(outsideProjectAttachmentHelpButton)
        }
        keyboardOrder += [scratchpadHelp, scratchpadChooseButton,
                          scratchpadDefaultButton, chatsDone]
        for (current, next) in zip(keyboardOrder, keyboardOrder.dropFirst()) {
            current.nextKeyView = next
        }
    }

    func updateScratchpadFolder() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let displayedPath = ScratchpadLocation.displayPath(
            LinuxGeneralSettings.scratchpadFolderURL,
            home: URL(fileURLWithPath: home, isDirectory: true))
        scratchpadFolderLabel?.stringValue = displayedPath
        scratchpadDefaultButton.isEnabled =
            LinuxGeneralSettings.configuredScratchpadFolderURL != nil
        needsPresentation = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = openingMessageField(notification.object) else { return }
        scheduleOpeningMessageWrite(for: field)
        needsPresentation = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard openingMessageField(notification.object) != nil else { return }
        finishPendingTextWrites()
    }

    private func openingMessageField(_ object: Any?) -> ThemedTextField? {
        guard let field = object as? ThemedTextField,
              field === newChatOpeningPrefixField || field === newChatOpeningSuffixField
        else { return nil }
        return field
    }

    private func scheduleOpeningMessageWrite(for field: ThemedTextField) {
        if let unsettled = unsettledOpeningMessageField, unsettled !== field {
            finishPendingTextWrites()
        }
        unsettledOpeningMessageField = field
        openingMessageWriteDueAt = ProcessInfo.processInfo.systemUptime
            + NewChatDefaults.textSettingCoalescingInterval
    }

    func finishPendingTextWrites() {
        openingMessageWriteDueAt = nil
        guard let field = unsettledOpeningMessageField else { return }
        unsettledOpeningMessageField = nil
        let typed = field.stringValue
        if field === newChatOpeningPrefixField {
            guard LinuxGeneralSettings.newChatOpeningPrefix != typed else { return }
            LinuxGeneralSettings.newChatOpeningPrefix = typed
            print("SETTINGS_OPENING_CHANGED kind=prefix bytes=\(typed.utf8.count)")
        } else {
            guard LinuxGeneralSettings.newChatOpeningSuffix != typed else { return }
            LinuxGeneralSettings.newChatOpeningSuffix = typed
            print("SETTINGS_OPENING_CHANGED kind=suffix bytes=\(typed.utf8.count)")
        }
        fflush(nil)
    }

    private func rebuildPermissionModePopUp(for kind: AgentKind) {
        permissionModePopUp.removeAllItems()
        for choice in NewChatsSettingsStructure.permissionChoices(for: kind) {
            permissionModePopUp.addItem(ThemedMenuItem(title: choice.title,
                subtitle: choice.subtitle, onChoose: { [weak self] in
                    LinuxGeneralSettings.defaultPermissionMode = choice.mode
                    self?.needsPresentation = true
                    print("SETTINGS_DEFAULT_PERMISSION_CHANGED value=\(choice.mode?.rawValue ?? "inherit")")
                    fflush(nil)
                }))
        }
        let selected = LinuxGeneralSettings.defaultPermissionMode
        let choices = NewChatsSettingsStructure.permissionChoices(for: kind)
        permissionModePopUp.selectItem(at: choices.firstIndex(where: { $0.mode == selected }) ?? 0)
    }

    func setThemeAppearance() {
        root.appearance = LinuxTheme.appearance
        chrome.setThemeAppearance()
        needsPresentation = true
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        // Route committed text, composition and keys to the pane's AppKit responders.
        _ = tw_workspace_composer_mode(window, focused ? 1 : 0)
        chrome.focus(focused, window: window)
        owner.isKeyWindow = focused
        if focused {
            ThemedMenuPresenter.presentationProvider = { [weak self] presentation, source,
                selected, onChoose, onDismiss in
                self?.presentPopup(presentation, from: source, selected: selected,
                    onChoose: onChoose, onDismiss: onDismiss)
            }
            ThemedPopover.presentationProvider = { [weak self] popover, _, source, _ in
                self?.presentHelp(popover, from: source) ?? false
            }
            _ = owner.makeFirstResponder(selectedPage == .general
                ? restoreSessionToggle : defaultAgentPopUp)
            tw_title(window, title)
        } else {
            tw_accessibility_settings_hide(window)
            accessibleViews.removeAll()
            finishPendingTextWrites()
            popupSession?.dismiss()
            helpSession?.popover.close()
            ThemedMenuPresenter.presentationProvider = nil
            ThemedPopover.presentationProvider = nil
            owner.cancelPointerGesture()
            _ = owner.makeFirstResponder(nil)
        }
        syncEditorFocus(window: window)
        needsPresentation = true
    }

    private func syncEditorFocus(window: OpaquePointer) {
        let editing = owner.firstResponder is NSTextView
        _ = tw_workspace_editor_focus(window, editing ? 1 : 0)
    }

    private func isPresentedMenuRow(_ view: NSView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is ThemedMenuSurfaceView { return true }
            ancestor = current.superview
        }
        return false
    }

    private func publishAccessibility(window: OpaquePointer, width: Int, height: Int,
                                      originX: Int) {
        let scale = WorkspaceDisplay.scale
        let contentHeight = max(1, height - WorkspacePaneChrome.headerPixelHeight)
        guard tw_accessibility_settings_begin(window, Int32(originX),
            Int32(WorkspacePaneChrome.headerPixelHeight), Int32(width), Int32(contentHeight)) != 0 else {
            accessibleViews.removeAll(keepingCapacity: true)
            return
        }
        accessibleViews.removeAll(keepingCapacity: true)
        var controlIndex = 0
        var pending: [NSView] = [root]
        while !pending.isEmpty && accessibleViews.count < Self.maximumAccessibleControls {
            let view = pending.removeLast()
            guard !view.isHiddenOrHasHiddenAncestor else { continue }
            pending.append(contentsOf: view.subviews.reversed())
            let role: Int32
            switch view.accessibilityRole() {
            case .button: role = 1
            case .checkBox: role = 2
            case .popUpButton: role = 3
            case .textField: role = 4
            case .menuItem: role = 5
            default: role = 0
            }
            if role != 0, view.isAccessibilityElement() {
                let visible = view.visibleRect
                let clipped = view.convert(visible, to: root).intersection(root.bounds)
                let name = view.accessibilityLabel() ?? view.accessibilityTitle()
                    ?? (view as? NSTextField)?.placeholderString
                if !clipped.isEmpty, let name, !name.isEmpty {
                    let identifier = view.accessibilityIdentifier()
                        ?? "settings.\(selectedPage.rawValue).control.\(controlIndex)"
                    let controlValue = view.accessibilityValue()
                    let value = controlValue.map { String(describing: $0) }
                    let detail = [value, view.accessibilityHelp()].compactMap { $0 }
                        .joined(separator: ". ")
                    let description = String(detail.unicodeScalars.prefix(120))
                    let x = originX + Int((clipped.minX * scale).rounded())
                    let y = height - Int((clipped.maxY * scale).rounded())
                    let w = Int((clipped.width * scale).rounded())
                    let h = Int((clipped.height * scale).rounded())
                    if w > 0, h > 0, identifier.utf8.count < 128,
                       name.utf8.count < 512, description.utf8.count < 512 {
                        let enabled = view.isAccessibilityEnabled() &&
                            (popupSession == nil || isPresentedMenuRow(view))
                        let checked = (controlValue as? Bool) == true
                        let isFocused = owner.firstResponder === view ||
                            (view as? NSTextField)?.currentEditor() === owner.firstResponder
                        let inserted = identifier.withCString { id in
                            name.withCString { label in
                                description.withCString { summary in
                                    tw_accessibility_settings_add(window, id, label, summary,
                                        role, enabled ? 1 : 0, checked ? 1 : 0,
                                        isFocused ? 1 : 0,
                                        Int32(x), Int32(y), Int32(w), Int32(h))
                                }
                            }
                        }
                        if inserted != 0 { accessibleViews[identifier] = view }
                    }
                    controlIndex += 1
                }
            }
        }
        tw_accessibility_settings_end(window)
    }

    func pressAccessibleControl(id: String, window: OpaquePointer) -> Bool {
        guard let view = accessibleViews[id], view.window === owner,
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
              view.isAccessibilityEnabled() else { return false }
        guard popupSession == nil || isPresentedMenuRow(view) else { return false }
        if view.accessibilityRole() == .textField {
            let frame = view.convert(view.bounds, to: root)
            let point = NSPoint(x: frame.midX, y: frame.midY)
            _ = owner.dispatchToContent(NSEvent(type: .leftMouseDown, locationInWindow: point))
            _ = owner.dispatchToContent(NSEvent(type: .leftMouseUp, locationInWindow: point))
            syncEditorFocus(window: window)
            needsPresentation = true
            return true
        }
        let pressed = view.accessibilityPerformPress()
        if pressed { needsPresentation = true }
        return pressed
    }

    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int,
                 focused: Bool) throws {
        if let due = openingMessageWriteDueAt,
           ProcessInfo.processInfo.systemUptime >= due {
            finishPendingTextWrites()
        }
        try chrome.refresh(window: window, width: width, height: height, originX: originX)
        let contentHeight = max(1, height - WorkspacePaneChrome.headerPixelHeight)
        let scale = WorkspaceDisplay.scale
        let size = NSSize(width: CGFloat(width) / scale,
                          height: CGFloat(contentHeight) / scale)
        guard needsPresentation || size != presentedSize ||
                displayRevision != owner.displayRevision else { return }
        root.frame = NSRect(origin: .zero, size: size)
        owner.layoutIfNeeded()
        popupSession?.reposition(in: root)
        helpSession?.reposition()
        if focused { publishAccessibility(window: window, width: width, height: height,
                                          originX: originX) }
        let bitmap = Bitmap(width: width, height: contentHeight,
                            background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_pane(window, $0.baseAddress, Int32(width), Int32(contentHeight), 0)
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        if focused { tw_title(window, title) }
        print("SETTINGS_FRAME \(width)x\(contentHeight) controls=\(toggles.count) "
            + "popup=\(popupSession != nil) help=\(helpSession != nil) "
            + "choice=\(popupFixture?.indexOfSelectedItem ?? -1)")
        if pageSelectors.indices.contains(selectedPage.rawValue) {
            let selector = pageSelectors[selectedPage.rawValue]
            let anchor = selector.convert(selector.bounds, to: root)
            print("SETTINGS_PAGE_ANCHOR value=\(selectedPage.title) x=\(anchor.minX) "
                + "y=\(anchor.minY) width=\(anchor.width) height=\(anchor.height)")
        }
        let restoreAnchor = restoreSessionToggle.convert(restoreSessionToggle.bounds, to: root)
        print("SETTINGS_RESTORE_ANCHOR x=\(restoreAnchor.minX) y=\(restoreAnchor.minY) "
            + "width=\(restoreAnchor.width) height=\(restoreAnchor.height)")
        let policyAnchor = restorePolicyPopUp.convert(restorePolicyPopUp.bounds, to: root)
        print("SETTINGS_POLICY_ANCHOR x=\(policyAnchor.minX) y=\(policyAnchor.minY) "
            + "width=\(policyAnchor.width) height=\(policyAnchor.height)")
        let windowAnchor = restoreWindowPopUp.convert(restoreWindowPopUp.bounds, to: root)
        print("SETTINGS_IDLE_WINDOW_ANCHOR x=\(windowAnchor.minX) y=\(windowAnchor.minY) "
            + "width=\(windowAnchor.width) height=\(windowAnchor.height)")
        let limitAnchor = restoreLimitPopUp.convert(restoreLimitPopUp.bounds, to: root)
        print("SETTINGS_IDLE_LIMIT_ANCHOR x=\(limitAnchor.minX) y=\(limitAnchor.minY) "
            + "width=\(limitAnchor.width) height=\(limitAnchor.height)")
        if selectedPage == .chats {
            for (name, popup) in [("agent", defaultAgentPopUp),
                                  ("permission", permissionModePopUp)] {
                let anchor = popup.convert(popup.bounds, to: root)
                print("SETTINGS_NEW_CHAT_ANCHOR kind=\(name) x=\(anchor.minX) y=\(anchor.minY) "
                    + "width=\(anchor.width) height=\(anchor.height)")
            }
            for (kind, popup) in [("claude", claudeStartupSpeedPopUp),
                                  ("codex", codexStartupSpeedPopUp)] {
                let anchor = popup.convert(popup.bounds, to: root)
                print("SETTINGS_SPEED_ANCHOR kind=\(kind) x=\(anchor.minX) y=\(anchor.minY) "
                    + "width=\(anchor.width) height=\(anchor.height)")
            }
            for (kind, field) in [("prefix", newChatOpeningPrefixField),
                                  ("suffix", newChatOpeningSuffixField)] {
                let anchor = field.convert(field.bounds, to: root)
                print("SETTINGS_OPENING_ANCHOR kind=\(kind) x=\(anchor.minX) y=\(anchor.minY) "
                    + "width=\(anchor.width) height=\(anchor.height)")
            }
            var helpButtons = newChatsHelpButtons.enumerated().map {
                ("new-chat-\($0.offset)", $0.element)
            }
            if let openingMessageHelpButton {
                helpButtons.append(("opening-message", openingMessageHelpButton))
            }
            for (kind, button) in helpButtons {
                let anchor = button.convert(button.bounds, to: root)
                print("SETTINGS_CHAT_HELP_ANCHOR kind=\(kind) x=\(anchor.minX) "
                    + "y=\(anchor.minY) width=\(anchor.width) height=\(anchor.height)")
            }
            for (kind, button) in [("choose", scratchpadChooseButton),
                                   ("default", scratchpadDefaultButton)] {
                let anchor = button.convert(button.bounds, to: root)
                print("SETTINGS_SCRATCHPAD_ANCHOR kind=\(kind) x=\(anchor.minX) y=\(anchor.minY) "
                    + "width=\(anchor.width) height=\(anchor.height)")
            }
            if let scratchpadHelpButton {
                let anchor = scratchpadHelpButton.convert(scratchpadHelpButton.bounds, to: root)
                print("SETTINGS_SCRATCHPAD_ANCHOR kind=help x=\(anchor.minX) y=\(anchor.minY) "
                    + "width=\(anchor.width) height=\(anchor.height)")
            }
        }
        if let popupFixture {
            let anchor = popupFixture.convert(popupFixture.bounds, to: root)
            print("SETTINGS_POPUP_ANCHOR x=\(anchor.minX) y=\(anchor.minY) width=\(anchor.width) height=\(anchor.height)")
        }
        fflush(nil)
        presentedSize = size
        displayRevision = owner.displayRevision
        needsPresentation = false
    }

    func handle(_ input: TWEvent, window: OpaquePointer) {
        if input.kind == 46 || input.kind == 47 {
            var textEvent = input
            guard let text = String(validatingCString: tw_event_text(&textEvent)),
                  let editor = owner.firstResponder as? NSTextView else { return }
            if input.kind == 46 {
                editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                let lengths = text.unicodeScalars.map { String($0).utf16.count }
                let start = min(max(0, Int(input.textCursor)), lengths.count)
                let end = min(start + max(0, Int(input.textSelectionLength)), lengths.count)
                editor.setMarkedText(text, selectedRange: NSRange(
                    location: lengths.prefix(start).reduce(0, +),
                    length: lengths[start..<end].reduce(0, +)),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            needsPresentation = true
            return
        }
        if input.kind == 7 || input.kind == 48 {
            guard input.action != 3 else { return }
            let key = WindowHarness.composerKeyEvent(input)
            if let popupSession {
                switch key.keyCode {
                case 53: popupSession.dismiss(); needsPresentation = true; return
                case 126: popupSession.move(-1); needsPresentation = true; return
                case 125: popupSession.move(1); needsPresentation = true; return
                case 36, 49: popupSession.chooseHighlighted(); needsPresentation = true; return
                default: break
                }
            }
            if let helpSession, key.keyCode == 53 {
                helpSession.popover.close()
                needsPresentation = true
                return
            }
            if key.keyCode == 48 {
                popupSession?.dismiss()
                helpSession?.popover.close()
                if owner.firstResponder is NSTextView {
                    _ = owner.dispatchToContent(key)
                } else {
                    let current = owner.firstResponder as? NSView
                    let next = input.modifiers & 1 != 0
                        ? current?.previousValidKeyView : current?.nextValidKeyView
                    if let next { _ = owner.makeFirstResponder(next) }
                }
            } else {
                _ = owner.dispatchToContent(key)
            }
            syncEditorFocus(window: window)
            needsPresentation = true
            return
        }
        let type: NSEvent.EventType
        switch input.kind {
        case 15 where input.key == 0:
            type = input.action == 1 ? .leftMouseDown : .leftMouseUp
        case 17: type = .leftMouseDragged
        case 16: type = .scrollWheel
        default: return
        }
        let scale = WorkspaceDisplay.scale
        let pointer = NSEvent(type: type, locationInWindow: NSPoint(
            x: CGFloat(input.x) / scale,
            y: root.bounds.height - CGFloat(input.y) / scale),
            scrollingDeltaY: CGFloat(input.key))
        if type == .leftMouseDown, let popupSession,
           !popupSession.frame.contains(pointer.locationInWindow) {
            popupSession.dismiss()
            needsPresentation = true
            return
        }
        if type == .leftMouseDown, let helpSession,
           !helpSession.frame.contains(pointer.locationInWindow) {
            helpSession.popover.close()
            needsPresentation = true
            return
        }
        _ = owner.dispatchToContent(pointer)
        syncEditorFocus(window: window)
        needsPresentation = true
    }
}

#endif
