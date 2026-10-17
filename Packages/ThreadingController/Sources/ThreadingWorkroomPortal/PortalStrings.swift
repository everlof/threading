import Foundation

/// The languages the portal's own words exist in. A question is written by the agent in the
/// question's language; these are the buttons, labels and messages around it.
public enum PortalLanguage: String, CaseIterable, Sendable {
    case sv, en

    var nativeName: String {
        switch self {
        case .sv: return "Svenska"
        case .en: return "English"
        }
    }

    /// The first supported language among BCP-47 tags, by primary subtag (`sv-FI` is Swedish).
    static func first(of tags: [String]) -> PortalLanguage? {
        for tag in tags {
            let primary = tag.split(separator: "-").first.map { $0.lowercased() } ?? ""
            if let language = PortalLanguage(rawValue: primary) { return language }
        }
        return nil
    }

    /// `Accept-Language` in the browser's order of preference; weights are honoured by order.
    static func acceptLanguage(_ header: String?) -> [String] {
        guard let header else { return [] }
        let weighted = header.split(separator: ",").prefix(16).compactMap { item -> (String, Double)? in
            let parts = item.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let tag = parts.first, !tag.isEmpty, tag != "*" else { return nil }
            let weight = parts.dropFirst().first { $0.hasPrefix("q=") }.flatMap { Double($0.dropFirst(2)) } ?? 1
            return (tag, weight)
        }
        return weighted.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
    }
}

enum PortalKey: CaseIterable {
    case signedInAs, language, saveLanguage
    case inboxTitle, inboxEmpty, recentTitle, more, from
    case stateOpen, stateAnswered, stateDeclined, stateWithdrawn
    case backToInbox, background, evidence, sourceToVerify
    case yourAnswer, comment, answerText, submit, update, optional, choose
    case yes, no, agree, disagree, unsure
    case answeredRevision, saved
    case clarifyTitle, clarifyHelp, clarifySubmit, clarifySent
    case declineTitle, declineHelp, declineSubmit, declinedBanner, withdrawnBanner
    case thread, noteYou, noteAgent
    case errorRequired, errorChoice, errorNumber, errorText, errorRevisions, errorNotes, errorClosed, errorGeneric
    case signInTitle, signInBody, joinTitle, joinBody, joinContinue, linkExpired
    case notFoundTitle, notFoundBody, tooManyTitle, tooManyBody, unavailableTitle, unavailableBody
    case privacy
}

struct PortalText {
    let language: PortalLanguage

    subscript(_ key: PortalKey) -> String {
        (language == .sv ? Self.swedish : Self.english)[key] ?? Self.english[key] ?? ""
    }

    func format(_ key: PortalKey, _ arguments: CVarArg...) -> String {
        String(format: self[key], arguments: arguments)
    }

    static let english: [PortalKey: String] = [
        .signedInAs: "Signed in as %@",
        .language: "Language",
        .saveLanguage: "Change",
        .inboxTitle: "Your questions",
        .inboxEmpty: "No open questions right now.",
        .recentTitle: "Answered and closed",
        .more: "Show more",
        .from: "From %@ · %@",
        .stateOpen: "Open",
        .stateAnswered: "Answered",
        .stateDeclined: "Declined",
        .stateWithdrawn: "Withdrawn",
        .backToInbox: "← All questions",
        .background: "Background",
        .evidence: "Evidence",
        .sourceToVerify: "Source to verify: %@",
        .yourAnswer: "Your answer",
        .comment: "Comment (optional)",
        .answerText: "Your answer",
        .submit: "Send answer",
        .update: "Update answer",
        .optional: "optional",
        .choose: "Choose one",
        .yes: "Yes",
        .no: "No",
        .agree: "Agree",
        .disagree: "Disagree",
        .unsure: "Not sure",
        .answeredRevision: "Answered %@ (revision %d). You can change your answer.",
        .saved: "Your answer is saved. The agent that asked has received it.",
        .clarifyTitle: "Need more information?",
        .clarifyHelp: "Ask the agent. The question stays open.",
        .clarifySubmit: "Ask for clarification",
        .clarifySent: "Your question was sent to the agent.",
        .declineTitle: "Can't answer this?",
        .declineHelp: "Say why, for example that someone else should answer. The question closes.",
        .declineSubmit: "Decline the question",
        .declinedBanner: "You declined this question.",
        .withdrawnBanner: "The agent withdrew this question.",
        .thread: "Conversation",
        .noteYou: "You",
        .noteAgent: "The agent",
        .errorRequired: "Fill in every field that is not marked optional.",
        .errorChoice: "Choose one of the options.",
        .errorNumber: "Enter a number within the stated range.",
        .errorText: "That text is too long.",
        .errorRevisions: "This answer cannot be changed again.",
        .errorNotes: "This conversation is full.",
        .errorClosed: "This question is closed.",
        .errorGeneric: "Check your answer and try again.",
        .signInTitle: "Open your link",
        .signInBody: "Use the personal link you were given to see your questions.",
        .joinTitle: "Welcome to Linked Workrooms",
        .joinBody: "This link signs in this browser. It works once, so keep this browser for later visits.",
        .joinContinue: "Continue",
        .linkExpired: "This link was already used or has expired. Ask for a new one.",
        .notFoundTitle: "Not found",
        .notFoundBody: "This page does not exist, or you no longer have access to it.",
        .tooManyTitle: "Too many requests",
        .tooManyBody: "Wait a moment and try again.",
        .unavailableTitle: "Not available",
        .unavailableBody: "This service is not available right now. Try again later.",
        .privacy: "Your answers are stored on the owner's computer and read by the agent that asked. They are information, not approvals."
    ]

    static let swedish: [PortalKey: String] = [
        .signedInAs: "Inloggad som %@",
        .language: "Språk",
        .saveLanguage: "Byt",
        .inboxTitle: "Dina frågor",
        .inboxEmpty: "Inga öppna frågor just nu.",
        .recentTitle: "Besvarade och stängda",
        .more: "Visa fler",
        .from: "Från %@ · %@",
        .stateOpen: "Öppen",
        .stateAnswered: "Besvarad",
        .stateDeclined: "Avböjd",
        .stateWithdrawn: "Återkallad",
        .backToInbox: "← Alla frågor",
        .background: "Bakgrund",
        .evidence: "Underlag",
        .sourceToVerify: "Källa att verifiera: %@",
        .yourAnswer: "Ditt svar",
        .comment: "Kommentar (valfri)",
        .answerText: "Ditt svar",
        .submit: "Skicka svar",
        .update: "Uppdatera svar",
        .optional: "valfritt",
        .choose: "Välj ett alternativ",
        .yes: "Ja",
        .no: "Nej",
        .agree: "Stämmer",
        .disagree: "Stämmer inte",
        .unsure: "Osäker",
        .answeredRevision: "Besvarad %@ (version %d). Du kan ändra ditt svar.",
        .saved: "Ditt svar är sparat. Agenten som frågade har fått det.",
        .clarifyTitle: "Behöver du mer information?",
        .clarifyHelp: "Fråga agenten. Frågan förblir öppen.",
        .clarifySubmit: "Be om förtydligande",
        .clarifySent: "Din fråga är skickad till agenten.",
        .declineTitle: "Kan du inte svara?",
        .declineHelp: "Skriv varför, till exempel att någon annan bör svara. Frågan stängs.",
        .declineSubmit: "Avböj frågan",
        .declinedBanner: "Du avböjde den här frågan.",
        .withdrawnBanner: "Agenten har dragit tillbaka frågan.",
        .thread: "Samtal",
        .noteYou: "Du",
        .noteAgent: "Agenten",
        .errorRequired: "Fyll i alla fält som inte är markerade som valfria.",
        .errorChoice: "Välj ett av alternativen.",
        .errorNumber: "Ange ett tal inom det angivna intervallet.",
        .errorText: "Texten är för lång.",
        .errorRevisions: "Svaret kan inte ändras fler gånger.",
        .errorNotes: "Samtalet är fullt.",
        .errorClosed: "Frågan är stängd.",
        .errorGeneric: "Kontrollera ditt svar och försök igen.",
        .signInTitle: "Öppna din länk",
        .signInBody: "Använd den personliga länk du fick för att se dina frågor.",
        .joinTitle: "Välkommen till Linked Workrooms",
        .joinBody: "Länken loggar in den här webbläsaren. Den fungerar en gång, så använd samma webbläsare nästa gång.",
        .joinContinue: "Fortsätt",
        .linkExpired: "Länken har redan använts eller gått ut. Be om en ny länk.",
        .notFoundTitle: "Hittades inte",
        .notFoundBody: "Sidan finns inte, eller så har du inte längre tillgång till den.",
        .tooManyTitle: "För många förfrågningar",
        .tooManyBody: "Vänta en stund och försök igen.",
        .unavailableTitle: "Inte tillgänglig",
        .unavailableBody: "Tjänsten är inte tillgänglig just nu. Försök igen senare.",
        .privacy: "Dina svar sparas på ägarens dator och läses av agenten som frågade. De är information, inte godkännanden."
    ]
}
