import Foundation
import Testing
import ThreadingController
@testable import ThreadingWorkroomPortal

/// The participant portal against a real store: routes, the public-endpoint policy, the join
/// handshake, answering, escaping and both languages.
struct WorkroomPortalTests {
    private static let origin = "https://rooms.example.test"
    private static let host = "rooms.example.test"

    private struct Fixture {
        let directory: URL
        let store: ControllerStore
        let portal: WorkroomPortal
        let session: MailAddress
        let room: LinkedWorkroom
        let person: WorkroomPerson
        let question: WorkroomQuestion
    }

    private func fixture(title: String = "Ska asfalten granskas?") async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        let host = try await store.host().id
        let session = MailAddress(host: host, kind: .session, id: UUID())
        _ = try await store.registerMailbox(session, name: "Ticket sweep")
        let room = try await store.createWorkroom(id: WorkroomID(), scope: "p", title: "Sweep", purpose: "", createdBy: session)
        let person = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: "expert", name: "Expert", language: "sv")
        _ = try await store.openWorkroom(room.id, people: [person.id], expiresAt: nil)
        let draft = WorkroomQuestionDraft(
            title: title, prompt: "Labbet redovisar bara summan.", language: "sv",
            form: WorkroomForm(fields: [
                WorkroomField(id: "rule", kind: .singleChoice, label: "Regel",
                              options: [WorkroomOption(id: "review", label: "Granska"), WorkroomOption(id: "keep", label: "Behåll")]),
                WorkroomField(id: "limit", kind: .number, label: "Gräns", required: false, unit: "mg/kg", minimum: 0)
            ]))
        let question = try await store.askWorkroom(id: QuestionID(), roomID: room.id, scope: "p", asker: session,
                                                   personHandle: "expert", draft: draft, gitContext: nil)
        let configuration = try #require(WorkroomPortalConfiguration(publicOrigin: Self.origin, loopbackPort: 4100))
        let portal = WorkroomPortal(backend: StoreParticipantBackend(store: store), configuration: configuration)
        return Fixture(directory: directory, store: store, portal: portal, session: session, room: room,
                       person: person, question: question)
    }

    private func request(_ method: String, _ target: String, cookie: String? = nil, origin: String? = WorkroomPortalTests.origin,
                         form: [(String, String)]? = nil, host: String = WorkroomPortalTests.host,
                         headers extra: [String: String] = [:]) -> PortalRequest {
        var headers = ["host": host]
        if let cookie { headers["cookie"] = "\(WorkroomPortal.cookieName)=\(cookie)" }
        var body = Data()
        if method == "POST" {
            if let origin { headers["origin"] = origin }
            headers["content-type"] = "application/x-www-form-urlencoded"
            body = Data((form ?? []).map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
        }
        headers.merge(extra) { _, new in new }
        return PortalRequest(method: method, target: target, headers: headers, body: body)
    }

    private func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    private func signIn(_ f: Fixture) async throws -> String {
        let (_, invitation) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        let response = await f.portal.handle(request("POST", "/join/\(invitation)"))
        let cookie = try #require(response.header("Set-Cookie"))
        return String(try #require(cookie.split(separator: ";").first?.split(separator: "=", maxSplits: 1).last))
    }

    private func body(_ response: PortalResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    @Test func routeTableHasOnlyParticipantRoutes() {
        #expect(WorkroomPortal.routes == [
            "GET /assets/portal.css", "GET /join/<token>", "POST /join/<token>", "GET /", "GET /q/<id>",
            "POST /q/<id>/answer", "POST /q/<id>/clarify", "POST /q/<id>/decline", "POST /language"
        ])
        for route in WorkroomPortal.routes {
            for owner in ["room", "people", "person", "invite", "grant", "owner", "open", "close"] {
                #expect(!route.lowercased().contains("/\(owner)"))
            }
        }
    }

    @Test func unconfiguredOrForeignHostIsRefused() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(await f.portal.handle(request("GET", "/", host: "evil.example")).status == 421)
        #expect(await f.portal.handle(request("GET", "/assets/portal.css", host: "127.0.0.1:4100")).status == 200)
        await f.portal.configure(nil)
        let unavailable = await f.portal.handle(request("GET", "/"))
        #expect(unavailable.status == 503)
        #expect(unavailable.header("Content-Security-Policy")?.contains("default-src 'none'") == true)
    }

    @Test func joiningNeedsAPostFromThePublishedOriginAndWorksOnce() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let (_, invitation) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        // A link preview fetching the URL must not spend it.
        #expect(await f.portal.handle(request("GET", "/join/\(invitation)")).status == 200)
        #expect(await f.portal.handle(request("POST", "/join/\(invitation)", origin: "https://evil.example")).status == 403)
        #expect(await f.portal.handle(request("POST", "/join/\(invitation)", origin: nil)).status == 403)
        let joined = await f.portal.handle(request("POST", "/join/\(invitation)"))
        #expect(joined.status == 303 && joined.header("Location") == "/")
        let cookie = try #require(joined.header("Set-Cookie"))
        #expect(cookie.hasPrefix("__Host-wr="))
        #expect(cookie.hasSuffix("; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=2592000"))
        #expect(await f.portal.handle(request("POST", "/join/\(invitation)")).status == 404)
    }

    @Test func inboxAndQuestionNeedASessionAndEscapeEverything() async throws {
        let f = try await fixture(title: "<script>alert(1)</script> \u{202E}evil")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let signedOut = await f.portal.handle(request("GET", "/"))
        #expect(signedOut.status == 401)
        let session = try await signIn(f)
        let inbox = await f.portal.handle(request("GET", "/", cookie: session))
        #expect(inbox.status == 200)
        let html = body(inbox)
        #expect(!html.contains("<script>") && html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("\u{202E}"))
        #expect(html.contains("lang=\"sv\"") && html.contains("Dina frågor"))
        let page = await f.portal.handle(request("GET", "/q/\(f.question.id)", cookie: session))
        #expect(page.status == 200)
        #expect(body(page).contains("name=\"_form\" value=\"\(WorkroomToken.formToken(for: session))\""))
    }

    @Test func answeringNeedsTheFormTokenValidatesAndRedirects() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let session = try await signIn(f)
        let token = WorkroomToken.formToken(for: session)
        let path = "/q/\(f.question.id)/answer"
        #expect(await f.portal.handle(request("POST", path, cookie: session, form: [("f.rule", "review")])).status == 403)
        let invalid = await f.portal.handle(request("POST", path, cookie: session,
                                                    form: [("_form", token), ("f.rule", "review"), ("f.limit", "minus ett")]))
        #expect(invalid.status == 400)
        #expect(body(invalid).contains("Ange ett tal") && body(invalid).contains("value=\"minus ett\""))
        let saved = await f.portal.handle(request("POST", path, cookie: session,
                                                  form: [("_form", token), ("f.rule", "review"), ("f.limit", "0,5"),
                                                         ("comment", "Granska alltid.")]))
        #expect(saved.status == 303 && saved.header("Location") == "/q/\(f.question.id)?saved=1")
        let detail = try await f.store.workroomQuestionDetail(f.question.id)
        #expect(detail.answers.first?.answers == [WorkroomFieldAnswer(field: "rule", values: ["review"]),
                                                  WorkroomFieldAnswer(field: "limit", values: ["0,5"])])
        #expect(try await f.store.inbox(f.session).items.count == 1)
        let shown = await f.portal.handle(request("GET", "/q/\(f.question.id)?saved=1", cookie: session))
        #expect(body(shown).contains("Ditt svar är sparat") && body(shown).contains("Uppdatera svar"))
    }

    @Test func foreignAndMissingQuestionsLookTheSame() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let other = try await f.store.addWorkroomPerson(id: WorkroomPersonID(), handle: "other", name: "Other", language: "sv")
        _ = try await f.store.openWorkroom(f.room.id, people: [other.id], expiresAt: nil)
        let (_, invitation) = try await f.store.issueWorkroomInvitation(person: other.id)
        let joined = await f.portal.handle(request("POST", "/join/\(invitation)"))
        let session = String(try #require(joined.header("Set-Cookie")?.split(separator: ";").first?.split(separator: "=", maxSplits: 1).last))
        let foreign = await f.portal.handle(request("GET", "/q/\(f.question.id)", cookie: session))
        let missing = await f.portal.handle(request("GET", "/q/\(QuestionID())", cookie: session))
        #expect(foreign.status == 404 && missing.status == 404)
        #expect(foreign.body == missing.body)
        #expect(foreign.header("X-Content-Type-Options") == "nosniff" && foreign.header("Cache-Control") == "no-store")
    }

    @Test func postsMustBeSmallUrlEncodedForms() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let session = try await signIn(f)
        let path = "/q/\(f.question.id)/clarify"
        let json = request("POST", path, cookie: session, form: [], headers: ["content-type": "application/json"])
        #expect(await f.portal.handle(json).status == 415)
        let large = PortalRequest(method: "POST", target: path,
                                  headers: ["host": Self.host, "origin": Self.origin, "content-type": "application/x-www-form-urlencoded",
                                            "cookie": "\(WorkroomPortal.cookieName)=\(session)"],
                                  body: Data(repeating: 0x61, count: WorkroomPortal.maximumBodyBytes + 1))
        #expect(await f.portal.handle(large).status == 413)
    }

    @Test func aDeviceIsRateLimited() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let session = try await signIn(f)
        var statuses: [Int] = []
        for _ in 0..<(PortalLimits.devicePerMinute + 1) {
            statuses.append(await f.portal.handle(request("GET", "/assets/portal.css", cookie: session)).status)
        }
        #expect(statuses.allSatisfy { $0 == 200 }) // The stylesheet needs no session.
        for _ in 0..<PortalLimits.devicePerMinute { _ = await f.portal.handle(request("GET", "/", cookie: session)) }
        #expect(await f.portal.handle(request("GET", "/", cookie: session)).status == 429)
    }

    @Test func languageFollowsThePersonAndTheBrowser() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        for key in PortalKey.allCases {
            #expect(PortalText.english[key] != nil && PortalText.swedish[key] != nil)
        }
        #expect(PortalLanguage.acceptLanguage("en-GB;q=0.4, sv-SE, de;q=0.8") == ["sv-SE", "de", "en-GB"])
        let (_, invitation) = try await f.store.issueWorkroomInvitation(person: f.person.id)
        let english = await f.portal.handle(request("GET", "/join/\(invitation)", headers: ["accept-language": "en-US,en;q=0.9"]))
        #expect(body(english).contains("Welcome to Linked Workrooms"))
        let session = try await signIn(f)
        let token = WorkroomToken.formToken(for: session)
        let switched = await f.portal.handle(request("POST", "/language", cookie: session,
                                                     form: [("_form", token), ("language", "en"), ("return", "/q/\(f.question.id)")]))
        #expect(switched.status == 303 && switched.header("Location") == "/q/\(f.question.id)")
        #expect(body(await f.portal.handle(request("GET", "/", cookie: session))).contains("Your questions"))
        #expect(WorkroomPortal.returnPath("https://evil.example") == "/")
    }
}
