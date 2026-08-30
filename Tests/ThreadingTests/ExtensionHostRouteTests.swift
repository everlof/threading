import XCTest
@testable import Threading

/// The extension host's route table.
///
/// It used to be spelled three times — a block of path constants, the `||` chain that decided
/// whether an unknown path was a 404, and the dispatch `switch` — and half the chain re-spelled
/// its literals rather than using the constants. A route added to the dispatch and missed in the
/// gate was silently unreachable, with nothing to catch it. `ExtensionHostService.Route` is now
/// the single list, so these tests hold the two properties that made the collapse safe: every
/// literal path still reaches the case it used to, and the 404 gate still runs *before*
/// authentication.
///
/// Every expected path here is written out in full. Deriving one from the enum would agree with
/// any rename and prove nothing.
@MainActor
final class ExtensionHostRouteTests: XCTestCase {

    // MARK: - Parsing

    /// Path, and the case it must produce. Both halves are literal.
    private static let table: [(path: String, route: ExtensionHostService.Route)] = [
        ("/v1/component-patches", .componentPatches),
        ("/v1/facts", .facts),
        ("/v1/identity-resolutions", .identityResolutions),
        ("/v1/network/fetch", .networkFetch),
        ("/v1/project-files/query", .projectFilesQuery),

        ("/v1/secrets", .secrets(nil)),
        ("/v1/secrets/api-token", .secrets("api-token")),

        ("/v1/storage/kv", .keyValue(nil)),
        ("/v1/storage/kv/counters", .keyValue("counters")),

        ("/v1/storage/cache", .cache(nil)),
        ("/v1/storage/cache/avatars", .cache("avatars")),

        // Services and companions keep their suffix unparsed: a malformed one is the handler's
        // 400, answered after its capability check, not the gate's 404.
        ("/v1/services/com.example.provider/lookup", .services("com.example.provider/lookup")),
        ("/v1/companions/tailer/operations/start", .companions("tailer/operations/start")),

        ("/v1/projects", .read(.projects(nil))),
        ("/v1/projects/alpha", .read(.projects("alpha"))),

        ("/v1/sessions", .read(.sessions(.collection))),
        ("/v1/sessions/abc123", .read(.sessions(.item("abc123")))),
        ("/v1/sessions/abc123/runtime", .read(.sessions(.runtime("abc123")))),

        ("/v1/providers", .read(.providers(nil))),
        ("/v1/providers/claude", .read(.providers("claude"))),

        ("/v1/accounts", .read(.accounts(nil))),
        ("/v1/accounts/work", .read(.accounts("work"))),

        ("/v1/events", .read(.events))
    ]

    func testEveryKnownPathParsesToItsRoute() {
        for entry in Self.table {
            XCTAssertEqual(
                ExtensionHostService.Route(path: entry.path),
                entry.route,
                "\(entry.path) parsed to the wrong route"
            )
        }
    }

    /// A name per `Route` case, with no `default:`.
    ///
    /// This switch is the forcing function, and it is worth being exact about how far it
    /// reaches. A case added to `Route` does not compile here until it is named — that part is
    /// a hard compile error, verified by adding a case and watching this file refuse to build.
    /// The `expected` set below and the table above are then the two halves a person keeps in
    /// step: naming a route in one without the other fails `testTheTableCoversEveryRouteCase`.
    /// What nothing can catch is naming the route here and in neither of those, because Swift
    /// cannot enumerate an enum carrying payloads.
    private static func coverageName(
        of route: ExtensionHostService.Route
    ) -> String {
        switch route {
        case .componentPatches: return "componentPatches"
        case .facts: return "facts"
        case .identityResolutions: return "identityResolutions"
        case .services: return "services"
        case .companions: return "companions"
        case .networkFetch: return "networkFetch"
        case .projectFilesQuery: return "projectFilesQuery"
        case .secrets(nil): return "secrets.collection"
        case .secrets: return "secrets.item"
        case .keyValue(nil): return "keyValue.collection"
        case .keyValue: return "keyValue.item"
        case .cache(nil): return "cache.collection"
        case .cache: return "cache.item"
        case .read(.projects(nil)): return "projects.collection"
        case .read(.projects): return "projects.item"
        case .read(.sessions(.collection)): return "sessions.collection"
        case .read(.sessions(.item)): return "sessions.item"
        case .read(.sessions(.runtime)): return "sessions.runtime"
        case .read(.providers(nil)): return "providers.collection"
        case .read(.providers): return "providers.item"
        case .read(.accounts(nil)): return "accounts.collection"
        case .read(.accounts): return "accounts.item"
        case .read(.events): return "events"
        }
    }

    func testTheTableCoversEveryRouteCase() {
        let expected: Set<String> = [
            "componentPatches",
            "facts",
            "identityResolutions",
            "services",
            "companions",
            "networkFetch",
            "projectFilesQuery",
            "secrets.collection",
            "secrets.item",
            "keyValue.collection",
            "keyValue.item",
            "cache.collection",
            "cache.item",
            "projects.collection",
            "projects.item",
            "sessions.collection",
            "sessions.item",
            "sessions.runtime",
            "providers.collection",
            "providers.item",
            "accounts.collection",
            "accounts.item",
            "events"
        ]
        let covered = Set(Self.table.map { Self.coverageName(of: $0.route) })
        XCTAssertEqual(
            covered,
            expected,
            "a route case has no literal path in the table above"
        )
        XCTAssertEqual(
            Self.table.count,
            expected.count,
            "each row should demonstrate a distinct route case"
        )
    }

    // MARK: - Near misses

    func testNearMissPathsAreNotRoutes() {
        let refused = [
            "",
            "/",
            "/v1",
            "/v1/",
            "/v1/project",          // singular
            "/v1/projectss",
            "/v1/sessionss/x",      // doubled letter before the separator
            "/v1/session/x",
            "/v1/events/",          // events has no item route
            "/v1/services",         // the prefix routes need their separator
            "/v1/companions",
            "/v1/storage",
            "/v1/storage/",
            "/v1/storage/kv2",
            "/v1/storage/caches",
            "/v1/secret",
            "/v2/projects",
            "/V1/PROJECTS",         // the table is case-sensitive
            "/v1/component-patch",
            "/v1/fact",
            "/v1/facts/",
            "/v1/network",
            "/v1/network/fetches",
            "/v1/project-files"
        ]
        for path in refused {
            XCTAssertNil(
                ExtensionHostService.Route(path: path),
                "\(path.isEmpty ? "<empty>" : path) must not be a route"
            )
        }
    }

    /// Observed, not assumed: a trailing separator on a collection that *does* have items parses
    /// as that collection's item route carrying the empty identifier. The handlers all refuse an
    /// empty identifier, so `/v1/projects/` is a 404 either way — but it is a 404 from the
    /// handler, not from the gate, and that is what the code this replaced did too.
    func testATrailingSeparatorParsesAsTheEmptyIdentifier() {
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/projects/"), .read(.projects("")))
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/secrets/"), .secrets(""))
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/storage/kv/"), .keyValue(""))
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/storage/cache/"), .cache(""))
        XCTAssertEqual(
            ExtensionHostService.Route(path: "/v1/sessions/"),
            .read(.sessions(.item("")))
        )
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/providers/"), .read(.providers("")))
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/accounts/"), .read(.accounts("")))
        // Services and companions hand the empty suffix to their handler unchanged.
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/services/"), .services(""))
        XCTAssertEqual(ExtensionHostService.Route(path: "/v1/companions/"), .companions(""))
    }

    /// `/v1/sessions/runtime` is the runtime read of an empty session id, not a session named
    /// `runtime`. The distinction is which capability the request costs — `hostSessionRuntimeRead`
    /// rather than `hostSessionsRead` — so it is pinned rather than left to whoever next tidies
    /// the parser.
    func testTheRuntimeSuffixIsMatchedOnTheWholePath() {
        XCTAssertEqual(
            ExtensionHostService.Route(path: "/v1/sessions/runtime"),
            .read(.sessions(.runtime("")))
        )
        XCTAssertEqual(
            ExtensionHostService.Route(path: "/v1/sessions/abc/runtime"),
            .read(.sessions(.runtime("abc")))
        )
        XCTAssertEqual(
            ExtensionHostService.Route(path: "/v1/sessions/abc/runtimes"),
            .read(.sessions(.item("abc/runtimes")))
        )
    }

    // MARK: - The gate runs before authentication

    private func makeService() throws -> ExtensionHostService {
        ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
    }

    private func answer(
        _ service: ExtensionHostService,
        method: String = "GET",
        path: String,
        headers: [String: String] = [:]
    ) throws -> HTTPResponse {
        var response: HTTPResponse?
        service.route(
            HTTPRequest(method: method, path: path, headers: headers, body: Data())
        ) {
            response = $0
        }
        return try XCTUnwrap(response, "\(method) \(path) was never answered")
    }

    /// The ordering is the security property, not an accident of how the guards were written:
    /// an unknown path is refused without the token ever being consulted, so an unauthenticated
    /// caller cannot map which routes exist by telling a 404 apart from a 401. Flipping the two
    /// guards would leak the route table to anyone who can reach the port.
    func testAnUnknownPathIs404BeforeAuthenticationAndAKnownPathIs401() throws {
        let service = try makeService()

        // No credentials at all.
        XCTAssertEqual(try answer(service, path: "/v1/nope").status, 404)
        XCTAssertEqual(try answer(service, path: "/v1/project").status, 404)
        XCTAssertEqual(try answer(service, path: "/v1/sessionss/x").status, 404)

        // A wrong token on those same unknown paths still reads 404, never 401: the gate has
        // already answered.
        let wrong = ["authorization": "Bearer not-a-real-token"]
        XCTAssertEqual(try answer(service, path: "/v1/nope", headers: wrong).status, 404)

        // A known path is where authentication speaks — with or without a token.
        XCTAssertEqual(try answer(service, path: "/v1/projects").status, 401)
        XCTAssertEqual(try answer(service, path: "/v1/projects", headers: wrong).status, 401)
        XCTAssertEqual(try answer(service, path: "/v1/sessions/abc123").status, 401)
        XCTAssertEqual(try answer(service, path: "/v1/events").status, 401)
        XCTAssertEqual(
            try answer(service, method: "PUT", path: "/v1/component-patches").status,
            401,
            "authentication comes before method matching too"
        )
    }
}
