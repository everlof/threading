import Foundation
import ThreadingController

/// Server-rendered pages: one same-origin stylesheet and one same-origin script that only
/// polls and never inserts markup, so every page works without it. Every agent- or
/// person-written string is escaped and shown as text. Links are only the portal's own routes.
///
/// A question page is a conversation: the question, then every answer revision and message in
/// the order they happened, the person's on the right, then a box to write in.
struct PortalRenderer {
    let text: PortalText

    /// The element a page opens at after a message: the newest entry, or the box to write in.
    static let latestAnchor = "latest"

    /// Where each inbox section resumes; `0` means from its start.
    struct InboxCursors {
        let replies: Int64
        let open: Int64
        let recent: Int64
    }

    /// What a page polls, the fingerprint it was rendered at, and where a reload opens.
    private struct Poll {
        let path: String
        let version: String
        let anchor: String?
    }

    // MARK: - Pages

    func inbox(person: WorkroomPerson, formToken: String, version: String, replies: WorkroomInboxPage,
               open: WorkroomInboxPage, recent: WorkroomInboxPage, cursors: InboxCursors) -> String {
        var body = "<h1>\(e(text[.inboxTitle]))</h1>"
        if replies.items.isEmpty, open.items.isEmpty { body += "<p class=\"quiet\">\(e(text[.inboxEmpty]))</p>" }
        if !replies.items.isEmpty {
            body += "<h2>\(e(text[.repliesTitle]))</h2><ul class=\"list\">" + replies.items.map(row).joined() + "</ul>"
            if replies.more { body += moreLink(InboxCursors(replies: replies.next, open: cursors.open, recent: cursors.recent)) }
        }
        if !open.items.isEmpty {
            if !replies.items.isEmpty { body += "<h2>\(e(text[.openTitle]))</h2>" }
            body += "<ul class=\"list\">" + open.items.map(row).joined() + "</ul>"
            if open.more { body += moreLink(InboxCursors(replies: cursors.replies, open: open.next, recent: cursors.recent)) }
        }
        if !recent.items.isEmpty {
            body += "<h2>\(e(text[.recentTitle]))</h2><ul class=\"list\">" + recent.items.map(row).joined() + "</ul>"
            if recent.more { body += moreLink(InboxCursors(replies: cursors.replies, open: cursors.open, recent: recent.next)) }
        }
        return page(title: text[.inboxTitle], person: person, formToken: formToken, returnPath: "/",
                    poll: Poll(path: "/state", version: version, anchor: nil), body: body)
    }

    func question(person: WorkroomPerson, formToken: String, detail: WorkroomQuestionDetail, next: QuestionID?,
                  saved: Bool, error: String?, submitted: [WorkroomFieldAnswer]?, submittedComment: String?) -> String {
        let question = detail.question
        let draft = question.draft
        let entries = Self.entries(detail)
        let writable = question.state == .open || question.state == .answered
        var body = "<nav class=\"crumbs\"><a href=\"/\">\(e(text[.backToInbox]))</a>"
        if let next, !saved { body += "<a href=\"/q/\(next)\">\(e(text[.nextQuestion]))</a>" }
        body += "</nav>"
        if saved {
            body += "<div class=\"notice\" role=\"status\"><p>\(e(text[.saved]))</p>"
            body += next.map { "<p><a class=\"button\" href=\"/q/\($0)\">\(e(text[.nextQuestion]))</a></p>" }
                ?? "<p>\(e(text[.allDone]))</p>"
            body += "</div>"
        }
        if let error { body += "<p class=\"error\" role=\"alert\">\(e(error))</p>" }
        body += "<article class=\"question card\" lang=\"\(e(draft.language))\">"
        body += "<p class=\"eyebrow\">\(e(text.format(.from, question.askerName, detail.room.title)))</p>"
        body += "<h1>\(e(draft.title))</h1>\(stateBadge(question.state))"
        body += "<p class=\"prompt\">\(e(draft.prompt))</p>"
        if !draft.background.isEmpty {
            body += "<section class=\"brief\"><h2>\(e(text[.background]))</h2><p class=\"pre\">\(e(draft.background))</p></section>"
        }
        if !draft.evidence.isEmpty {
            body += "<section class=\"brief\"><h2>\(e(text[.evidence]))</h2><ul>"
            for item in draft.evidence {
                body += "<li><strong>\(e(item.label))</strong><p class=\"pre\">\(e(item.text))</p>"
                if let source = item.source { body += "<p class=\"quiet\">\(e(text.format(.sourceToVerify, source)))</p>" }
                body += "</li>"
            }
            body += "</ul></section>"
        }
        body += "</article>"
        if writable {
            let latest = detail.answers.last
            let form = answerForm(question, formToken: formToken, values: submitted ?? latest?.answers ?? [],
                                  comment: submittedComment ?? latest?.comment ?? "", revising: latest != nil)
            if latest == nil {
                body += form
            } else {
                // The current answer is in the conversation; changing it is a deliberate step.
                body += "<details class=\"card disclosure\"\(submitted != nil ? " open" : "")>"
                body += "<summary>\(e(text[.changeAnswer]))</summary>\(form)</details>"
            }
        }
        if !entries.isEmpty {
            body += "<section class=\"conversation\" aria-label=\"\(e(text[.thread]))\"><ol class=\"chat\">"
            for (index, entry) in entries.enumerated() {
                body += self.entry(entry, question: question, latest: index == entries.count - 1)
            }
            body += "</ol></section>"
        }
        if writable {
            // Until there is an answer or a message, answering is the page's job and writing is
            // the side door; after that the conversation is.
            let composer = composer(question, formToken: formToken, anchored: entries.isEmpty)
            if entries.isEmpty {
                body += "<details class=\"card disclosure\"><summary>\(e(text[.composeFirst]))</summary>\(composer)</details>"
            } else {
                body += "<div class=\"card\">\(composer)</div>"
            }
        }
        switch question.state {
        case .open:
            body += "<details class=\"card disclosure quiet-disclosure\"><summary>\(e(text[.declineTitle]))</summary>"
            body += "<form method=\"post\" action=\"/q/\(question.id)/decline\">\(hidden(formToken))"
            body += "<p class=\"help\">\(e(text[.declineHelp]))</p>"
            body += "<textarea name=\"text\" rows=\"3\" maxlength=\"\(WorkroomLimits.noteBytes)\" required></textarea>"
            body += "<button type=\"submit\" class=\"secondary\">\(e(text[.declineSubmit]))</button></form></details>"
        case .answered:
            break
        case .declined:
            body += "<p class=\"notice\">\(e(text[.declinedBanner]))</p>"
        case .withdrawn:
            body += "<p class=\"notice\">\(e(text[.withdrawnBanner]))</p>"
        }
        if let next, !saved, !writable || question.state == .answered {
            body += "<p class=\"onward\"><a class=\"button\" href=\"/q/\(next)\">\(e(text[.nextQuestion]))</a></p>"
        }
        return page(title: draft.title, person: person, formToken: formToken, returnPath: "/q/\(question.id)",
                    poll: Poll(path: "/q/\(question.id)/state", version: question.pageVersion, anchor: "#\(Self.latestAnchor)"),
                    body: body)
    }

    func join(token: String) -> String {
        let body = """
            <h1>\(e(text[.joinTitle]))</h1><p>\(e(text[.joinBody]))</p>
            <form method="post" action="/join/\(e(token))"><button type="submit">\(e(text[.joinContinue]))</button></form>
            """
        return page(title: text[.joinTitle], person: nil, formToken: nil, returnPath: "/", poll: nil, body: body)
    }

    func message(title: PortalKey, body: PortalKey) -> String {
        page(title: text[title], person: nil, formToken: nil, returnPath: "/", poll: nil,
             body: "<h1>\(e(text[title]))</h1><p>\(e(text[body]))</p>")
    }

    func message(title: PortalKey, text body: String) -> String {
        page(title: text[title], person: nil, formToken: nil, returnPath: "/", poll: nil,
             body: "<h1>\(e(text[title]))</h1><p>\(e(body))</p>")
    }

    // MARK: - Parts

    private func page(title: String, person: WorkroomPerson?, formToken: String?, returnPath: String, poll: Poll?,
                      body: String) -> String {
        var header = "<header>"
        header += person == nil ? "<span class=\"brand\">Linked Workrooms</span>" : "<a class=\"brand\" href=\"/\">Linked Workrooms</a>"
        if let person { header += "<span class=\"who\">\(e(person.name))</span>" }
        header += "</header>"
        var footer = "<footer>"
        if person != nil, let formToken {
            footer += "<form method=\"post\" action=\"/language\" class=\"language\">\(hidden(formToken))"
            footer += "<input type=\"hidden\" name=\"return\" value=\"\(e(returnPath))\">"
            footer += "<label>\(e(text[.language])) <select name=\"language\">"
            for language in PortalLanguage.allCases {
                let selected = language == text.language ? " selected" : ""
                footer += "<option value=\"\(language.rawValue)\"\(selected)>\(e(language.nativeName))</option>"
            }
            footer += "</select></label> <button type=\"submit\" class=\"secondary\">\(e(text[.saveLanguage]))</button></form>"
        }
        footer += "<p>\(e(text[.privacy]))</p></footer>"
        var attributes = ""
        var fresh = ""
        if let poll {
            attributes = " data-poll=\"\(e(poll.path))\" data-version=\"\(e(poll.version))\""
            if let anchor = poll.anchor { attributes += " data-anchor=\"\(e(anchor))\"" }
            fresh = "<p id=\"fresh\" class=\"fresh\" role=\"status\" hidden>\(e(text[.freshNotice])) " +
                "<a href=\"\(e(returnPath + (poll.anchor ?? "")))\">\(e(text[.freshShow]))</a></p>"
        }
        return """
            <!doctype html><html lang="\(text.language.rawValue)"><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">\
            <meta name="referrer" content="no-referrer"><meta name="format-detection" content="telephone=no">\
            <meta name="theme-color" content="#f4f6f8" media="(prefers-color-scheme: light)">\
            <meta name="theme-color" content="#12171c" media="(prefers-color-scheme: dark)">\
            <title>\(e(title)) · Linked Workrooms</title>\
            <link rel="stylesheet" href="/assets/portal.css?v=\(PortalAssets.version)">\
            <script src="/assets/portal.js?v=\(PortalAssets.version)" defer></script></head>\
            <body\(attributes)>\(header)\(fresh)<main>\(body)</main>\(footer)</body></html>
            """
    }

    private func row(_ item: WorkroomInboxItem) -> String {
        let question = item.question
        let target = item.reply == nil ? "/q/\(question.id)" : "/q/\(question.id)#\(Self.latestAnchor)"
        var html = "<li><a href=\"\(target)\"><span class=\"title\">\(e(question.draft.title))</span>" +
            "<span class=\"meta\">\(e(text.format(.from, question.askerName, item.roomTitle)))</span>"
        if let reply = item.reply { html += "<span class=\"preview\">\(e(reply))</span>" }
        html += "</a>"
        html += item.reply == nil ? stateBadge(question.state) : "<span class=\"badge new\">\(e(text[.newMessage]))</span>"
        return html + "</li>"
    }

    private func moreLink(_ cursors: InboxCursors) -> String {
        "<p><a href=\"/?new=\(cursors.replies)&amp;open=\(cursors.open)&amp;recent=\(cursors.recent)\">\(e(text[.more]))</a></p>"
    }

    private func stateBadge(_ state: WorkroomQuestionState) -> String {
        let key: PortalKey
        switch state {
        case .open: key = .stateOpen
        case .answered: key = .stateAnswered
        case .declined: key = .stateDeclined
        case .withdrawn: key = .stateWithdrawn
        }
        return "<span class=\"badge \(state.rawValue)\">\(e(text[key]))</span>"
    }

    // MARK: Conversation

    private enum Entry {
        case answer(WorkroomAnswer)
        case note(WorkroomNote)
    }

    /// Answer revisions and messages in the order the store recorded them.
    private static func entries(_ detail: WorkroomQuestionDetail) -> [Entry] {
        detail.timeline.compactMap { entry in
            switch entry {
            case .answer(let index): return detail.answers.indices.contains(index) ? .answer(detail.answers[index]) : nil
            case .note(let index): return detail.notes.indices.contains(index) ? .note(detail.notes[index]) : nil
            }
        }
    }

    private func entry(_ entry: Entry, question: WorkroomQuestion, latest: Bool) -> String {
        let anchor = latest ? " id=\"\(Self.latestAnchor)\"" : ""
        switch entry {
        case .answer(let answer):
            var html = "<li class=\"msg person\"\(anchor)><p class=\"who\">\(e(text[.noteYou])) · \(time(answer.at))</p>"
            html += "<p class=\"kind\">\(e(text[answer.revision == 1 ? .yourAnswer : .answerChanged]))</p>"
            let shown = question.draft.form.fields.compactMap { field -> (WorkroomField, [String])? in
                guard let values = answer.answers.first(where: { $0.field == field.id })?.values, !values.isEmpty else { return nil }
                return (field, values)
            }
            if !shown.isEmpty {
                html += "<dl class=\"answers\">"
                for (field, values) in shown {
                    html += "<div><dt>\(e(field.label))</dt><dd>\(e(display(field, values: values)))</dd></div>"
                }
                html += "</dl>"
            }
            if !answer.comment.isEmpty { html += "<p class=\"pre\">\(e(answer.comment))</p>" }
            return html + "</li>"
        case .note(let note):
            let side: String
            switch note.author {
            case .person: side = "person"
            case .agent: side = "agent"
            case .owner: side = "agent owner"
            }
            let closing = note.kind == .decline || note.kind == .withdrawal ? " closing" : ""
            var html = "<li class=\"msg \(side)\(closing)\"\(anchor)><p class=\"who\">"
            switch note.author {
            case .person:
                html += e(text[.noteYou])
            case .agent:
                html += "\(e(question.askerName)) <span class=\"tag\">\(e(text[.noteAgent]))</span>"
            case .owner:
                html += "\(e(note.name ?? text[.noteOwner])) <span class=\"tag\">\(e(text[.noteOwner]))</span>"
            }
            html += " · \(time(note.at))</p>"
            switch note.kind {
            case .decline: html += "<p class=\"kind\">\(e(text[.stateDeclined]))</p>"
            case .withdrawal: html += "<p class=\"kind\">\(e(text[.stateWithdrawn]))</p>"
            case .clarification, .response, .comment: break
            }
            return html + "<p class=\"pre\">\(e(note.text))</p></li>"
        }
    }

    private func display(_ field: WorkroomField, values: [String]) -> String {
        WorkroomAnswerDisplay.value(field, values: values, text: text)
    }

    private func composer(_ question: WorkroomQuestion, formToken: String, anchored: Bool) -> String {
        let anchor = anchored ? " id=\"\(Self.latestAnchor)\"" : ""
        return "<form method=\"post\" action=\"/q/\(question.id)/clarify\" class=\"composer\"\(anchor)>\(hidden(formToken))" +
            "<label class=\"field\"><span class=\"label\">\(e(text[.composeTo]))</span>" +
            "<textarea name=\"text\" rows=\"3\" maxlength=\"\(WorkroomLimits.noteBytes)\" required></textarea></label>" +
            "<p class=\"help\">\(e(text[.composeHelp]))</p>" +
            "<button type=\"submit\">\(e(text[.composeSubmit]))</button></form>"
    }

    // MARK: Answer form

    private func answerForm(_ question: WorkroomQuestion, formToken: String, values: [WorkroomFieldAnswer],
                            comment: String, revising: Bool) -> String {
        let chosen = Dictionary(values.map { ($0.field, $0.values) }, uniquingKeysWith: { first, _ in first })
        var html = "<form method=\"post\" action=\"/q/\(question.id)/answer\" class=\"answer\(revising ? "" : " card")\">\(hidden(formToken))"
        if !revising { html += "<h2>\(e(text[.yourAnswer]))</h2>" }
        for field in question.draft.form.fields {
            html += fieldHTML(field, values: chosen[field.id] ?? [])
        }
        let commentRequired = question.draft.form.fields.isEmpty
        let commentLabel = commentRequired ? text[.answerText] : text[.comment]
        html += "<label class=\"field\"><span class=\"label\">\(e(commentLabel))</span>"
        html += "<textarea name=\"comment\" rows=\"\(commentRequired ? 5 : 3)\" maxlength=\"\(WorkroomLimits.commentBytes)\"\(commentRequired ? " required" : "")>"
        html += "\(e(comment))</textarea></label>"
        html += "<button type=\"submit\">\(e(revising ? text[.update] : text[.submit]))</button></form>"
        return html
    }

    private func fieldHTML(_ field: WorkroomField, values: [String]) -> String {
        let name = "f.\(field.id)"
        let label = e(field.label) + (field.required ? "" : " <span class=\"quiet\">(\(e(text[.optional])))</span>")
        let help = field.help.map { "<p class=\"help\">\(e($0))</p>" } ?? ""
        let required = field.required ? " required" : ""
        switch field.kind {
        case .singleChoice, .multiChoice:
            let type = field.kind == .singleChoice ? "radio" : "checkbox"
            var html = "<fieldset class=\"field\"><legend>\(label)</legend>\(help)"
            for option in field.options ?? [] {
                let checked = values.contains(option.id) ? " checked" : ""
                let requiredAttribute = field.kind == .singleChoice ? required : ""
                html += "<label class=\"choice\"><input type=\"\(type)\" name=\"\(e(name))\" value=\"\(e(option.id))\"\(checked)\(requiredAttribute)>"
                html += "<span><span class=\"option\">\(e(option.label))</span>"
                if let consequence = option.consequence { html += "<span class=\"consequence\">\(e(consequence))</span>" }
                html += "</span></label>"
            }
            return html + "</fieldset>"
        case .yesNo, .confirm:
            let choices: [(String, PortalKey)] = field.kind == .yesNo
                ? WorkroomYesNo.allCases.map { ($0.rawValue, WorkroomAnswerDisplay.key(for: $0)) }
                : WorkroomConfirmation.allCases.map { ($0.rawValue, WorkroomAnswerDisplay.key(for: $0)) }
            var html = "<fieldset class=\"field\"><legend>\(label)</legend>\(help)<div class=\"inline\">"
            for (value, key) in choices {
                let checked = values.first == value ? " checked" : ""
                html += "<label class=\"choice compact\"><input type=\"radio\" name=\"\(e(name))\" value=\"\(value)\"\(checked)\(required)>"
                html += "<span>\(e(text[key]))</span></label>"
            }
            return html + "</div></fieldset>"
        case .number:
            let unit = field.unit.map { " <span class=\"unit\">\(e($0))</span>" } ?? ""
            return "<label class=\"field\"><span class=\"label\">\(label)</span>\(help)<span class=\"number\">" +
                "<input type=\"text\" inputmode=\"decimal\" name=\"\(e(name))\" value=\"\(e(values.first ?? ""))\" maxlength=\"32\"\(required)>" +
                "\(unit)</span></label>"
        case .shortText:
            return "<label class=\"field\"><span class=\"label\">\(label)</span>\(help)" +
                "<input type=\"text\" name=\"\(e(name))\" value=\"\(e(values.first ?? ""))\" maxlength=\"\(WorkroomLimits.shortTextBytes)\"\(required)></label>"
        case .longText:
            return "<label class=\"field\"><span class=\"label\">\(label)</span>\(help)" +
                "<textarea name=\"\(e(name))\" rows=\"5\" maxlength=\"\(WorkroomLimits.longTextBytes)\"\(required)>\(e(values.first ?? ""))</textarea></label>"
        }
    }

    private func hidden(_ formToken: String) -> String {
        "<input type=\"hidden\" name=\"_form\" value=\"\(e(formToken))\">"
    }

    /// A stored time, readable without the script (UTC) and in the reader's own zone with it.
    private func time(_ iso: String) -> String {
        "<time datetime=\"\(e(iso))\">\(e(Self.displayDate(iso)))</time>"
    }

    private func e(_ value: String) -> String { PortalHTML.escape(value) }

    /// `2026-10-17 14:05 UTC`, the same for every reader; the stored value is ISO 8601.
    static func displayDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}

/// An answer as the person chose it: option labels, the words for yes and no, the unit. Shared
/// by the portal and the iPhone app's projection, so both say the same words.
public enum WorkroomAnswerDisplay {
    static func key(for answer: WorkroomYesNo) -> PortalKey {
        switch answer {
        case .yes: return .yes
        case .no: return .no
        }
    }

    static func key(for answer: WorkroomConfirmation) -> PortalKey {
        switch answer {
        case .agree: return .agree
        case .disagree: return .disagree
        case .unsure: return .unsure
        }
    }

    public static func value(_ field: WorkroomField, values: [String], language: String) -> String {
        value(field, values: values,
              text: PortalText(language: PortalLanguage.first(of: [language]) ?? .en))
    }

    static func value(_ field: WorkroomField, values: [String], text: PortalText) -> String {
        switch field.kind {
        case .singleChoice, .multiChoice:
            return values.map { value in field.options?.first(where: { $0.id == value })?.label ?? value }.joined(separator: ", ")
        case .yesNo:
            return values.map { WorkroomYesNo(rawValue: $0).map { text[key(for: $0)] } ?? $0 }.joined(separator: ", ")
        case .confirm:
            return values.map { WorkroomConfirmation(rawValue: $0).map { text[key(for: $0)] } ?? $0 }.joined(separator: ", ")
        case .number:
            return (values.first ?? "") + (field.unit.map { " \($0)" } ?? "")
        case .shortText, .longText:
            return values.joined(separator: "\n")
        }
    }
}
