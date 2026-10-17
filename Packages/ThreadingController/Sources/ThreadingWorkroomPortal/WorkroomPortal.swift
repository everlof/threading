import Foundation
import ThreadingController

/// Where the portal is published. Requests whose `Host` is not one of `allowedHosts` are refused
/// (DNS rebinding, stray traffic), and a form post must come from exactly `publicOrigin`.
public struct WorkroomPortalConfiguration: Sendable, Equatable {
    public let publicOrigin: String
    public let allowedHosts: Set<String>

    /// `publicOrigin` is `https://host[:port]`. A tunnel may forward the public `Host` or rewrite it
    /// to the loopback listener's, so both are accepted; neither can be produced by a rebinding page.
    public init?(publicOrigin: String, loopbackPort: UInt16?) {
        guard let url = URL(string: publicOrigin), url.scheme == "https", let host = url.host?.lowercased(),
              url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil else { return nil }
        let authority = url.port.map { "\(host):\($0)" } ?? host
        self.publicOrigin = "https://\(authority)"
        var hosts: Set<String> = [authority]
        if let loopbackPort { hosts.formUnion(["127.0.0.1:\(loopbackPort)", "localhost:\(loopbackPort)"]) }
        allowedHosts = hosts
    }
}

/// The Linked Workrooms participant portal. Every route is listed in `routes`; there is no owner
/// route, so publishing this through a tunnel exposes exactly what a person may do.
public actor WorkroomPortal {
    /// Every method and path pattern this portal answers. A test pins it.
    public static let routes = [
        "GET /assets/portal.css",
        "GET /join/<token>",
        "POST /join/<token>",
        "GET /",
        "GET /q/<id>",
        "POST /q/<id>/answer",
        "POST /q/<id>/clarify",
        "POST /q/<id>/decline",
        "POST /language"
    ]

    public static let cookieName = "__Host-wr"
    public static let maximumBodyBytes = 65_536

    private let backend: any WorkroomParticipantBackend
    private var configuration: WorkroomPortalConfiguration?
    private var limiter = PortalRateLimiter()
    private let clock: @Sendable () -> Date

    public init(backend: any WorkroomParticipantBackend, configuration: WorkroomPortalConfiguration? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.configuration = configuration
        self.clock = clock
    }

    /// The tunnel's address changed, or it stopped (nil: every request is refused as unavailable).
    public func configure(_ configuration: WorkroomPortalConfiguration?) { self.configuration = configuration }

    public func handle(_ request: PortalRequest) async -> PortalResponse {
        let fallback = PortalText(language: PortalLanguage.first(of: PortalLanguage.acceptLanguage(request.header("accept-language"))) ?? .en)
        guard let configuration else {
            return html(503, PortalRenderer(text: fallback).message(title: .unavailableTitle, body: .unavailableBody))
        }
        guard let host = request.header("host")?.lowercased(), configuration.allowedHosts.contains(host) else {
            return html(421, PortalRenderer(text: fallback).message(title: .notFoundTitle, body: .notFoundBody))
        }
        let now = clock()
        guard limiter.admit("global", limit: PortalLimits.globalPerMinute, now: now) else { return tooMany(fallback) }
        do {
            return try await route(request, configuration: configuration, fallback: fallback, now: now)
        } catch {
            return html(503, PortalRenderer(text: fallback).message(title: .unavailableTitle, body: .unavailableBody))
        }
    }

    // MARK: - Routing

    private func route(_ request: PortalRequest, configuration: WorkroomPortalConfiguration, fallback: PortalText,
                       now: Date) async throws -> PortalResponse {
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if request.method == "GET", request.path == "/assets/portal.css" {
            return respond(200, contentType: "text/css; charset=utf-8", body: Data(PortalStyle.css.utf8),
                           extra: [PortalHeader("Cache-Control", "max-age=3600")])
        }
        if segments.count == 2, segments[0] == "join" {
            let token = segments[1]
            if request.method == "GET" { return html(200, PortalRenderer(text: fallback).join(token: token)) }
            if request.method == "POST" { return try await join(request, token: token, configuration: configuration, fallback: fallback, now: now) }
            return notFound(fallback)
        }
        // Everything else belongs to a signed-in person.
        guard let sessionToken = Self.cookie(request.header("cookie")),
              let participant = try await backend.participant(sessionToken: sessionToken) else {
            return html(401, PortalRenderer(text: fallback).message(title: .signInTitle, body: .signInBody),
                        extra: request.header("cookie")?.contains(Self.cookieName) == true ? [Self.clearCookie] : [])
        }
        guard limiter.admit("device:\(participant.device.id)", limit: PortalLimits.devicePerMinute, now: now) else {
            return tooMany(fallback)
        }
        let text = PortalText(language: PortalLanguage.first(of: [participant.person.language]) ?? fallback.language)
        let renderer = PortalRenderer(text: text)
        let formToken = WorkroomToken.formToken(for: sessionToken)
        var form = PortalForm.Fields()
        if request.method == "POST" {
            if let refusal = refusePost(request, configuration: configuration, text: text) { return refusal }
            form = PortalForm.parse(request.body)
            guard WorkroomToken.equal(form.first("_form"), formToken) else {
                return html(403, renderer.message(title: .notFoundTitle, body: .errorGeneric))
            }
        }
        let person = participant.person
        switch (request.method, segments.count) {
        case ("GET", 1) where segments[0].isEmpty:
            let openCursor = Int64(request.query["open"] ?? "") ?? 0
            let recentCursor = Int64(request.query["recent"] ?? "") ?? 0
            guard openCursor >= 0, recentCursor >= 0 else { return notFound(text) }
            let open = try await backend.inbox(person: person.id, filter: .open, cursor: openCursor)
            let recent = try await backend.inbox(person: person.id, filter: .recent, cursor: recentCursor)
            return html(200, renderer.inbox(person: person, formToken: formToken, open: open, recent: recent,
                                            openCursor: openCursor, recentCursor: recentCursor))
        case ("POST", 1) where segments[0] == "language":
            guard let language = PortalLanguage(rawValue: form.first("language")) else { return notFound(text) }
            _ = try await backend.setLanguage(person: person.id, language: language.rawValue)
            return redirect(Self.returnPath(form.first("return")))
        case ("GET", 2) where segments[0] == "q":
            guard let id = try? QuestionID(segments[1]) else { return notFound(text) }
            let notice: String? = request.query["saved"] != nil ? text[.saved] : request.query["asked"] != nil ? text[.clarifySent] : nil
            return try await questionPage(person: person, id: id, renderer: renderer, formToken: formToken, status: 200, notice: notice)
        case ("POST", 3) where segments[0] == "q":
            guard let id = try? QuestionID(segments[1]) else { return notFound(text) }
            return try await questionAction(segments[2], person: person, id: id, form: form, renderer: renderer, formToken: formToken)
        default:
            return notFound(text)
        }
    }

    private func join(_ request: PortalRequest, token: String, configuration: WorkroomPortalConfiguration,
                      fallback: PortalText, now: Date) async throws -> PortalResponse {
        if let refusal = refusePost(request, configuration: configuration, text: fallback) { return refusal }
        guard limiter.admit("join", limit: PortalLimits.joinsPerMinute, now: now) else { return tooMany(fallback) }
        do {
            let (_, session) = try await backend.redeem(invitation: token,
                                                        deviceLabel: Self.deviceLabel(request.header("user-agent")))
            return redirect("/", extra: [PortalHeader("Set-Cookie", "\(Self.cookieName)=\(session); Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=\(Int(WorkroomLimits.deviceLifetime))")])
        } catch ControllerError.notFound {
            return html(404, PortalRenderer(text: fallback).message(title: .notFoundTitle, body: .linkExpired))
        }
    }

    private func questionAction(_ action: String, person: WorkroomPerson, id: QuestionID, form: PortalForm.Fields,
                                renderer: PortalRenderer, formToken: String) async throws -> PortalResponse {
        do {
            switch action {
            case "answer":
                let detail = try await backend.question(person: person.id, id: id)
                let answers = detail.question.draft.form.fields.compactMap { field -> WorkroomFieldAnswer? in
                    let values = (form.values["f.\(field.id)"] ?? []).map { field.kind == .longText ? $0 : $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    return values.isEmpty ? nil : WorkroomFieldAnswer(field: field.id, values: values)
                }
                let comment = form.first("comment")
                do {
                    _ = try await backend.answer(person: person.id, id: id, answers: answers, comment: comment)
                } catch let error as ControllerError {
                    guard error != .notFound else { throw error }
                    return html(error == .conflict ? 409 : 400,
                                renderer.question(person: person, formToken: formToken, detail: detail, notice: nil,
                                                  error: Self.message(for: error, text: renderer.text),
                                                  submitted: answers, submittedComment: comment))
                }
                return redirect("/q/\(id)?saved=1")
            case "clarify":
                _ = try await backend.clarify(person: person.id, id: id, text: form.first("text"))
                return redirect("/q/\(id)?asked=1")
            case "decline":
                _ = try await backend.decline(person: person.id, id: id, reason: form.first("text"))
                return redirect("/q/\(id)")
            default:
                return notFound(renderer.text)
            }
        } catch ControllerError.notFound {
            return notFound(renderer.text)
        } catch let error as ControllerError {
            return try await questionPage(person: person, id: id, renderer: renderer, formToken: formToken,
                                          status: error == .conflict ? 409 : 400, notice: nil,
                                          error: Self.message(for: error, text: renderer.text))
        }
    }

    private func questionPage(person: WorkroomPerson, id: QuestionID, renderer: PortalRenderer, formToken: String,
                              status: Int, notice: String?, error: String? = nil) async throws -> PortalResponse {
        do {
            let detail = try await backend.question(person: person.id, id: id)
            return html(status, renderer.question(person: person, formToken: formToken, detail: detail, notice: notice,
                                                  error: error, submitted: nil, submittedComment: nil))
        } catch ControllerError.notFound {
            return notFound(renderer.text)
        }
    }

    // MARK: - Policy

    /// A post must come from the published origin, as a small url-encoded form.
    private func refusePost(_ request: PortalRequest, configuration: WorkroomPortalConfiguration,
                            text: PortalText) -> PortalResponse? {
        guard request.header("origin") == configuration.publicOrigin else {
            return html(403, PortalRenderer(text: text).message(title: .notFoundTitle, body: .errorGeneric))
        }
        guard request.header("content-type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
                .lowercased() == "application/x-www-form-urlencoded" else {
            return html(415, PortalRenderer(text: text).message(title: .notFoundTitle, body: .errorGeneric))
        }
        guard request.body.count <= Self.maximumBodyBytes else {
            return html(413, PortalRenderer(text: text).message(title: .notFoundTitle, body: .errorText))
        }
        return nil
    }

    static func message(for error: ControllerError, text: PortalText) -> String {
        switch error {
        case .conflict: return text[.errorClosed]
        case .invalidInput(let field):
            switch field {
            case "answer_required": return text[.errorRequired]
            case "answer_choice", "answer_yes_no", "answer_confirm": return text[.errorChoice]
            case "answer_number": return text[.errorNumber]
            case "answer_text", "comment", "note": return text[.errorText]
            case "answer_revisions": return text[.errorRevisions]
            case "notes": return text[.errorNotes]
            default: return text[.errorGeneric]
            }
        default: return text[.errorGeneric]
        }
    }

    static func cookie(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == cookieName { return String(pair[1]) }
        }
        return nil
    }

    static let clearCookie = PortalHeader("Set-Cookie", "\(cookieName)=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0")

    /// Only the inbox or a question page; anything else returns to the inbox.
    static func returnPath(_ value: String) -> String {
        if value.hasPrefix("/q/"), (try? QuestionID(String(value.dropFirst(3)))) != nil { return value }
        return "/"
    }

    /// A short, human description of the browser for the owner's device list.
    static func deviceLabel(_ userAgent: String?) -> String {
        guard let agent = userAgent else { return "Browser" }
        let browser = agent.contains("Edg/") ? "Edge" : agent.contains("Firefox/") ? "Firefox"
            : agent.contains("Chrome/") ? "Chrome" : agent.contains("Safari/") ? "Safari" : "Browser"
        let system = agent.contains("iPhone") ? "iPhone" : agent.contains("iPad") ? "iPad" : agent.contains("Android") ? "Android"
            : agent.contains("Mac OS X") ? "Mac" : agent.contains("Windows") ? "Windows" : agent.contains("Linux") ? "Linux" : nil
        return system.map { "\(browser) on \($0)" } ?? browser
    }

    // MARK: - Responses

    static let securityHeaders = [
        PortalHeader("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"),
        PortalHeader("X-Content-Type-Options", "nosniff"),
        PortalHeader("Referrer-Policy", "no-referrer"),
        PortalHeader("X-Robots-Tag", "noindex, nofollow"),
        PortalHeader("Strict-Transport-Security", "max-age=31536000"),
        PortalHeader("Cross-Origin-Opener-Policy", "same-origin"),
        PortalHeader("Cross-Origin-Resource-Policy", "same-origin"),
        PortalHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
    ]

    private func respond(_ status: Int, contentType: String, body: Data, extra: [PortalHeader] = []) -> PortalResponse {
        let cache = extra.contains { $0.name == "Cache-Control" } ? [] : [PortalHeader("Cache-Control", "no-store")]
        return PortalResponse(status: status, headers: Self.securityHeaders + cache + [PortalHeader("Content-Type", contentType)] + extra,
                              body: body)
    }

    private func html(_ status: Int, _ page: String, extra: [PortalHeader] = []) -> PortalResponse {
        respond(status, contentType: "text/html; charset=utf-8", body: Data(page.utf8), extra: extra)
    }

    private func redirect(_ location: String, extra: [PortalHeader] = []) -> PortalResponse {
        respond(303, contentType: "text/plain; charset=utf-8", body: Data(), extra: [PortalHeader("Location", location)] + extra)
    }

    /// The one answer for missing, foreign and revoked alike.
    private func notFound(_ text: PortalText) -> PortalResponse {
        html(404, PortalRenderer(text: text).message(title: .notFoundTitle, body: .notFoundBody))
    }

    private func tooMany(_ text: PortalText) -> PortalResponse {
        html(429, PortalRenderer(text: text).message(title: .tooManyTitle, body: .tooManyBody),
             extra: [PortalHeader("Retry-After", "60")])
    }
}

enum PortalLimits {
    static let globalPerMinute = 600
    static let devicePerMinute = 120
    static let joinsPerMinute = 20
    /// Keys the limiter remembers before it forgets the stale ones.
    static let trackedKeys = 2_000
}

/// Fixed one-minute windows per key. Keyed by device and globally, never by client address:
/// every request arrives from the tunnel on loopback, and forwarding headers can be forged.
struct PortalRateLimiter {
    private var windows: [String: (start: Date, count: Int)] = [:]

    mutating func admit(_ key: String, limit: Int, now: Date) -> Bool {
        if windows.count > PortalLimits.trackedKeys {
            windows = windows.filter { now.timeIntervalSince($0.value.start) < 60 }
        }
        var window = windows[key] ?? (now, 0)
        if now.timeIntervalSince(window.start) >= 60 { window = (now, 0) }
        guard window.count < limit else { windows[key] = window; return false }
        window.count += 1
        windows[key] = window
        return true
    }
}
