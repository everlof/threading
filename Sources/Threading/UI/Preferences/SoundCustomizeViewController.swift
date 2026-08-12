import AppKit

// MARK: - Sound Customize Sheet

/// A sound per event, for one scope — the per-event tier behind *Customize…*.
///
/// One sheet, identical at every scope, because the model is: a chat, a checkout, a standalone
/// terminal and the app itself all answer the same nine questions, and only *what they inherit*
/// differs. Building a second surface for the app scope would be building a second place for the
/// same nine rows to drift apart in.
///
/// Two things here are load-bearing and neither is visible in a screenshot:
///
/// - **The *Inherit* parenthetical names what the row would read with nothing of its own.** It
///   is `SoundResolution.inherited`, once, for both the label and the writer — see `apply`.
/// - **A row set to exactly what it inherits stores nothing.** The mute writer's rule, at every
///   level rather than only the base coat: storing the matching value is what would stop a later
///   change to the project from reaching the chat.
///
/// The form is fixed — two kinds and nine events, from a closed enum — so it is a retained stack
/// rather than a virtualized list. The Scaling Gate's exemption for a small fixed form is exactly
/// this case; nothing here is sized by data.
@MainActor
final class SoundCustomizeViewController: NSViewController {

    // MARK: - Model

    /// One group of the sheet: a kind, its own row, and the events under it.
    private struct Group {
        let kind: SoundEvent.Kind
        let events: [SoundEvent]

        /// The kind row's own label. Written out per case rather than composed, so the two
        /// strings are literals the localization boundary can see.
        var kindTitle: String {
            switch kind {
            case .bell: return L10n.string("All bells")
            case .alert: return L10n.string("All notifications")
            }
        }
    }

    /// One picker and the level it writes.
    private struct Row {
        let level: SoundResolution.Level
        let popUp: ThemedPopUp
    }

    /// What a picker's item carries. *Inherit* is a value here rather than an absent one so the
    /// handler needs no sentinel to tell it apart from a sound named something.
    private enum RowChoice {
        case inherited
        case set(SoundChoice)
    }

    // MARK: - Properties

    private let scope: SoundScope
    private let store: ProjectStore

    /// Called when the sheet is done, however it was closed.
    var onDone: (() -> Void)?

    private var rows: [Row] = []
    private let resetButton = ThemedButton()
    private let doneButton = ThemedButton()
    private let failureNote = NSTextField(labelWithString: "")

    /// The two groups, in the order the mock reads them: what a program does, then what
    /// Threading noticed on your behalf.
    private static let groups: [Group] = [
        Group(
            kind: .bell,
            events: [.bellAgentAsking, .bellAgentVisible, .bellLaunch, .bellOtherProgram]
        ),
        Group(
            kind: .alert,
            events: [
                .alertBlocked, .alertUnread, .alertFinished, .alertRequestedUpdate,
                .alertScheduledMessage
            ]
        )
    ]

    // MARK: - Initialization

    init(scope: SoundScope, store: ProjectStore = .shared) {
        self.scope = scope
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the sheet over whoever asked for it.
    ///
    /// Static because three surfaces reach it — a chat's menu, a checkout's menu, and both
    /// Settings cards — and each of them owns a different presenter.
    static func present(_ scope: SoundScope, from presenter: NSViewController) {
        let sheet = SoundCustomizeViewController(scope: scope)
        sheet.onDone = { [weak presenter, weak sheet] in
            guard let presenter, let sheet else { return }
            presenter.dismiss(sheet)
        }
        presenter.presentAsSheet(sheet)
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(
            x: 0, y: 0,
            width: SoundCustomizeLayout.sheetWidth,
            height: SoundCustomizeLayout.sheetHeight
        ))
        setupViews()

        // Sized to its content, for the reason the report sheets are: slack in a stack pinned
        // top and bottom becomes gaps between the cards.
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(NSSize(
            width: SoundCustomizeLayout.sheetWidth,
            height: view.fittingSize.height
        ))
    }

    // MARK: - Setup

    private func setupViews() {
        view.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )

        let headingLabel = SettingsUI.heading(sheetTitle, localizes: false)

        let subheadingLabel = NSTextField(wrappingLabelWithString: summary)
        subheadingLabel.applyFont(.subheading)
        subheadingLabel.textColor = Design.Text.secondary
        subheadingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        failureNote.applyFont(.subheading)
        failureNote.textColor = Design.Text.secondary
        failureNote.isHidden = true
        failureNote.setAccessibilityIdentifier(SoundCustomizeIdentifiers.failure)

        let footnote = SettingsUI.note(SoundCustomizeStrings.footnote, localizes: false)
        let content: [NSView] = [
            headings,
            SettingsUI.section("Terminal Bell", card(for: Self.groups[0])),
            SettingsUI.section("Notifications", card(for: Self.groups[1])),
            footnote,
            failureNote,
            makeFooter()
        ]

        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        // The footnote belongs to the group above it rather than to the footer below.
        stack.setCustomSpacing(Design.Spacing.medium, after: footnote)
        stack.setCustomSpacing(Design.Spacing.medium, after: failureNote)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            stack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.pane
            )
        ])

        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        refresh()
    }

    /// One group: the kind's own row, then one row per event under it.
    ///
    /// The kind row sits *inside* the card rather than beside the caption, which is where the
    /// mock draws it. A caption in this app is a quiet label above a card and carries no
    /// controls; making it carry one would be inventing a second kind of section header for the
    /// sake of one screen.
    private func card(for group: Group) -> SettingsCard {
        var views: [NSView] = [row(for: .kind(group.kind), title: group.kindTitle)]
        for event in group.events {
            views.append(row(for: .event(event), title: SoundCustomizeStrings.title(of: event)))
        }
        return SettingsCard(rows: views)
    }

    private func row(for level: SoundResolution.Level, title: String) -> NSView {
        let popUp = SettingsUI.popUp(target: self, action: #selector(rowChoiceChanged(_:)))
        popUp.tag = rows.count
        popUp.setAccessibilityIdentifier(SoundCustomizeIdentifiers.picker(for: level))
        popUp.setAccessibilityLabel(title)
        rows.append(Row(level: level, popUp: popUp))
        return SettingsUI.row(title: title, control: popUp, localizes: false)
    }

    /// *Reset All* leading, *Done* trailing. The reset is on the far side of the footer from the
    /// button people press to leave, because it is the one control here that discards something.
    private func makeFooter() -> NSView {
        resetButton.title = SoundCustomizeStrings.resetTitle(at: scope)
        resetButton.target = self
        resetButton.action = #selector(resetAll)
        resetButton.setAccessibilityIdentifier(SoundCustomizeIdentifiers.reset)

        doneButton.title = L10n.string("Done")
        doneButton.isProminent = true
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityIdentifier(SoundCustomizeIdentifiers.done)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [resetButton, spacer, doneButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small
        return footer
    }

    // MARK: - Presentation

    /// Names the scope, because the same nine rows mean different things over different records
    /// and a sheet that did not say which one it was editing would be the easiest mistake in
    /// this feature to make.
    var sheetTitle: String {
        guard let name = scopeName else { return L10n.string("Sounds") }
        return L10n.format("Sounds — %@", name)
    }

    private var scopeName: String? {
        switch scope {
        case .app:
            return nil
        case .project(let projectID):
            return store.project(withID: projectID)?.name
        case .session(let sessionID):
            return store.session(withID: sessionID)?.displayTitle
        case .terminal(let terminalID):
            return store.terminal(withID: terminalID)?.displayTitle
        }
    }

    /// One line saying who follows this scope, so *Inherit* is not the only place the chain is
    /// explained.
    private var summary: String {
        switch scope {
        case .app:
            return L10n.string(
                "What every chat, checkout and terminal starts from. Anything that has answered "
                    + "for itself keeps its own answer."
            )
        case .project:
            return L10n.string(
                "This checkout's chats and terminals follow these unless they answer for "
                    + "themselves."
            )
        case .session:
            return L10n.string(
                "This conversation only. Anything left inheriting follows its checkout, then "
                    + "the app."
            )
        case .terminal:
            return L10n.string(
                "This terminal only. It keeps no record of why a bell rang, so the bell rows "
                    + "below apply to every bell it makes."
            )
        }
    }

    // MARK: - Refresh

    /// Rebuilds every picker.
    ///
    /// Every row, not only the one that changed: a kind row moves what its four or five event
    /// rows inherit, and *Reset All* moves all eleven at once. Eleven rebuilds share one reading
    /// of the sounds folders — see `SoundPickerMenu.addSounds` — so the pass is one directory
    /// scan on a click rather than eleven.
    private func refresh() {
        let groups = SoundPickerMenu.groups()
        for row in rows { rebuild(row, groups: groups) }
    }

    private func rebuild(_ row: Row, groups: [[NotificationSound]]) {
        let popUp = row.popUp
        popUp.removeAllItems()

        var inheritIndex: Int?
        if offersInherit(row.level) {
            popUp.addItem(ThemedMenuItem(
                title: inheritTitle(for: row.level),
                representedValue: RowChoice.inherited
            ))
            inheritIndex = popUp.numberOfItems - 1
            popUp.addSeparator()
        }

        var indexOfChoice: [SoundChoice: Int] = [:]
        for (title, value) in [
            (L10n.string("Off"), SoundChoice.silent),
            (L10n.string("macOS Alert Sound"), SoundChoice.system)
        ] {
            popUp.addItem(ThemedMenuItem(title: title, representedValue: RowChoice.set(value)))
            indexOfChoice[value] = popUp.numberOfItems - 1
        }

        let indexOfSound = SoundPickerMenu.addSounds(to: popUp, groups: groups) {
            RowChoice.set(.named($0))
        }

        SoundPickerMenu.addCustomSoundItem(to: popUp) { [weak self] in
            // Choosing an item moves the selection onto it, and this one is a door rather than
            // a choice. Put the control back before the panel opens over the sheet: nothing has
            // been chosen yet, and the row would otherwise read as if it had.
            self?.refresh()
            self?.addSound(for: row.level)
        }

        // A stored name whose file has gone shows as the system sound, because that is what it
        // will sound like — both players fall back the same way, and a picker naming a sound
        // nobody will hear would be the one lie on the sheet.
        let fallback = inheritIndex ?? indexOfChoice[.system] ?? 0
        switch scope.choice(forKey: row.level.storageKey) {
        case .none:
            popUp.selectItem(at: fallback)
        case .some(.named(let fileName)):
            popUp.selectItem(at: indexOfSound[fileName] ?? indexOfChoice[.system] ?? fallback)
        case .some(let choice):
            popUp.selectItem(at: indexOfChoice[choice] ?? fallback)
        }
    }

    /// Whether this row has an outermost item at all.
    ///
    /// Every row does except the app scope's two kind rows: those **are** the pickers on the
    /// General page — the same two preferences, read and written here — and there is nothing
    /// beyond them to fall back to. Their *macOS Alert Sound* item is the default, so a *Default
    /// (…)* item above it would be a second way to choose the item below it.
    private func offersInherit(_ level: SoundResolution.Level) -> Bool {
        if case .kind = level, scope == .app { return false }
        return true
    }

    /// *Inherit (Basso)* — or *Default (Basso)* at the app scope, which is the word the theme
    /// scope already uses for the same position and the reason sounds do not invent a third.
    private func inheritTitle(for level: SoundResolution.Level) -> String {
        let name = SoundMenuNames.inheritedName(of: scope.inherited(level))
        return scope == .app
            ? L10n.format("Default (%@)", name)
            : L10n.format("Inherit (%@)", name)
    }

    // MARK: - Actions

    @objc private func rowChoiceChanged(_ sender: ThemedPopUp) {
        guard rows.indices.contains(sender.tag),
              let choice = sender.selectedItem?.representedValue as? RowChoice else { return }
        apply(choice, to: rows[sender.tag])
    }

    /// Writes one row, **nil where the value matches what the row would have inherited**.
    ///
    /// The same expression names the *Inherit* item, so the label and the writer cannot disagree
    /// about what inherited means. Choosing *Inherit* clears the entry by the same line — nil
    /// equals nil.
    private func apply(_ choice: RowChoice, to row: Row) {
        let chosen: SoundChoice?
        switch choice {
        case .inherited: chosen = nil
        case .set(let value): chosen = value
        }

        let stored = chosen == scope.inherited(row.level) ? nil : chosen
        guard scope.setChoice(stored, forKey: row.level.storageKey) else {
            showFailure()
            refresh()
            return
        }

        hideFailure()
        preview(chosen)
        refresh()
    }

    /// Clears every entry at this scope, and stays open showing the result — the reset is
    /// visible rather than a dialog's word for it.
    @objc func resetAll() {
        guard scope.resetAll() else {
            showFailure()
            refresh()
            return
        }
        hideFailure()
        refresh()
    }

    @objc private func done() {
        onDone?()
    }

    /// Choosing a sound plays it, the way every alert-sound list does: a name is not a sound.
    ///
    /// The two reserved answers stay quiet, exactly as the settings pickers and the submenu
    /// leave them — macOS's notification tone is not a file any name resolves to, and *Off*
    /// previews as silence, which is the honest answer. *Inherit* previews nothing because it
    /// chooses nothing.
    private func preview(_ choice: SoundChoice?) {
        guard case .named(let fileName) = choice,
              let sound = NotificationSoundLibrary.resolve(fileName: fileName) else { return }
        NotificationSoundPreview.play(sound)
    }

    /// Copies a chosen file into `~/Library/Sounds` and gives this row that sound.
    private func addSound(for level: SoundResolution.Level) {
        SoundPickerMenu.addCustomSound { [weak self] sound in
            guard let self, let sound else { return }
            guard let row = self.rows.first(where: { $0.level == level }) else { return }
            self.apply(.set(.named(sound.fileName)), to: row)
        }
    }

    // MARK: - Private Methods

    private func showFailure() {
        failureNote.stringValue = L10n.string("The project data could not be saved.")
        failureNote.isHidden = false
    }

    private func hideFailure() {
        guard !failureNote.isHidden else { return }
        failureNote.isHidden = true
    }

    // MARK: - Testing Seams

    /// What one row's picker is showing, for a test that cannot open a menu.
    func selectedTitle(for level: SoundResolution.Level) -> String? {
        rows.first { $0.level == level }?.popUp.selectedItem?.title
    }

    /// Drives one row the way a click on its item would, including the writer behind it.
    func choose(_ choice: SoundChoice?, for level: SoundResolution.Level) {
        guard let row = rows.first(where: { $0.level == level }) else { return }
        apply(choice.map(RowChoice.set) ?? .inherited, to: row)
    }
}

// MARK: - Layout

enum SoundCustomizeLayout {
    /// Wide enough for the longest event label beside a picker: "Finished or asked while you
    /// were away" is the one that sets it.
    static let sheetWidth: CGFloat = 620

    /// A starting height only — `loadView` shrinks the sheet to what its content asked for.
    static let sheetHeight: CGFloat = 720
}

enum SoundCustomizeIdentifiers {
    static let reset = "sounds.customize.reset"
    static let done = "sounds.customize.done"
    static let failure = "sounds.customize.failure"

    static func picker(for level: SoundResolution.Level) -> String {
        "sounds.customize.\(level.storageKey)"
    }
}

// MARK: - Strings

enum SoundCustomizeStrings {

    /// The nine events in the words the sheet names them by.
    ///
    /// Here rather than on `SoundEvent` because the raw values are a **stored** wire format and
    /// these are copy: one is renamed when the wording improves, the other can never be renamed
    /// at all.
    static func title(of event: SoundEvent) -> String {
        switch event {
        case .bellAgentAsking:
            return L10n.string("The agent rings while you're away")
        case .bellAgentVisible:
            return L10n.string("Rings while you're watching")
        case .bellLaunch:
            return L10n.string("Rings during a launch")
        case .bellOtherProgram:
            return L10n.string("Another program rings")
        case .alertBlocked:
            return L10n.string("Blocked on an approval")
        case .alertUnread:
            return L10n.string("Finished or asked while you were away")
        case .alertFinished:
            return L10n.string("Finished in the background")
        case .alertRequestedUpdate:
            return L10n.string("The agent sends an update")
        case .alertScheduledMessage:
            return L10n.string("A scheduled message went out")
        }
    }

    /// The opt-in rule, said once where its consequence is on screen: three rows read *Silent*
    /// no matter what the group above them says.
    static var footnote: String {
        L10n.string(
            "Events shown as Silent make no sound anywhere unless given one here — the group "
                + "and one-click choices never turn them on."
        )
    }

    /// *Inherited* everywhere but the app, which has nothing to inherit from.
    static func resetTitle(at scope: SoundScope) -> String {
        scope == .app
            ? L10n.string("Reset All to Default")
            : L10n.string("Reset All to Inherited")
    }
}
