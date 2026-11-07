import SwiftUI
import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

/// The phone's half of Linked Workrooms that needs no Mac: what a membership is shown as, what
/// the form lets through before a round trip, how paged sections grow, and what a refusal says.
final class MobileWorkroomTests: XCTestCase {
    // MARK: Markdown

    /// A table cell that wraps makes its row as tall as its text. Measured at its ideal size —
    /// the size a sideways-scrolling table is given — the grid reported every row on one line,
    /// and drew a two-line cell's second line over the next row. The table with long cells has
    /// to measure taller than the same table with short ones by more than a line, and the
    /// drawing is written out for review.
    @MainActor
    func testATableRowGrowsWithItsWrappedCell() throws {
        let short = """
            | Prov | Beslut |
            |---|---|
            | A1 | Godkänt |
            | A2 | Granskas |
            """
        let long = """
            | Prov | Beslut |
            |---|---|
            | A1 | Godkänt |
            | A2 (`A-rg-as-over-mrr`), arsenik <10, koppar <80 och en förklaring som inte får plats på en rad | **Granskas** eftersom hela gränsen lyfter provet över MRR |
            """
        func render(_ text: String) throws -> UIImage {
            let renderer = ImageRenderer(content: MobileMarkdownView(text, scrollsTables: false)
                .fixedSize().padding().background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage)
        }
        let shortImage = try render(short)
        let longImage = try render(long)
        let line = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        XCTAssertGreaterThan(longImage.size.height, shortImage.size.height + line * 1.5,
                             "a wrapped cell did not make its row taller")
        if let out = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !out.isEmpty,
           let data = longImage.pngData() {
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("mobile-markdown-table.png"))
        }
    }

    /// The sideways-scrolling box is exactly as tall as the table, and the table draws at the
    /// height it measured: `Grid` measured 210 points and drew its rows taller, so the last row
    /// was cut off at the box's edge with no way to scroll down to it.
    @MainActor
    func testATableScrollsSidewaysWithoutLosingItsLastRow() throws {
        let text = """
            | Syntetiskt prov | Utveckling | Familj 1 | Varför |
            |---|---|---|---|
            | Prov B (`A-rg-bly-200`) | IFA, granskas | preliminär MKM, ej 17 05 04 | 1,3 b |
            | Arsenik <15 (`A-rg-as-over-mrr`), arsenik <10, koppar <80 | MKM, MRR, KM | preliminär MRR | hela gränsen lyfter provet över MRR (**C b**) |
            | Tio fall av ”gräns på nivå” (bly, kadmium, Cr(VI), PFOS…) | granskas | slutlig med anmärkning | bara 0, den mildare räkningen, ger en lägre klass (*B b*) |
            | Prov D (`A-rg-zn-12`) | ~~avförd~~ klar | slutlig | `KM` håller med marginal |
            """
        let whole = try XCTUnwrap(ImageRenderer(content: MobileMarkdownView(text, scrollsTables: false).fixedSize())
            .uiImage).size.height

        // In a window, as the app shows it.
        let width: CGFloat = 358
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: ScrollView {
            MobileMarkdownView(text).frame(width: width)
        }.background(Color.black).environment(\.colorScheme, .dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.view.layoutIfNeeded()

        var scrollViews: [UIScrollView] = []
        func collect(_ view: UIView) {
            if let scrollView = view as? UIScrollView { scrollViews.append(scrollView) }
            view.subviews.forEach(collect)
        }
        collect(host.view)
        let sideways = try XCTUnwrap(scrollViews.first { $0.contentSize.width > $0.bounds.width + 1 },
                                     "the wide table does not scroll sideways")
        XCTAssertEqual(sideways.bounds.height, whole, accuracy: 1,
                       "the sideways box is not as tall as its table drawn whole")
        XCTAssertEqual(sideways.contentSize.height, whole, accuracy: 1,
                       "the table inside the box is not drawn at its own height")

        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        // The last row is drawn whole: its band, read up a column of pixels inside the first
        // cell's padding where no text is drawn, is at least a line and its padding tall.
        let box = sideways.convert(sideways.bounds, to: host.view)
        let column = try luminances(of: image, atX: box.minX + MobileDesign.Spacing.medium - 2)
        let scale = image.scale
        let bottom = Int((box.maxY - 4) * scale)
        let band = column[bottom]
        XCTAssertGreaterThan(band, column[Int((box.maxY + 8) * scale)] + 0.03, "the last row's band is not drawn")
        var top = bottom
        while top > 0, abs(column[top - 1] - band) < 0.02 { top -= 1 }
        let line = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        XCTAssertGreaterThan(CGFloat(bottom - top) / scale + 4, line + 2 * MobileDesign.Spacing.small - 2,
                             "the last row is cut off at the box's edge")
        if let out = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !out.isEmpty,
           let data = image.pngData() {
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("mobile-markdown-scrolling-table.png"))
        }
    }

    /// The brightness of each pixel row of `image` at `x` points, top to bottom.
    private func luminances(of image: UIImage, atX x: CGFloat) throws -> [CGFloat] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixel = min(width - 1, Int(x * image.scale))
        return (0..<height).map { row in
            let offset = (row * width + pixel) * 4
            return (0.299 * CGFloat(pixels[offset]) + 0.587 * CGFloat(pixels[offset + 1])
                + 0.114 * CGFloat(pixels[offset + 2])) / 255
        }
    }

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
