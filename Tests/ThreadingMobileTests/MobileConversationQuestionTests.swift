import XCTest
import UIKit
import ThreadingRemoteKit
@testable import ThreadingMobile

@MainActor
final class MobileConversationQuestionTests: XCTestCase {
    private func request(canAnswer: Bool = true) -> RemoteQuestionRequestDTO {
        .init(id: UUID().uuidString, questions: [
            .init(id: "density", header: "Density", prompt: "How much work detail?", options: [
                .init(label: "Compact", detail: "Keep completed work behind a disclosure."),
                .init(label: "Expanded", detail: "Show every step.")], allowsOther: true),
            .init(id: "review", header: "Review", prompt: "What should we check?", options: [], allowsOther: true)
        ], blocksTurn: true, canAnswer: canAnswer)
    }
    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants(type, in: $0) }
    }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(UIButton.self, in: view).first { $0.accessibilityIdentifier == id })
    }
    func testPagingSelectionAndCustomAnswerUseExactQuestionIDs() throws {
        let draft = MobileConversationQuestionDraft()
        var replies: [[String: String]?] = []
        let card = MobileConversationQuestionCard(request: request(), draft: draft, theme: .init(nil)) { replies.append($0) }
        let next = try button("conversation.question.submit", in: card)
        XCTAssertFalse(next.isEnabled)
        try button("conversation.question.option.density.0", in: card).sendActions(for: .touchUpInside)
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(replies.isEmpty)
        next.sendActions(for: .touchUpInside)
        XCTAssertEqual(draft.page, 1)
        let editor = try XCTUnwrap(descendants(UITextField.self, in: card).first)
        editor.text = "Scrolling"; editor.sendActions(for: .editingChanged)
        try button("conversation.question.back", in: card).sendActions(for: .touchUpInside)
        XCTAssertEqual(draft.answers["density"], "Compact")
        next.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.text, "Scrolling")
        next.sendActions(for: .touchUpInside)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0], ["density": "Compact", "review": "Scrolling"])
    }
    func testRecycledViewRestoresDraftAndReadonlyCannotSubmit() throws {
        let draft = MobileConversationQuestionDraft()
        draft.answers = ["density": "Expanded"]
        let card = MobileConversationQuestionCard(request: request(canAnswer: false), draft: draft, theme: .init(nil)) { _ in XCTFail("Read-only form answered") }
        XCTAssertTrue(try button("conversation.question.submit", in: card).isEnabled, "Read-only viewers can review the next page")
        XCTAssertFalse(try button("conversation.question.cancel", in: card).isEnabled)
        let selected = try button("conversation.question.option.density.1", in: card)
        XCTAssertTrue(selected.accessibilityTraits.contains(.selected))
        XCTAssertFalse(selected.isEnabled)
        try button("conversation.question.submit", in: card).sendActions(for: .touchUpInside)
        XCTAssertEqual(draft.page, 1)
        XCTAssertTrue(try button("conversation.question.submit", in: card).isHidden)
        let size = card.systemLayoutSizeFitting(CGSize(width: 288, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertEqual(size.width, 288)
    }
    func testQuestionMetadataDoesNotResetTheTimeline() {
        let store = RemoteConversationStore()
        let row = RemoteConversationRowDTO(id: "stable", kind: .assistant, text: "Working")
        store.replace(with: .init(rows: [row], canSend: false, revision: 1))
        let question = request()
        let change = store.replace(with: .init(rows: [row], canSend: false, questions: [question], revision: 2))
        XCTAssertEqual(change, .delta(inserted: [], updated: [], streamingChanged: false, permissionChanged: false,
                                     questionsChanged: true, capabilitiesChanged: false, historyChanged: false))
        XCTAssertEqual(store.state.questions, [question])
    }
    func testBlockingDecisionStopsWorkingIndicatorWithoutTreatingOptionalQuestionsAsBlocking() {
        let connection = RemoteSessionConnection.demoConversation()
        let question = request()
        connection.conversationStore.replace(with: .init(rows: [], canSend: false, questions: [question]))
        XCTAssertTrue(connection.isAwaitingUserDecision)
        XCTAssertFalse(connection.isAgentWorking)
        let optional = RemoteQuestionRequestDTO(id: question.id, questions: question.questions, blocksTurn: false)
        connection.conversationStore.replace(with: .init(rows: [], canSend: false, questions: [optional]))
        XCTAssertFalse(connection.isAwaitingUserDecision)
        connection.conversationStore.replace(with: .init(rows: [], canSend: false,
            permission: .init(id: "permission", toolName: "Edit", summary: "A.swift")))
        XCTAssertTrue(connection.isAwaitingUserDecision)
        XCTAssertFalse(connection.isAgentWorking)
    }

}
