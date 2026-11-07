#if DEBUG
import Foundation
import ThreadingRemoteKit

/// Canned Linked Workroom data for the `workroom-inbox` and `workroom-question` demo scenes, so
/// the participant's screens can be photographed and checked without a Mac. The model answers
/// from here instead of the network only while one of those scenes is running.
enum MobileWorkroomFixture {
    static var isActive: Bool {
        switch MobileDemoScene.current {
        case .workroomInbox, .workroomQuestion: return true
        default: return false
        }
    }

    static let questionID = "5d0d2c3e-8f1a-4d6e-9a51-2b7c0e4f9a10"
    /// The answered question with a follow-up waiting, as `workroom-conversation` opens it.
    static let answeredID = "a1f3c9d2-6b4e-4f0a-8c2d-7e5b1a9c3f20"
    private static var replyID: String { answeredID }
    private static let openID = "c7e2a4b1-3d5f-4a6c-9e8b-1f0d2c3a4b30"
    private static let doneID = "e9b1d3f5-7a2c-4e6b-8d0f-3c5a7e9b1d40"
    private static let now = Date().timeIntervalSince1970

    static var inbox: RemoteWorkroomInboxDTO {
        RemoteWorkroomInboxDTO(
            viewer: .participant,
            personName: "Viktor",
            language: "sv",
            sections: [
                RemoteWorkroomSectionDTO(kind: .replies, items: [
                    summary(replyID, "Gäller gränsen även asfalt med tjära?", state: .answered,
                            preview: "Tack för svaret! En följdfråga: ska gränsen 0,5 mg/kg gälla även när asfalten innehåller tjära?",
                            age: 300),
                ], next: 0, more: false),
                RemoteWorkroomSectionDTO(kind: .open, items: [
                    summary(questionID, "Ska asfalt med bara PAH-summa granskas?", state: .open, preview: nil, age: 1_800),
                    summary(openID, "Stämmer sammanfattningen av SONDA-753?", state: .open, preview: nil, age: 3_600),
                ], next: 0, more: true),
                RemoteWorkroomSectionDTO(kind: .recent, items: [
                    summary(doneID, "Vilket labb används för slamprover?", state: .answered, preview: nil, age: 86_400),
                ], next: 0, more: false),
            ],
            state: RemoteWorkroomStateDTO(version: "fixture", waiting: 3)
        )
    }

    static func question(id: String) -> RemoteWorkroomQuestionDTO {
        id == answeredID ? answered : open(id: id)
    }

    /// The open question with the conversation that came before its answer.
    private static func open(id: String) -> RemoteWorkroomQuestionDTO {
        RemoteWorkroomQuestionDTO(
            id: id,
            viewer: .participant,
            roomTitle: "Ärendegenomgång november",
            askerName: "Sonda-agenten",
            personName: "Viktor",
            language: "sv",
            title: "Ska asfalt med bara PAH-summa granskas?",
            prompt: "Labbet redovisar bara summan av PAH för några asfaltsprover. Ska de alltid gå till manuell granskning, eller räcker summan för att klassa dem?",
            background: "Sedan oktober skickar ALS bara PAH-summan för asfalt. Klassningen behöver idag de enskilda ämnena.",
            evidence: [
                RemoteWorkroomEvidenceDTO(label: "SONDA-753", text: "Tre prover i oktober saknade enskilda PAH-värden.", source: "Jira SONDA-753"),
            ],
            fields: [
                RemoteWorkroomFieldDTO(
                    id: "rule", kind: .singleChoice, label: "Hur ska de hanteras?", help: nil, required: true,
                    options: [
                        RemoteWorkroomOptionDTO(id: "review", label: "Granska manuellt", consequence: "Ingen klassning förrän någon tittat på provet"),
                        RemoteWorkroomOptionDTO(id: "sum", label: "Klassa på summan", consequence: "Snabbare, men kan ge för sträng klass"),
                    ],
                    unit: nil, minimum: nil, maximum: nil
                ),
                RemoteWorkroomFieldDTO(id: "limit", kind: .number, label: "Gräns för PAH-summa", help: nil, required: false,
                                       options: [], unit: "mg/kg", minimum: 0, maximum: 1_000),
                RemoteWorkroomFieldDTO(id: "summary", kind: .confirm, label: "Stämmer beskrivningen ovan?", help: nil,
                                       required: true, options: [], unit: nil, minimum: nil, maximum: nil),
            ],
            state: .open,
            entries: [
                RemoteWorkroomEntryDTO(id: "e1", kind: .message, author: .person, authorName: "Viktor",
                                       at: now - 2_400, text: "Gäller det även prover från 2023?", shown: [], revision: nil),
                RemoteWorkroomEntryDTO(id: "e2", kind: .message, author: .agent, authorName: "Sonda-agenten",
                                       at: now - 2_200, text: "Ja, alla prover oavsett år. Bara summan redovisas för dem.",
                                       shown: [], revision: nil),
                RemoteWorkroomEntryDTO(id: "e3", kind: .message, author: .owner, authorName: "David",
                                       at: now - 2_000, text: "Viktor, tänk på att det rör sig om ungefär 40 prover i månaden.",
                                       shown: [], revision: nil),
            ],
            latestAnswer: [],
            latestComment: "",
            canAnswer: true,
            canMessage: true,
            canDecline: true,
            nextQuestionID: openID,
            version: "fixture"
        )
    }

    /// Answered, then asked about by the agent, with the owner's comment between.
    private static var answered: RemoteWorkroomQuestionDTO {
        let base = open(id: answeredID)
        return RemoteWorkroomQuestionDTO(
            id: answeredID, viewer: .participant, roomTitle: base.roomTitle, askerName: base.askerName,
            personName: base.personName, language: base.language, title: "Gäller gränsen även asfalt med tjära?",
            prompt: base.prompt, background: "", evidence: [], fields: base.fields, state: .answered,
            entries: base.entries + [
                RemoteWorkroomEntryDTO(id: "e4", kind: .answer, author: .person, authorName: "Viktor", at: now - 1_500,
                                       text: "Granska alltid när bara summan finns.",
                                       shown: [
                                           RemoteWorkroomShownAnswerDTO(label: "Hur ska de hanteras?", value: "Granska manuellt"),
                                           RemoteWorkroomShownAnswerDTO(label: "Gräns för PAH-summa", value: "0,5 mg/kg"),
                                           RemoteWorkroomShownAnswerDTO(label: "Stämmer beskrivningen ovan?", value: "Stämmer"),
                                       ], revision: 1),
                RemoteWorkroomEntryDTO(id: "e5", kind: .message, author: .agent, authorName: base.askerName,
                                       at: now - 300,
                                       text: "Tack för svaret! En följdfråga: ska gränsen 0,5 mg/kg gälla även när asfalten innehåller tjära?",
                                       shown: [], revision: nil),
            ],
            latestAnswer: [
                RemoteWorkroomFieldAnswerDTO(field: "rule", values: ["review"]),
                RemoteWorkroomFieldAnswerDTO(field: "limit", values: ["0,5"]),
                RemoteWorkroomFieldAnswerDTO(field: "summary", values: [RemoteWorkroomConfirmation.agree.rawValue]),
            ],
            latestComment: "Granska alltid när bara summan finns.",
            canAnswer: true, canMessage: true, canDecline: false, nextQuestionID: questionID, version: "fixture"
        )
    }

    private static func summary(_ id: String, _ title: String, state: RemoteWorkroomQuestionState,
                                preview: String?, age: TimeInterval) -> RemoteWorkroomQuestionSummaryDTO {
        RemoteWorkroomQuestionSummaryDTO(
            id: id, title: title, roomTitle: "Ärendegenomgång november", askerName: "Sonda-agenten",
            personName: "Viktor", state: state, unreadPreview: preview, askedAt: now - age, updatedAt: now - age
        )
    }
}
#endif
