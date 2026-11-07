import Foundation
import ThreadingController
import ThreadingRemoteKit
import ThreadingWorkroomPortal

/// Tells a workroom person's phone that something waits for them: a question, a message from
/// the agent that asked, the owner's comment, or a room just opened to them.
///
/// Only a person who accepted an app invitation has a phone to tell, and only a question in a
/// room open to them is announced — the same visibility the portal and the app apply on every
/// read. The words are in the person's language; the badge is everything that waits for them.
@MainActor
enum WorkroomAppNotifier {
    enum Moment: Equatable {
        case asked
        case agentMessage(text: String)
        case ownerComment(name: String, text: String)
    }

    static func notify(_ moment: Moment, about question: WorkroomQuestion) async {
        let person = question.person
        guard !RemoteAccessCoordinator.shared.workroomAuthorizations(for: person).isEmpty else { return }
        do {
            let store = try await MacMailbox.shared.controllerStore()
            // Throws not-found for a question the person cannot see yet; it is announced when
            // its room opens instead.
            _ = try await store.participantQuestionVersion(person: person, id: question.id)
            let record = try await store.workroomPerson(person)
            let title: String
            let body: String
            switch moment {
            case .asked:
                title = WorkroomNotificationText.newQuestion(from: question.askerName, language: record.language)
                body = question.draft.title
            case let .agentMessage(text):
                title = WorkroomNotificationText.message(from: question.askerName, language: record.language)
                body = text
            case let .ownerComment(name, text):
                title = WorkroomNotificationText.comment(from: name, language: record.language)
                body = text
            }
            deliver(title: title, body: body, question: question.id, person: person,
                    badge: try await store.participantWaitingCount(person: person))
        } catch {
            ThreadingLogger.remote.notice(
                "Workroom app notice skipped: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    /// A room opened to a person: one notice for everything that waited, pointing at their next
    /// open question.
    static func roomOpened(_ room: WorkroomID, to person: WorkroomPersonID) async {
        guard !RemoteAccessCoordinator.shared.workroomAuthorizations(for: person).isEmpty else { return }
        do {
            let store = try await MacMailbox.shared.controllerStore()
            let waiting = try await store.openWorkroomQuestionCount(room, person: person)
            guard waiting > 0,
                  let first = try await store.participantInbox(person: person, filter: .open, limit: 1).items.first
            else { return }
            let record = try await store.workroomPerson(person)
            deliver(title: WorkroomNotificationText.waiting(waiting, language: record.language),
                    body: first.roomTitle, question: first.question.id, person: person,
                    badge: try await store.participantWaitingCount(person: person))
        } catch {
            ThreadingLogger.remote.notice(
                "Workroom app notice skipped: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    private static func deliver(title: String, body: String, question: QuestionID, person: WorkroomPersonID, badge: Int) {
        let event = RemoteNotificationEventDTO(
            kind: .workroom,
            hostID: RemoteHostIdentity.current.id,
            sessionID: question.description,
            title: clipped(title),
            body: clipped(body)
        )
        RemoteNotificationService.shared.deliverWorkroom(event, person: person, badge: badge)
    }

    /// Lock-screen copy is one bounded line; the broker refuses an oversized payload.
    private static func clipped(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard line.utf8.count > WorkroomAppNotifierDefaults.textBytes else { return line }
        var result = ""
        for character in line {
            guard result.utf8.count + character.utf8.count < WorkroomAppNotifierDefaults.textBytes else { break }
            result.append(character)
        }
        return result + "…"
    }
}

enum WorkroomAppNotifierDefaults {
    /// Bytes of a notification's title or body; the whole APNs payload must fit 4 KiB.
    static let textBytes = 300
}
