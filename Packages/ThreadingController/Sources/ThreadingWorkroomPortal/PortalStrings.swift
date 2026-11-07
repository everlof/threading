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
    case language, saveLanguage
    case inboxTitle, inboxEmpty, repliesTitle, openTitle, recentTitle, more, from, newMessage
    case stateOpen, stateAnswered, stateDeclined, stateWithdrawn
    case backToInbox, nextQuestion, allDone, background, evidence, sourceToVerify
    case yourAnswer, answerChanged, changeAnswer, comment, answerText, submit, update, optional
    case yes, no, agree, disagree, unsure
    case saved, freshNotice, freshShow
    case composeTo, composeHelp, composeSubmit, composeFirst
    case declineTitle, declineHelp, declineSubmit, declinedBanner, withdrawnBanner
    case thread, noteYou, noteAgent, noteOwner
    case errorRequired, errorChoice, errorNumber, errorText, errorRevisions, errorNotes, errorClosed, errorGeneric
    case signInTitle, signInBody, joinTitle, joinBody, joinContinue, linkExpired
    case notFoundTitle, notFoundBody, tooManyTitle, tooManyBody, unavailableTitle, unavailableBody
    case privacy
    case pushNewQuestion, pushMessage, pushComment, pushWaitingOne, pushWaitingMany
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
        .language: "Language",
        .saveLanguage: "Change",
        .inboxTitle: "Your questions",
        .inboxEmpty: "No open questions right now.",
        .repliesTitle: "New messages",
        .openTitle: "Waiting for your answer",
        .recentTitle: "Answered and closed",
        .more: "Show more",
        .from: "From %@ · %@",
        .newMessage: "New message",
        .stateOpen: "Open",
        .stateAnswered: "Answered",
        .stateDeclined: "Declined",
        .stateWithdrawn: "Withdrawn",
        .backToInbox: "← All questions",
        .nextQuestion: "Next question →",
        .allDone: "That was the last open question. Thank you!",
        .background: "Background",
        .evidence: "Evidence",
        .sourceToVerify: "Source to verify: %@",
        .yourAnswer: "Your answer",
        .answerChanged: "Changed answer",
        .changeAnswer: "Change your answer",
        .comment: "Comment (optional)",
        .answerText: "Your answer",
        .submit: "Send answer",
        .update: "Update answer",
        .optional: "optional",
        .yes: "Yes",
        .no: "No",
        .agree: "Agree",
        .disagree: "Disagree",
        .unsure: "Not sure",
        .saved: "Your answer is saved. The agent that asked has received it.",
        .freshNotice: "Something new has arrived.",
        .freshShow: "Show it",
        .composeTo: "Write to the agent that asked",
        .composeHelp: "Ask something, add a fact or reply. The agent reads it and answers here.",
        .composeSubmit: "Send",
        .composeFirst: "Need to ask something before you answer?",
        .declineTitle: "Can't answer this?",
        .declineHelp: "Say why, for example that someone else should answer. The question closes.",
        .declineSubmit: "Decline the question",
        .declinedBanner: "You declined this question.",
        .withdrawnBanner: "The agent withdrew this question.",
        .thread: "Conversation",
        .noteYou: "You",
        .noteAgent: "AI agent",
        .noteOwner: "owner",
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
        .privacy: "Your answers are stored on the owner's computer and read by the agent that asked. They are information, not approvals.",
        .pushNewQuestion: "New question from %@",
        .pushMessage: "%@ wrote",
        .pushComment: "%@ commented",
        .pushWaitingOne: "A question is waiting for you",
        .pushWaitingMany: "%d questions are waiting for you"
    ]

    static let swedish: [PortalKey: String] = [
        .language: "Språk",
        .saveLanguage: "Byt",
        .inboxTitle: "Dina frågor",
        .inboxEmpty: "Inga öppna frågor just nu.",
        .repliesTitle: "Nya meddelanden",
        .openTitle: "Väntar på ditt svar",
        .recentTitle: "Besvarade och stängda",
        .more: "Visa fler",
        .from: "Från %@ · %@",
        .newMessage: "Nytt meddelande",
        .stateOpen: "Öppen",
        .stateAnswered: "Besvarad",
        .stateDeclined: "Avböjd",
        .stateWithdrawn: "Återkallad",
        .backToInbox: "← Alla frågor",
        .nextQuestion: "Nästa fråga →",
        .allDone: "Det var den sista öppna frågan. Tack!",
        .background: "Bakgrund",
        .evidence: "Underlag",
        .sourceToVerify: "Källa att verifiera: %@",
        .yourAnswer: "Ditt svar",
        .answerChanged: "Ändrat svar",
        .changeAnswer: "Ändra ditt svar",
        .comment: "Kommentar (valfri)",
        .answerText: "Ditt svar",
        .submit: "Skicka svar",
        .update: "Uppdatera svar",
        .optional: "valfritt",
        .yes: "Ja",
        .no: "Nej",
        .agree: "Stämmer",
        .disagree: "Stämmer inte",
        .unsure: "Osäker",
        .saved: "Ditt svar är sparat. Agenten som frågade har fått det.",
        .freshNotice: "Det har kommit något nytt.",
        .freshShow: "Visa",
        .composeTo: "Skriv till agenten som frågade",
        .composeHelp: "Fråga något, lägg till en uppgift eller svara. Agenten läser det och svarar här.",
        .composeSubmit: "Skicka",
        .composeFirst: "Behöver du fråga något innan du svarar?",
        .declineTitle: "Kan du inte svara?",
        .declineHelp: "Skriv varför, till exempel att någon annan bör svara. Frågan stängs.",
        .declineSubmit: "Avböj frågan",
        .declinedBanner: "Du avböjde den här frågan.",
        .withdrawnBanner: "Agenten har dragit tillbaka frågan.",
        .thread: "Samtal",
        .noteYou: "Du",
        .noteAgent: "AI-agent",
        .noteOwner: "ägare",
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
        .privacy: "Dina svar sparas på ägarens dator och läses av agenten som frågade. De är information, inte godkännanden.",
        .pushNewQuestion: "Ny fråga från %@",
        .pushMessage: "%@ skrev",
        .pushComment: "%@ kommenterade",
        .pushWaitingOne: "En fråga väntar på dig",
        .pushWaitingMany: "%d frågor väntar på dig"
    ]
}

/// The titles of the notifications a person's phone shows, in their language. The same table as
/// the portal's words, so a person reads one vocabulary on the web and on the lock screen.
public enum WorkroomNotificationText {
    public static func newQuestion(from asker: String, language: String) -> String {
        text(language).format(.pushNewQuestion, asker)
    }

    public static func message(from author: String, language: String) -> String {
        text(language).format(.pushMessage, author)
    }

    public static func comment(from owner: String, language: String) -> String {
        text(language).format(.pushComment, owner)
    }

    public static func waiting(_ count: Int, language: String) -> String {
        count == 1 ? text(language)[.pushWaitingOne] : text(language).format(.pushWaitingMany, count)
    }

    private static func text(_ language: String) -> PortalText {
        PortalText(language: PortalLanguage.first(of: [language]) ?? .en)
    }
}
