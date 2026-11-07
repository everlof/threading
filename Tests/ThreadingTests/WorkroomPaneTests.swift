import AppKit
import ThreadingController
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The chat's Workroom pane: what it says, what its controls ask for, what survives a refresh,
/// what it looks like, and the words its feed reads out of real workroom records.
@MainActor
final class WorkroomPaneTests: HostedStoreTestCase {

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
        /// The display panel's narrowest useful width, beside a chat on a laptop.
        static let narrow: CGFloat = 300
        static let width: CGFloat = 380
        static let height: CGFloat = 560
    }

    /// The windows of this test's panes, kept until the test ends so their layout holds.
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        AppThemePalette.set(.system)
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - The overview

    func testAChatWithoutAWorkroomSaysHowToGetOne() {
        let (pane, _) = mounted(WorkroomPanePresentation(chatTitle: "MOMS"))
        XCTAssertTrue(texts(in: pane).contains { $0.hasPrefix(String(L10n.string(
            "This chat has no workroom yet. Ask the agent to create one, for example “Make a workroom and ask our accountant how VAT is rounded.” Nobody outside this Mac sees anything until you approve opening it."
        ).prefix(20))) })
        XCTAssertTrue(texts(in: pane).contains("MOMS"), "the pane does not say which chat it is about")
    }

    func testPeopleCarryTheirInvitationAndOnlyAnOpenRoomCloses() throws {
        var actions: [WorkroomPaneAction] = []
        let (pane, _) = mounted(Self.overview)
        pane.onAction = { actions.append($0) }

        let buttons = pane.view.workroomDescendants(ofType: ThemedButton.self)
        let invites = buttons.filter { $0.title == L10n.string("Invite to App…") }
        XCTAssertEqual(invites.count, 1, "the owner was offered an invitation, or Viktor was not")
        XCTAssertEqual(invites.first?.toolTip, L10n.format("Invite %@ to the Threading app", "Viktor"))
        let inviteRow = try XCTUnwrap(pane.rows.first { invites.first?.isDescendant(of: $0) == true })
        XCTAssertEqual(inviteRow.accessibilityLabel(), "Viktor, Not in the app yet", "VoiceOver cannot tell whose invitation it is")
        let closes = buttons.filter { $0.title == L10n.string("Close") }
        XCTAssertEqual(closes.count, 1, "a closed room offered Close")
        XCTAssertEqual(closes.first?.toolTip, L10n.format("Close “%@” to everyone", "Sonda: beslut"))

        XCTAssertTrue(try XCTUnwrap(invites.first).performPrimaryAction())
        XCTAssertTrue(try XCTUnwrap(closes.first).performPrimaryAction())
        let settings = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == WorkroomPaneIdentifiers.settings })
        XCTAssertTrue(settings.performPrimaryAction())
        XCTAssertEqual(actions, [.inviteToApp(person: "viktor-id"), .closeRoom("open-room"), .openSettings])
    }

    func testAQuestionOpensItsConversationAndTheWayBack() throws {
        var actions: [WorkroomPaneAction] = []
        let (pane, _) = mounted(Self.overview)
        pane.onAction = { actions.append($0) }

        let row = try XCTUnwrap(pane.view.workroomDescendants(ofType: SearchResultRowView.self).first)
        XCTAssertEqual(row.accessibilityTitle(), "Hur avrundas momsen? — Viktor · Answered")
        XCTAssertTrue(row.performPrimaryAction())
        XCTAssertEqual(actions, [.openQuestion("q1")])

        pane.apply(Self.conversation())
        let shown = texts(in: pane)
        XCTAssertTrue(shown.contains("Stämmer det? Ja"), "the answer's choice is missing")
        XCTAssertTrue(shown.contains("Avrunda per rad."), "the answer's comment is missing")
        XCTAssertTrue(shown.contains("Viktor svarade · 7 nov. 2026 14:20"))
        let back = try XCTUnwrap(pane.view.workroomDescendants(ofType: ThemedButton.self)
            .first { $0.accessibilityIdentifier() == WorkroomPaneIdentifiers.back })
        XCTAssertTrue(back.performPrimaryAction())
        XCTAssertEqual(actions, [.openQuestion("q1"), .showQuestions])
    }

    /// A reading that changed nothing is not drawn again: the rows on screen are the same views,
    /// so a scroll position, a hover and a selection in them survive the refresh.
    func testARefreshThatChangedNothingKeepsTheRows() {
        let (pane, _) = mounted(Self.overview)
        let before = pane.rows.map(ObjectIdentifier.init)
        pane.apply(Self.overview)
        XCTAssertEqual(pane.rows.map(ObjectIdentifier.init), before)
    }

    // MARK: - Commenting

    func testTheCommentBeingWrittenSurvivesANewEntryAndIsSentTrimmed() throws {
        var actions: [WorkroomPaneAction] = []
        let (pane, _) = mounted(Self.conversation())
        pane.onAction = { actions.append($0) }
        let composer = try XCTUnwrap(pane.view.workroomDescendants(ofType: PromptView.self).first)
        composer.stringValue = "Kolla bilagan"

        // Viktor writes while the owner is typing: the conversation grows, the draft stays.
        pane.apply(Self.conversation(extra: true))
        XCTAssertTrue(pane.view.workroomDescendants(ofType: PromptView.self).first === composer)
        XCTAssertEqual(composer.stringValue, "Kolla bilagan")
        XCTAssertTrue(texts(in: pane).contains("En sak till."))

        composer.onSubmit?("  Kolla bilagan \n")
        XCTAssertEqual(actions, [.comment(question: "q1", text: "Kolla bilagan")])
        XCTAssertFalse(composer.isSubmissionEnabled, "a second Return could send it twice")
        pane.commentDidFail()
        XCTAssertEqual(composer.stringValue, "Kolla bilagan", "a failed comment lost what was written")
        XCTAssertTrue(composer.isSubmissionEnabled)
        pane.commentDidSend()
        XCTAssertEqual(composer.stringValue, "")

        // A different question starts with an empty composer.
        composer.stringValue = "Till fel fråga"
        pane.apply(Self.conversation(id: "q2"))
        XCTAssertEqual(composer.stringValue, "")
    }

    func testAQuestionThatTakesNoCommentHasNoComposer() {
        var closed = Self.conversation()
        closed.detail = WorkroomPanePresentation.Detail(
            id: "q1", title: "Hur avrundas momsen?", status: "Sonda · Viktor · Declined", prompt: "",
            entries: [], commentReaders: nil)
        let (pane, _) = mounted(closed)
        XCTAssertTrue(pane.view.workroomDescendants(ofType: PromptView.self).isEmpty)
        XCTAssertTrue(texts(in: pane).contains(L10n.string("No answer yet.")))
    }

    // MARK: - Layout and rendering

    /// The verbs stay inside their row in a narrow panel in every stock theme: the words before
    /// them give way first. Measured against the row rather than the pane, because where the
    /// list's own scroller sits is the list's business — a leading legacy scroller moves the
    /// whole document over — and this is about the row not pushing its own buttons out.
    func testTheVerbsFitANarrowPaneInEveryStockTheme() throws {
        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)
            let (pane, _) = mounted(Self.overview, width: Render.narrow)
            AppThemeRefresh.repaint(pane.view)
            pane.view.layoutSubtreeIfNeeded()
            for button in pane.view.workroomDescendants(ofType: ThemedButton.self) {
                let container = pane.rows.first { button.isDescendant(of: $0) } ?? pane.view
                let frame = button.convert(button.bounds, to: container)
                XCTAssertLessThanOrEqual(frame.maxX, container.bounds.width + 0.5, "\(theme.name): \(button.title)")
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(theme.name): \(button.title)")
                XCTAssertGreaterThanOrEqual(frame.width, button.intrinsicContentSize.width - 0.5,
                                            "\(theme.name): \(button.title) was squeezed")
            }
        }
    }

    func testRendersTheOverviewAndAConversationLightAndDark() throws {
        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        for theme in [AppTheme.system, AppThemeStyles.cyberpunk] {
            AppThemePalette.set(theme)
            for (name, presentation) in [("overview", Self.overview), ("conversation", Self.conversation(extra: true))] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let (pane, _) = mounted(presentation)
                    let image = try XCTUnwrap(rendered(pane, appearance: appearance))
                    let url = Render.directory.appendingPathComponent(
                        "workroom-pane-\(name)-\(theme.id.rawValue)-\(appearance == .aqua ? "light" : "dark").png")
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
                }
            }
        }
    }

    /// A pane already on screen follows a theme switch: the same views, drawn in the new roles.
    func testAPaneOnScreenFollowsAThemeSwitch() throws {
        let (pane, _) = mounted(Self.overview)
        let before = try XCTUnwrap(rendered(pane, appearance: .darkAqua)?.representation(using: .png, properties: [:]))
        let rows = pane.rows.map(ObjectIdentifier.init)
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))
        AppThemeRefresh.repaint(pane.view)
        let after = try XCTUnwrap(rendered(pane, appearance: .darkAqua)?.representation(using: .png, properties: [:]))
        XCTAssertNotEqual(before, after, "the pane kept the colours it was built in")
        XCTAssertEqual(pane.rows.map(ObjectIdentifier.init), rows, "a theme switch rebuilt the pane")
    }

    // MARK: - The tab

    func testTheTabIsOnePerChatStaysInThePanelAndIsNeverSaved() throws {
        let sessionID = SessionID()
        let panel = DisplayPaneController()
        let first = try XCTUnwrap(panel.activateWorkroom(for: sessionID))
        XCTAssertTrue(panel.activateWorkroom(for: sessionID) === first)
        let tab = try XCTUnwrap(panel.tabs(for: sessionID).first { $0.workroom != nil })
        XCTAssertEqual(panel.tabs(for: sessionID).filter { $0.workroom != nil }.count, 1)
        XCTAssertFalse(tab.canLiveInDetachedWindow)
        XCTAssertEqual(tab.title, L10n.string("Workroom"))

        panel.addContentTab(DisplayContent(body: .html("<p>plan</p>"), title: "Plan", subtitle: ""), for: sessionID)
        let layout = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: sessionID))
        XCTAssertEqual(layout.panelTabs.map(\.kind), [.html], "the Workroom tab reached the saved layout")
    }

    func testTheCommandIsInThePlusMenu() {
        let entry = PanelCommands.entries.first { $0.target == .workroom }
        XCTAssertEqual(entry?.id, "panel.workroom")
        XCTAssertTrue(AppCommands.all.contains { $0.id == "panel.workroom" && $0.scope == .session })
    }

    // MARK: - The feed's words

    func testARoomSaysWhetherItIsReachableAndWhatWaits() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let open = WorkroomPaneFeed.roomStatus(try await fixture.store.workroomSummary(fixture.room))
        XCTAssertEqual(open, [L10n.string("Open with no end date"), L10n.format("Open questions: %d", 1)]
            .joined(separator: WorkroomPaneFeedDefaults.separator))
        _ = try await fixture.store.closeWorkroom(fixture.room)
        let closed = WorkroomPaneFeed.roomStatus(try await fixture.store.workroomSummary(fixture.room))
        XCTAssertEqual(closed, [L10n.string("Closed"), L10n.format("Open questions: %d", 1)]
            .joined(separator: WorkroomPaneFeedDefaults.separator))
    }

    func testTheConversationReadsAsTheOwnerSeesIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let (store, person, question) = (fixture.store, fixture.person, fixture.question)
        _ = try await store.participantAnswer(person: person.id, id: question.id,
                                              answers: [WorkroomFieldAnswer(field: "ok", values: [WorkroomYesNo.yes.rawValue])],
                                              comment: "Per rad.")
        _ = try await store.ownerCommentOnWorkroomQuestion(question.id, ownerName: "David", text: "Tack.")

        let detail = WorkroomPaneFeed.detail(try await store.workroomQuestionDetail(question.id))
        XCTAssertEqual(detail.id, question.id.description)
        XCTAssertEqual(detail.entries.count, 2)
        XCTAssertTrue(detail.entries[0].heading.hasPrefix(L10n.format("%@ answered", "Viktor")))
        XCTAssertEqual(detail.entries[0].lines, ["Stämmer det? Ja"])
        XCTAssertEqual(WorkroomPaneFeed.shownLine(label: "Belopp", value: "120 kr"), "Belopp: 120 kr")
        XCTAssertEqual(detail.entries[0].text, "Per rad.")
        XCTAssertTrue(detail.entries[1].heading.hasPrefix("David"))
        XCTAssertEqual(detail.commentReaders,
                       L10n.format("%@ sees your comment, and this chat gets it as mail.", "Viktor"))
        XCTAssertTrue(detail.status.hasSuffix(L10n.string("Answered")))
    }

    func testAWithdrawnQuestionTakesNoComment() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let open = WorkroomPaneFeed.detail(try await fixture.store.workroomQuestionDetail(fixture.question.id))
        XCTAssertNotNil(open.commentReaders)
        XCTAssertTrue(open.entries.isEmpty)
        _ = try await fixture.store.withdrawWorkroomQuestion(fixture.question.id, asker: fixture.session, reason: "Löst")
        let withdrawn = WorkroomPaneFeed.detail(try await fixture.store.workroomQuestionDetail(fixture.question.id))
        XCTAssertNil(withdrawn.commentReaders, "a withdrawn question still offered a comment")
        XCTAssertTrue(withdrawn.status.hasSuffix(L10n.string("Withdrawn")))
    }

    func testAPersonIsDescribedByWhereTheyWillSeeTheQuestion() {
        var app = RemoteAccessCoordinator.SessionAccess()
        XCTAssertEqual(WorkroomPaneFeed.personStatus(app: app, browsers: [], isOwner: false),
                       L10n.string("Not in the app yet"))
        XCTAssertEqual(WorkroomPaneFeed.personStatus(app: app, browsers: [], isOwner: true),
                       L10n.string("You · your paired iPhone shows every question"))
        let seen = Date(timeIntervalSince1970: 1_794_000_000)
        app.members.append(.init(id: "m", displayName: "Viktor", deviceID: "d", capability: .interact,
                                 canApprovePermissions: false, joinedAt: seen.addingTimeInterval(-60), lastSeenAt: seen))
        XCTAssertEqual(WorkroomPaneFeed.personStatus(app: app, browsers: [], isOwner: false),
                       L10n.format("In the app · last seen %@", seen.formatted(date: .abbreviated, time: .shortened)))
    }

    // MARK: - Fixtures

    private static let overview = WorkroomPanePresentation(
        chatTitle: "MOMS",
        rooms: [
            .init(id: "open-room", title: "Sonda: beslut", status: "Open until 28 Nov 2026 · Open questions: 1",
                  canClose: true, people: [
                    .init(id: "viktor-id", name: "Viktor", status: "Not in the app yet", canInvite: true),
                    .init(id: "owner-id", name: "David", status: "You · your paired iPhone shows every question",
                          canInvite: false)
                  ]),
            .init(id: "closed-room", title: "Gamla frågor", status: "Closed", canClose: false, people: [])
        ],
        questions: [.init(id: "q1", title: "Hur avrundas momsen?", status: "Viktor · Answered")]
    )

    private static func conversation(id: String = "q1", extra: Bool = false) -> WorkroomPanePresentation {
        var entries = [
            WorkroomPanePresentation.Entry(id: "a1", heading: "Viktor svarade · 7 nov. 2026 14:20",
                                           lines: ["Stämmer det? Ja"], text: "Avrunda per rad.")
        ]
        if extra {
            entries.append(.init(id: "n1", heading: "Viktor · 7 nov. 2026 14:22", lines: [], text: "En sak till."))
        }
        var presentation = overview
        presentation.detail = .init(
            id: id, title: "Hur avrundas momsen?", status: "Sonda: beslut · Viktor · Answered",
            prompt: "Avrundas momsen per rad eller på totalen?", entries: entries,
            commentReaders: "Viktor sees your comment, and this chat gets it as mail.")
        return presentation
    }

    /// A pane in an unshown window, on the panel's own ground, at the panel's size.
    private func mounted(_ presentation: WorkroomPanePresentation,
                         width: CGFloat = Render.width) -> (WorkroomPaneViewController, NSWindow) {
        let pane = WorkroomPaneViewController()
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: width, height: Render.height)
        host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        pane.view.frame = host.bounds
        pane.view.autoresizingMask = [.width, .height]
        host.addSubview(pane.view)
        windows.append(window)
        pane.apply(presentation)
        host.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func rendered(_ pane: WorkroomPaneViewController, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        guard let host = pane.view.superview else { return nil }
        var result: NSBitmapImageRep?
        let drawing = NSAppearance(named: appearance)
        host.appearance = drawing
        drawing?.performAsCurrentDrawingAppearance {
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            result = bitmap
        }
        return result
    }

    private func texts(in pane: WorkroomPaneViewController) -> [String] {
        pane.view.workroomDescendants(ofType: NSTextField.self).map(\.stringValue)
    }

    private struct Fixture {
        let directory: URL
        let store: ControllerStore
        let session: MailAddress
        let room: WorkroomID
        let person: WorkroomPerson
        let question: WorkroomQuestion

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("workroom-pane-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
            session = MailAddress(host: try await store.host().id, kind: .session, id: UUID())
            _ = try await store.registerMailbox(session, name: "MOMS")
            room = try await store.createWorkroom(id: WorkroomID(), scope: "p", title: "Sonda", purpose: "",
                                                  createdBy: session).id
            person = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: "viktor", name: "Viktor",
                                                       language: "sv")
            _ = try await store.openWorkroom(room, people: [person.id], expiresAt: nil)
            question = try await store.askWorkroom(
                id: QuestionID(), roomID: room, scope: "p", asker: session, personHandle: "viktor",
                draft: WorkroomQuestionDraft(
                    title: "Hur avrundas momsen?", prompt: "Per rad eller på totalen?", language: "sv",
                    form: WorkroomForm(fields: [WorkroomField(id: "ok", kind: .yesNo, label: "Stämmer det?")])
                ),
                gitContext: nil)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

private extension NSView {
    func workroomDescendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            ((view as? T).map { [$0] } ?? []) + view.workroomDescendants(ofType: type)
        }
    }
}
