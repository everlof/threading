import Foundation
import ThreadingController

/// Server-rendered pages: no JavaScript, one same-origin stylesheet, every agent- or
/// person-written string escaped and shown as text. Links are only the portal's own routes.
struct PortalRenderer {
    let text: PortalText

    // MARK: - Pages

    func inbox(person: WorkroomPerson, formToken: String, open: WorkroomInboxPage, recent: WorkroomInboxPage,
               openCursor: Int64, recentCursor: Int64) -> String {
        var body = "<h1>\(e(text[.inboxTitle]))</h1>"
        if open.items.isEmpty { body += "<p class=\"quiet\">\(e(text[.inboxEmpty]))</p>" }
        else { body += "<ul class=\"list\">" + open.items.map(row).joined() + "</ul>" }
        if open.more { body += moreLink(open: open.next, recent: recentCursor) }
        if !recent.items.isEmpty {
            body += "<h2>\(e(text[.recentTitle]))</h2><ul class=\"list\">" + recent.items.map(row).joined() + "</ul>"
            if recent.more { body += moreLink(open: openCursor, recent: recent.next) }
        }
        return page(title: text[.inboxTitle], person: person, formToken: formToken, returnPath: "/", body: body)
    }

    func question(person: WorkroomPerson, formToken: String, detail: WorkroomQuestionDetail, notice: String?,
                  error: String?, submitted: [WorkroomFieldAnswer]?, submittedComment: String?) -> String {
        let question = detail.question
        let draft = question.draft
        var body = "<p><a href=\"/\">\(e(text[.backToInbox]))</a></p>"
        body += "<article class=\"question\" lang=\"\(e(draft.language))\">"
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
        if let notice { body += "<p class=\"notice\" role=\"status\">\(e(notice))</p>" }
        if let error { body += "<p class=\"error\" role=\"alert\">\(e(error))</p>" }
        if !detail.notes.isEmpty { body += thread(detail.notes) }
        switch question.state {
        case .open, .answered:
            let latest = detail.answers.last
            if let latest {
                body += "<p class=\"quiet\">\(e(text.format(.answeredRevision, Self.displayDate(latest.at), latest.revision)))</p>"
            }
            body += answerForm(question, formToken: formToken, values: submitted ?? latest?.answers ?? [],
                               comment: submittedComment ?? latest?.comment ?? "", revising: latest != nil)
            body += noteForm(question, formToken: formToken, action: "clarify", title: .clarifyTitle,
                             help: .clarifyHelp, submit: .clarifySubmit, secondary: true)
            if question.state == .open {
                body += noteForm(question, formToken: formToken, action: "decline", title: .declineTitle,
                                 help: .declineHelp, submit: .declineSubmit, secondary: true)
            }
        case .declined:
            body += "<p class=\"notice\">\(e(text[.declinedBanner]))</p>"
        case .withdrawn:
            body += "<p class=\"notice\">\(e(text[.withdrawnBanner]))</p>"
        }
        return page(title: draft.title, person: person, formToken: formToken, returnPath: "/q/\(question.id)", body: body)
    }

    func join(token: String) -> String {
        let body = """
            <h1>\(e(text[.joinTitle]))</h1><p>\(e(text[.joinBody]))</p>
            <form method="post" action="/join/\(e(token))"><button type="submit">\(e(text[.joinContinue]))</button></form>
            """
        return page(title: text[.joinTitle], person: nil, formToken: nil, returnPath: "/", body: body)
    }

    func message(title: PortalKey, body: PortalKey) -> String {
        page(title: text[title], person: nil, formToken: nil, returnPath: "/", body: "<h1>\(e(text[title]))</h1><p>\(e(text[body]))</p>")
    }

    func message(title: PortalKey, text body: String) -> String {
        page(title: text[title], person: nil, formToken: nil, returnPath: "/", body: "<h1>\(e(text[title]))</h1><p>\(e(body))</p>")
    }

    // MARK: - Parts

    private func page(title: String, person: WorkroomPerson?, formToken: String?, returnPath: String, body: String) -> String {
        var header = "<header><span class=\"brand\">Linked Workrooms</span>"
        if let person, let formToken {
            header += "<form method=\"post\" action=\"/language\" class=\"language\">\(hidden(formToken))"
            header += "<input type=\"hidden\" name=\"return\" value=\"\(e(returnPath))\">"
            header += "<label>\(e(text[.language])) <select name=\"language\">"
            for language in PortalLanguage.allCases {
                let selected = language == text.language ? " selected" : ""
                header += "<option value=\"\(language.rawValue)\"\(selected)>\(e(language.nativeName))</option>"
            }
            header += "</select></label> <button type=\"submit\" class=\"secondary\">\(e(text[.saveLanguage]))</button></form>"
            header += "<span class=\"who\">\(e(text.format(.signedInAs, person.name)))</span>"
        }
        header += "</header>"
        return """
            <!doctype html><html lang="\(text.language.rawValue)"><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">\
            <meta name="referrer" content="no-referrer"><title>\(e(title)) · Linked Workrooms</title>\
            <link rel="stylesheet" href="/assets/portal.css"></head><body>\(header)<main>\(body)</main>\
            <footer><p>\(e(text[.privacy]))</p></footer></body></html>
            """
    }

    private func row(_ item: WorkroomInboxItem) -> String {
        let question = item.question
        return "<li><a href=\"/q/\(question.id)\"><span class=\"title\">\(e(question.draft.title))</span>" +
            "<span class=\"meta\">\(e(text.format(.from, question.askerName, item.roomTitle)))</span></a>" +
            stateBadge(question.state) + "</li>"
    }

    private func moreLink(open: Int64, recent: Int64) -> String {
        "<p><a href=\"/?open=\(open)&amp;recent=\(recent)\">\(e(text[.more]))</a></p>"
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

    private func thread(_ notes: [WorkroomNote]) -> String {
        var html = "<section class=\"thread\"><h2>\(e(text[.thread]))</h2><ol>"
        for note in notes {
            let who = note.author == .person ? text[.noteYou] : text[.noteAgent]
            html += "<li class=\"\(note.author.rawValue)\"><p class=\"meta\">\(e(who)) · \(e(Self.displayDate(note.at)))</p>"
            html += "<p class=\"pre\">\(e(note.text))</p></li>"
        }
        return html + "</ol></section>"
    }

    private func answerForm(_ question: WorkroomQuestion, formToken: String, values: [WorkroomFieldAnswer],
                            comment: String, revising: Bool) -> String {
        let chosen = Dictionary(values.map { ($0.field, $0.values) }, uniquingKeysWith: { first, _ in first })
        var html = "<form method=\"post\" action=\"/q/\(question.id)/answer\" class=\"answer\">\(hidden(formToken))"
        html += "<h2>\(e(text[.yourAnswer]))</h2>"
        for field in question.draft.form.fields {
            html += fieldHTML(field, values: chosen[field.id] ?? [])
        }
        let commentRequired = question.draft.form.fields.isEmpty
        let commentLabel = commentRequired ? text[.answerText] : text[.comment]
        html += "<label class=\"field\"><span class=\"label\">\(e(commentLabel))</span>"
        html += "<textarea name=\"comment\" rows=\"4\" maxlength=\"\(WorkroomLimits.commentBytes)\"\(commentRequired ? " required" : "")>"
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
                ? [("yes", .yes), ("no", .no)]
                : [("agree", .agree), ("disagree", .disagree), ("unsure", .unsure)]
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

    private func noteForm(_ question: WorkroomQuestion, formToken: String, action: String, title: PortalKey,
                          help: PortalKey, submit: PortalKey, secondary: Bool) -> String {
        "<details class=\"note\"><summary>\(e(text[title]))</summary>" +
            "<form method=\"post\" action=\"/q/\(question.id)/\(action)\">\(hidden(formToken))" +
            "<p class=\"help\">\(e(text[help]))</p>" +
            "<textarea name=\"text\" rows=\"3\" maxlength=\"\(WorkroomLimits.noteBytes)\" required></textarea>" +
            "<button type=\"submit\"\(secondary ? " class=\"secondary\"" : "")>\(e(text[submit]))</button></form></details>"
    }

    private func hidden(_ formToken: String) -> String {
        "<input type=\"hidden\" name=\"_form\" value=\"\(e(formToken))\">"
    }

    private func e(_ value: String) -> String { PortalHTML.escape(value) }

    /// `2026-10-17 14:05` in UTC, the same for every reader; the stored value is ISO 8601.
    static func displayDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}

enum PortalStyle {
    static let css = """
        :root{color-scheme:light dark;--bg:#f4f6f8;--card:#fff;--ink:#17212b;--quiet:#55636f;--line:#d5dde3;\
        --accent:#0b5c78;--accent-ink:#fff;--soft:#e4eef2;--ok:#1d6b4c;--warn:#7a5310;--bad:#9b2c25}
        @media (prefers-color-scheme:dark){:root{--bg:#12171c;--card:#1b2229;--ink:#e6edf2;--quiet:#9aa8b4;\
        --line:#2e3943;--accent:#5bb6d6;--accent-ink:#0b1a20;--soft:#22303a;--ok:#6fcf9f;--warn:#e3b45c;--bad:#f08a80}}
        *{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
        body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
        header{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;justify-content:space-between;\
        max-width:760px;margin:0 auto;padding:16px}
        .brand{font-weight:700;letter-spacing:-.01em}.who{color:var(--quiet);font-size:.9rem}
        .language{display:flex;gap:6px;align-items:center;font-size:.9rem;order:3}
        main{max-width:760px;margin:0 auto;padding:0 16px 32px}footer{max-width:760px;margin:0 auto;padding:0 16px 32px;\
        color:var(--quiet);font-size:.85rem}
        h1{font-size:1.5rem;line-height:1.25;margin:.4em 0}h2{font-size:1.1rem;margin:1.2em 0 .5em}
        a{color:var(--accent)}p{margin:.5em 0}.quiet,.help,.meta{color:var(--quiet)}.help{font-size:.92rem}
        .pre,.prompt{white-space:pre-wrap;overflow-wrap:anywhere}.prompt{font-size:1.05rem}
        .eyebrow{color:var(--quiet);font-size:.85rem;margin:0}
        .question,.answer,.thread,.note,.list li{background:var(--card);border:1px solid var(--line);border-radius:12px}
        .question{padding:16px 18px}.answer{padding:16px 18px;margin-top:16px}.thread{padding:4px 18px;margin-top:16px}
        .brief{border-top:1px solid var(--line);margin-top:14px;padding-top:4px}.brief ul{padding-left:18px}
        .list{list-style:none;padding:0;margin:0;display:grid;gap:10px}
        .list li{padding:12px 14px;display:flex;gap:12px;align-items:flex-start;justify-content:space-between}
        .list a{text-decoration:none;color:inherit;display:grid;gap:2px;min-width:0}.list .title{font-weight:600;overflow-wrap:anywhere}
        .meta{font-size:.85rem}
        .badge{font-size:.78rem;font-weight:650;border-radius:999px;padding:2px 9px;background:var(--soft);white-space:nowrap}
        .badge.open{color:var(--warn)}.badge.answered{color:var(--ok)}.badge.declined,.badge.withdrawn{color:var(--quiet)}
        .field{display:block;border:0;margin:0 0 16px;padding:0}.field legend,.field .label{font-weight:600;display:block;margin-bottom:6px;padding:0}
        .choice{display:flex;gap:10px;align-items:flex-start;padding:10px 12px;border:1px solid var(--line);border-radius:10px;\
        margin-bottom:8px;cursor:pointer}.choice.compact{margin:0}.inline{display:flex;flex-wrap:wrap;gap:8px}
        .choice input{margin-top:4px}.option{display:block;font-weight:550}.consequence{display:block;color:var(--quiet);font-size:.9rem}
        input[type=text],textarea,select{font:inherit;color:inherit;background:var(--bg);border:1px solid var(--line);\
        border-radius:8px;padding:9px 10px;width:100%}select{width:auto;padding:4px 8px}
        .number{display:flex;gap:8px;align-items:center}.number input{max-width:12em}
        input:focus-visible,textarea:focus-visible,select:focus-visible,button:focus-visible,a:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
        button{font:inherit;font-weight:650;color:var(--accent-ink);background:var(--accent);border:0;border-radius:9px;\
        padding:10px 16px;cursor:pointer}button.secondary{background:var(--soft);color:var(--ink)}
        .language button{padding:4px 10px}
        .note{margin-top:12px;padding:10px 14px}.note summary{cursor:pointer;font-weight:600}.note textarea{margin:8px 0}
        .notice,.error{border-radius:10px;padding:10px 12px;margin:14px 0}.notice{background:var(--soft)}
        .error{border:1px solid var(--bad);color:var(--bad)}
        .thread ol{list-style:none;padding:0}.thread li{border-top:1px solid var(--line);padding:8px 0}.thread li:first-child{border-top:0}
        @media print{header form,.note,button{display:none}body{background:#fff;color:#000}\
        .question,.answer,.thread{border-color:#999}}
        """
}
