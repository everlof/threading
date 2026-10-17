import Foundation
import ThreadingController

/// One request as the socket adapter parsed it. Header names are lowercased; an adapter refuses
/// a request that repeats `host`, `origin`, `cookie` or `content-type` before it gets here.
public struct PortalRequest: Sendable {
    public let method: String
    /// The path without its query.
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, target: String, headers: [String: String], body: Data = Data()) {
        self.method = method.uppercased()
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = parts.first.map(String.init) ?? "/"
        query = parts.count > 1 ? PortalForm.parse(Data(parts[1].utf8)).single : [:]
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct PortalResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [PortalHeader]
    public let body: Data

    public init(status: Int, headers: [PortalHeader], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct PortalHeader: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// Everything the portal may do, and nothing the owner or an agent may do. The host supplies an
/// implementation over its store; it has no route to rooms, people, grants or invitations.
public protocol WorkroomParticipantBackend: Sendable {
    func redeem(invitation token: String, deviceLabel: String) async throws -> (WorkroomParticipant, String)
    func participant(sessionToken: String) async throws -> WorkroomParticipant?
    func inbox(person: WorkroomPersonID, filter: WorkroomInboxFilter, cursor: Int64) async throws -> WorkroomInboxPage
    func question(person: WorkroomPersonID, id: QuestionID) async throws -> WorkroomQuestionDetail
    func answer(person: WorkroomPersonID, id: QuestionID, answers: [WorkroomFieldAnswer],
                comment: String) async throws -> WorkroomParticipantReceipt
    func clarify(person: WorkroomPersonID, id: QuestionID, text: String) async throws -> WorkroomParticipantReceipt
    func decline(person: WorkroomPersonID, id: QuestionID, reason: String) async throws -> WorkroomParticipantReceipt
    func setLanguage(person: WorkroomPersonID, language: String) async throws -> WorkroomPerson
}

/// The store itself, as a backend. A host that must react to a person's write (deliver the mail
/// notice) wraps this rather than reimplementing it.
public struct StoreParticipantBackend: WorkroomParticipantBackend {
    public let store: ControllerStore

    public init(store: ControllerStore) { self.store = store }

    public func redeem(invitation token: String, deviceLabel: String) async throws -> (WorkroomParticipant, String) {
        try await store.redeemWorkroomInvitation(token, deviceLabel: deviceLabel)
    }
    public func participant(sessionToken: String) async throws -> WorkroomParticipant? {
        try await store.workroomParticipant(sessionToken: sessionToken)
    }
    public func inbox(person: WorkroomPersonID, filter: WorkroomInboxFilter, cursor: Int64) async throws -> WorkroomInboxPage {
        try await store.participantInbox(person: person, filter: filter, cursor: cursor)
    }
    public func question(person: WorkroomPersonID, id: QuestionID) async throws -> WorkroomQuestionDetail {
        try await store.participantQuestion(person: person, id: id)
    }
    public func answer(person: WorkroomPersonID, id: QuestionID, answers: [WorkroomFieldAnswer],
                       comment: String) async throws -> WorkroomParticipantReceipt {
        try await store.participantAnswer(person: person, id: id, answers: answers, comment: comment)
    }
    public func clarify(person: WorkroomPersonID, id: QuestionID, text: String) async throws -> WorkroomParticipantReceipt {
        try await store.participantClarify(person: person, id: id, text: text)
    }
    public func decline(person: WorkroomPersonID, id: QuestionID, reason: String) async throws -> WorkroomParticipantReceipt {
        try await store.participantDecline(person: person, id: id, reason: reason)
    }
    public func setLanguage(person: WorkroomPersonID, language: String) async throws -> WorkroomPerson {
        try await store.participantSetLanguage(person: person, language: language)
    }
}

/// `application/x-www-form-urlencoded`, the only body the portal accepts.
enum PortalForm {
    struct Fields {
        var values: [String: [String]] = [:]
        var single: [String: String] { values.compactMapValues(\.last) }
        func first(_ name: String) -> String { values[name]?.first ?? "" }
    }

    static func parse(_ body: Data) -> Fields {
        var fields = Fields()
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0]) else { continue }
            let value = parts.count > 1 ? decode(parts[1]) ?? "" : ""
            fields.values[name, default: []].append(value)
        }
        return fields
    }

    private static func decode(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

/// Escapes text for HTML element and attribute content. Directional overrides are replaced so
/// agent-written text cannot visually reorder what a person reads around it.
enum PortalHTML {
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "\u{202A}"..."\u{202E}", "\u{2066}"..."\u{2069}", "\u{200E}", "\u{200F}": result += "\u{FFFD}"
            case "\0": continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
