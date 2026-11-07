import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

/// The phone's half of Linked Workrooms that needs no Mac: what a membership is shown as, what
/// the form lets through before a round trip, how paged sections grow, and what a refusal says.
final class MobileWorkroomTests: XCTestCase {
    // MARK: Membership

    func testAWorkroomMembershipIsNeitherAnOwnerNorAChat() throws {
        let membership = try host(scope: RemoteShareScope.workroom.rawValue)
        XCTAssertTrue(membership.isWorkroomParticipant)
        XCTAssertFalse(membership.isOwnerDevice)
        XCTAssertEqual(membership.menuTitle, MobileL10n.string("%@ · Linked Workroom", "Studio Mac"))
        XCTAssertNotEqual(membership.menuTitle, MobileL10n.string("%@ · Shared chat", "Studio Mac"))
        // In Settings ▸ Macs: the Mac's name over what this phone holds there, and no second
        // copy of the Mac's identity code under a record that only answers questions.
        let row = try XCTUnwrap(PairedMacPresentation.rows(hosts: [membership], activeHostID: nil).first)
        XCTAssertEqual(row.title, "Studio Mac")
        XCTAssertEqual(row.role, MobileL10n.string("Linked Workroom"))
        XCTAssertNil(row.identityCode)

        XCTAssertFalse(try host(scope: RemoteShareScope.all.rawValue).isWorkroomParticipant)
        XCTAssertFalse(try host(scope: RemoteShareScope.session.rawValue).isWorkroomParticipant)
    }

    func testTheBadgeCountsOnlyWorkroomMembershipsAndNeverGoesNegative() throws {
        let workroom = try host(id: "w", scope: RemoteShareScope.workroom.rawValue)
        let owner = try host(id: "o", scope: RemoteShareScope.all.rawValue)
        let second = try host(id: "w2", scope: RemoteShareScope.workroom.rawValue)
        XCTAssertEqual(MobileWorkroomBadge.total(["w": 3, "o": 9, "w2": 2], hosts: [workroom, owner, second]), 5)
        XCTAssertEqual(MobileWorkroomBadge.total(["w": -1], hosts: [workroom]), 0)
        // A membership that has not reported yet counts nothing rather than a stale guess.
        XCTAssertEqual(MobileWorkroomBadge.total([:], hosts: [workroom]), 0)
    }

    func testAWorkroomEventIsShownEvenWhileTheAppIsOpen() {
        XCTAssertTrue(RemoteNotificationPresentationPolicy.presentsInForeground(.workroom))
    }

    // MARK: Form

    func testTheDraftStartsFromTheLatestAnswerAndBuildsOnlyFilledFields() {
        let question = question(latest: [RemoteWorkroomFieldAnswerDTO(field: "rule", values: ["review"])],
                                comment: "Alltid")
        var draft = WorkroomAnswerDraft(question: question)
        XCTAssertEqual(draft.single("rule"), "review")
        XCTAssertEqual(draft.comment, "Alltid")

        draft.setText(" 0,5 ", in: "limit")
        draft.choose(RemoteWorkroomConfirmation.agree.rawValue, in: "summary")
        draft.setText("   ", in: "note")
        let request = draft.request(for: question.fields)
        XCTAssertEqual(request.answers, [
            RemoteWorkroomFieldAnswerDTO(field: "rule", values: ["review"]),
            RemoteWorkroomFieldAnswerDTO(field: "limit", values: ["0,5"]),
            RemoteWorkroomFieldAnswerDTO(field: "summary", values: [RemoteWorkroomConfirmation.agree.rawValue]),
        ])
        XCTAssertEqual(request.comment, "Alltid")
    }

    func testRequiredFieldsAndNumbersAreCheckedBeforeSending() {
        let fields = question().fields
        var draft = WorkroomAnswerDraft()
        XCTAssertEqual(draft.problem(for: fields), .missing)

        draft.choose("review", in: "rule")
        draft.choose(RemoteWorkroomConfirmation.unsure.rawValue, in: "summary")
        XCTAssertNil(draft.problem(for: fields), "an optional number may stay empty")

        draft.setText("mycket", in: "limit")
        XCTAssertEqual(draft.problem(for: fields), .number("Gräns"))
        draft.setText("1001", in: "limit")
        XCTAssertEqual(draft.problem(for: fields), .number("Gräns"))
        draft.setText("12,5", in: "limit")
        XCTAssertNil(draft.problem(for: fields), "a Swedish decimal comma is a number")
    }

    func testMultipleChoiceTogglesAndAFreeTextQuestionNeedsItsComment() {
        var draft = WorkroomAnswerDraft()
        draft.toggle("a", in: "labs")
        draft.toggle("b", in: "labs")
        draft.toggle("a", in: "labs")
        XCTAssertEqual(draft.values["labs"], ["b"])

        XCTAssertEqual(WorkroomAnswerDraft().problem(for: []), .emptyAnswer)
        var text = WorkroomAnswerDraft()
        text.comment = String(repeating: "å", count: RemoteWorkroomLimits.commentBytes)
        XCTAssertEqual(text.problem(for: []), .tooLong)
        text.comment = "Ja, det stämmer."
        XCTAssertNil(text.problem(for: []))
    }

    func testNumbersFollowTheMacsRule() {
        XCTAssertEqual(WorkroomAnswerDraft.number("0,5"), 0.5)
        XCTAssertEqual(WorkroomAnswerDraft.number(" 12.25 "), 12.25)
        XCTAssertNil(WorkroomAnswerDraft.number("inf"))
        XCTAssertNil(WorkroomAnswerDraft.number(""))
    }

    // MARK: Inbox pages

    func testPagingOneSectionAppendsOnlyThatSectionWithoutDuplicates() {
        var pages = WorkroomInboxPages()
        pages.replace(with: inbox(open: [summary("q1"), summary("q2")], openNext: 7, openMore: true))
        XCTAssertEqual(pages.cursors(advancing: .open), MobileWorkroomInboxCursors(replies: 0, open: 7, recent: 0))

        pages.append(RemoteWorkroomSectionDTO(kind: .open, items: [summary("q2"), summary("q3")], next: 9, more: false))
        let open = pages.sections.first { $0.kind == .open }
        XCTAssertEqual(open?.items.map(\.id), ["q1", "q2", "q3"])
        XCTAssertEqual(open?.more, false)
        XCTAssertEqual(pages.sections.first { $0.kind == .replies }?.items.map(\.id), ["r1"])
    }

    func testTheOwnersLatestSectionPagesWithTheRecentCursor() {
        var pages = WorkroomInboxPages()
        pages.replace(with: RemoteWorkroomInboxDTO(
            viewer: .owner, personName: nil, language: nil,
            sections: [RemoteWorkroomSectionDTO(kind: .latest, items: [summary("q1")], next: 42, more: true)],
            state: RemoteWorkroomStateDTO(version: "1", waiting: 0)
        ))
        XCTAssertEqual(pages.cursors(advancing: .latest), MobileWorkroomInboxCursors(replies: 0, open: 0, recent: 42))
    }

    func testOnlyAQuestionIDCanBecomeAPath() {
        XCTAssertThrowsError(try RemoteClient.workroomQuestionID("../state"))
        XCTAssertEqual(try RemoteClient.workroomQuestionID("5D0D2C3E-8F1A-4D6E-9A51-2B7C0E4F9A10"),
                       "5d0d2c3e-8f1a-4d6e-9a51-2b7c0e4f9a10")
    }

    // MARK: Refusals

    func testRefusalsReadAsWhatThePersonCanDoAboutThem() {
        func message(_ status: Int, _ detail: String? = nil) -> String {
            WorkroomRefusal.message(for: RemoteClientError.server(status: status, code: nil, detail: detail))
        }
        XCTAssertEqual(message(400, WorkroomRefusal.answerRequired.rawValue),
                       MobileL10n.string("Fill in every field that is not marked optional."))
        XCTAssertEqual(message(400, WorkroomRefusal.answerNumber.rawValue),
                       MobileL10n.string("Enter a number within the stated range."))
        XCTAssertEqual(message(400, WorkroomRefusal.notes.rawValue), MobileL10n.string("This conversation is full."))
        XCTAssertEqual(message(400, "something_new"), MobileL10n.string("Check your answer and try again."))
        XCTAssertEqual(message(404), MobileL10n.string("This question isn’t available any more."))
        XCTAssertEqual(message(409), MobileL10n.string("This question is closed."))
        XCTAssertEqual(message(403), MobileL10n.string("You can’t do that on this question."))
    }

    // MARK: Fixtures

    private func host(id: String = "mac", scope: String) throws -> PairedRemoteHost {
        PairedRemoteHost(
            id: id, hostID: "mac", shareID: "share", scope: scope, name: "Studio Mac",
            link: try XCTUnwrap(RemoteConnectionLink(baseURL: URL(string: "https://mac.example")!, token: "bearer")),
            lastConnectedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func question(latest: [RemoteWorkroomFieldAnswerDTO] = [], comment: String = "")
        -> RemoteWorkroomQuestionDTO {
        RemoteWorkroomQuestionDTO(
            id: UUID().uuidString.lowercased(), viewer: .participant, roomTitle: "Rum", askerName: "Agent",
            personName: "Viktor", language: "sv", title: "Fråga", prompt: "Hur?", background: "", evidence: [],
            fields: [
                RemoteWorkroomFieldDTO(id: "rule", kind: .singleChoice, label: "Regel", help: nil, required: true,
                                       options: [RemoteWorkroomOptionDTO(id: "review", label: "Granska", consequence: nil)],
                                       unit: nil, minimum: nil, maximum: nil),
                RemoteWorkroomFieldDTO(id: "limit", kind: .number, label: "Gräns", help: nil, required: false,
                                       options: [], unit: "mg/kg", minimum: 0, maximum: 1_000),
                RemoteWorkroomFieldDTO(id: "summary", kind: .confirm, label: "Stämmer det?", help: nil, required: true,
                                       options: [], unit: nil, minimum: nil, maximum: nil),
                RemoteWorkroomFieldDTO(id: "note", kind: .shortText, label: "Notering", help: nil, required: false,
                                       options: [], unit: nil, minimum: nil, maximum: nil),
            ],
            state: .open, entries: [], latestAnswer: latest, latestComment: comment,
            canAnswer: true, canMessage: true, canDecline: true, nextQuestionID: nil, version: "1"
        )
    }

    private func summary(_ id: String) -> RemoteWorkroomQuestionSummaryDTO {
        RemoteWorkroomQuestionSummaryDTO(id: id, title: id, roomTitle: "Rum", askerName: "Agent", personName: "Viktor",
                                         state: .open, unreadPreview: nil, askedAt: 0, updatedAt: 0)
    }

    private func inbox(open: [RemoteWorkroomQuestionSummaryDTO], openNext: Int64, openMore: Bool)
        -> RemoteWorkroomInboxDTO {
        RemoteWorkroomInboxDTO(
            viewer: .participant, personName: "Viktor", language: "sv",
            sections: [
                RemoteWorkroomSectionDTO(kind: .replies, items: [summary("r1")], next: 3, more: false),
                RemoteWorkroomSectionDTO(kind: .open, items: open, next: openNext, more: openMore),
                RemoteWorkroomSectionDTO(kind: .recent, items: [], next: 0, more: false),
            ],
            state: RemoteWorkroomStateDTO(version: "1", waiting: 3)
        )
    }
}
