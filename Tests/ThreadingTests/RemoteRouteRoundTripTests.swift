@testable import Threading
import ThreadingRemoteKit
import XCTest

/// The one test that puts **both ends of the remote wire in the same process**.
///
/// Everything else about this protocol proves one side is self-consistent.
/// `RemoteRouteVocabularyTests` checks the package's enums, `RemoteRouteWireSpellingTests`
/// checks the host's derived constants against the literal bytes, and
/// `RemoteServerIntegrationTests` drives the server with paths it spells itself. None of them
/// can catch the failure that actually ships a broken phone: a route renamed on the host and
/// updated in the host's own tests, while the client keeps building the old URL. Every suite
/// stays green and the app stops working.
///
/// So this file builds each URL the way `RemoteConnectionLink` builds it — the same code the
/// iPhone runs — takes the path off it the way the wire would, and hands that to the matcher
/// `RemoteAccessServer` calls. A rename that moves one end and not the other fails here.
///
/// The loops switch **exhaustively** over `allCases` on purpose. A new route or action is a
/// compile error in this file until somebody says which builder and which matcher own it, which
/// is what stops a route from shipping untested.
final class RemoteRouteRoundTripTests: XCTestCase {
    // MARK: - Fixture

    /// An origin whose path is `/`, so a built URL's path is the route and nothing else.
    private let link = RemoteConnectionLink(
        baseURL: URL(string: "https://mac.example:8443/")!,
        token: "round-trip-bearer"
    )!

    /// Identifiers deliberately chosen to need no percent-escaping, so an equality assertion
    /// means "the host read back the id the client put in" rather than "the host read back
    /// whatever Foundation escaped it to". The escaping case is asserted on its own below.
    private let sessionID = "session-1234"
    private let terminalID = "terminal-5678"

    private struct UnparsedRequest: Error {}

    // MARK: - Helpers

    /// The request target the host actually receives.
    ///
    /// `URLComponents.path` is percent-**decoded**; a request target on the wire is not, and
    /// `RemoteRouter` never decodes. So `percentEncodedPath` is the honest input, passed through
    /// `RemoteRouter.normalizedPath` because that is the server's own first call on a raw target.
    private func wirePath(_ url: URL) throws -> String {
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false),
            "the client built a URL that does not decompose: \(url.absoluteString)"
        )
        return RemoteRouter.normalizedPath(components.percentEncodedPath)
    }

    /// Parses a real request head through `MCPConnection`, which is the only place header names
    /// are lowercased. Building an `HTTPRequest` by hand would skip exactly the step under test.
    private func parsedRequest(headerName: String, value: String) throws -> HTTPRequest {
        let raw = [
            "GET \(RemoteRoute.me.absolutePath) HTTP/1.1",
            "Host: mac.example",
            "\(headerName): \(value)",
            "",
            "",
        ].joined(separator: "\r\n")
        switch MCPConnection.parseRequest(
            from: Data(raw.utf8),
            maximumBodyBytes: RemoteAccessDefaults.maximumRequestBytes
        ) {
        case let .request(request, _):
            return request
        case .incomplete:
            XCTFail("the fixture request head was not recognised as complete")
            throw UnparsedRequest()
        case let .malformed(status, reason):
            XCTFail("the fixture request head was refused: \(status) \(reason)")
            throw UnparsedRequest()
        }
    }

    // MARK: - REST routes

    func testEveryRESTRouteTheClientBuildsIsTheOneTheHostMatches() throws {
        for route in RemoteRoute.allCases {
            switch route {
            case .me:
                XCTAssertEqual(try wirePath(link.meURL), RemoteRouter.apiSessionsPath)
            case .search:
                XCTAssertEqual(try wirePath(link.searchURL), RemoteRouter.searchPath)
                XCTAssertEqual(
                    try wirePath(link.searchResolveURL),
                    RemoteRouter.searchResolvePath
                )
            case .usage:
                XCTAssertEqual(try wirePath(link.usageURL), RemoteRouter.usagePath)
                // The paged form adds a query; the host matches the path in front of it, which
                // is why `normalizedPath` is in the helper rather than assumed away.
                XCTAssertEqual(
                    try wirePath(link.usageURL(cursor: "cursor-1", limit: 25)),
                    RemoteRouter.usagePath
                )
            case .usageLimit:
                XCTAssertEqual(
                    try wirePath(link.usageLimitURL(seriesID: "series-1", days: 7)),
                    RemoteRouter.usageLimitPath
                )
            case .session:
                XCTAssertEqual(try wirePath(link.createSessionURL), RemoteRouter.createSessionPath)
            case .terminal:
                // There is no bare `/api/terminal` endpoint on either side: this route exists
                // only as the prefix under which an id and an action live. Assert it through the
                // one builder/matcher pair that owns it rather than inventing an endpoint.
                let built = try wirePath(link.resumeTerminalURL(terminalID: terminalID))
                XCTAssertTrue(
                    built.hasPrefix(RemoteRoute.terminal.prefix),
                    "the client stopped building terminal URLs under \(RemoteRoute.terminal.prefix): \(built)"
                )
                XCTAssertEqual(RemoteRouter.resumeTerminalID(forPath: built), terminalID)
            case .theme:
                XCTAssertEqual(try wirePath(link.appThemeURL), RemoteRouter.appThemePath)
            case .notifications:
                XCTAssertEqual(
                    try wirePath(link.notificationRegistrationURL),
                    RemoteRouter.notificationRegistrationPath
                )
            case .diagnostics:
                XCTAssertEqual(
                    try wirePath(link.diagnosticUploadURL),
                    RemoteRouter.diagnosticUploadPath
                )
            case .localDiagnosticsCapture:
                XCTAssertEqual(
                    try wirePath(link.mobileDiagnosticsCaptureUploadURL),
                    RemoteRouter.mobileDiagnosticsCaptureUploadPath
                )
            case .invitationAcceptance:
                XCTAssertEqual(
                    try wirePath(link.invitationAcceptanceURL),
                    RemoteRouter.invitationAcceptancePath
                )
            case .hostedDeviceCredential:
                XCTAssertEqual(
                    try wirePath(link.hostedDeviceCredentialURL),
                    RemoteRouter.hostedDeviceCredentialPath
                )
            case .settings:
                // Named rather than skipped: `RemoteConnectionLink` builds **no** URL for this
                // route, and neither the iPhone nor the browser client calls it — today the only
                // client of `/api/settings/<identity>` is a hand-spelled path in
                // `RemoteServerIntegrationTests`. So there is nothing to round-trip; what can
                // still be pinned is that the host matches the route this enum defines.
                XCTAssertEqual(
                    RemoteRouter.appSettingIdentity(
                        forPath: RemoteRoute.settings.prefix + "remoteAccessEnabled"
                    ),
                    "remoteAccessEnabled",
                    "the host must keep matching \(RemoteRoute.settings.prefix)<identity>"
                )
                XCTAssertNil(
                    RemoteRouter.appSettingIdentity(forPath: RemoteRoute.settings.absolutePath),
                    "the bare route addresses no setting"
                )
            }
        }
    }

    // MARK: - Session actions

    func testEverySessionActionURLTheClientBuildsIsMatchedByTheHost() throws {
        for action in RemoteSessionRouteAction.allCases {
            let built: String
            let matched: String?

            switch action {
            case .resume:
                built = try wirePath(link.resumeURL(sessionID: sessionID))
                matched = RemoteRouter.resumeSessionID(forPath: built)
            case .theme:
                built = try wirePath(link.sessionThemeURL(sessionID: sessionID))
                matched = RemoteRouter.themeSessionID(forPath: built)
            case .rename:
                built = try wirePath(link.renameSessionURL(sessionID: sessionID))
                matched = RemoteRouter.renameSessionID(forPath: built)
            case .pinned:
                built = try wirePath(link.pinnedSessionURL(sessionID: sessionID))
                matched = RemoteRouter.pinnedSessionID(forPath: built)
            case .archived:
                built = try wirePath(link.archivedSessionURL(sessionID: sessionID))
                matched = RemoteRouter.archivedSessionID(forPath: built)
            case .snoozed:
                built = try wirePath(link.snoozedSessionURL(sessionID: sessionID))
                matched = RemoteRouter.snoozedSessionID(forPath: built)
            case .surface:
                built = try wirePath(link.sessionSurfaceURL(sessionID: sessionID))
                matched = RemoteRouter.surfaceSessionID(forPath: built)
            case .account:
                built = try wirePath(link.sessionAccountURL(sessionID: sessionID))
                matched = RemoteRouter.accountSessionID(forPath: built)
            case .limitRecovery:
                built = try wirePath(link.sessionLimitRecoveryURL(sessionID: sessionID))
                matched = RemoteRouter.limitRecoverySessionID(forPath: built)
            case .share:
                built = try wirePath(link.sessionShareURL(sessionID: sessionID))
                matched = RemoteRouter.shareSessionID(forPath: built)
            case .unshare:
                built = try wirePath(link.sessionUnshareURL(sessionID: sessionID))
                matched = RemoteRouter.unshareSessionID(forPath: built)
            case .gitReview:
                // The only session action carrying a component after it, so it has its own
                // parser on the host. Every mode is walked separately below.
                built = try wirePath(link.gitReviewURL(sessionID: sessionID, mode: .staged))
                matched = RemoteRouter.gitReviewRoute(forPath: built)?.sessionID
            case .repositoryFiles:
                built = try wirePath(link.repositoryFilesURL(sessionID: sessionID))
                matched = RemoteRouter.repositoryFilesSessionID(forPath: built)
            case .repositoryFile:
                built = try wirePath(
                    XCTUnwrap(link.repositoryFileURL(sessionID: sessionID, path: "Sources/App.swift"))
                )
                matched = RemoteRouter.repositoryFileSessionID(forPath: built)
            case .attachments:
                built = try wirePath(link.attachmentsURL(sessionID: sessionID))
                matched = RemoteRouter.attachmentsSessionID(forPath: built)
            case .attachment:
                built = try wirePath(
                    XCTUnwrap(link.attachmentURL(sessionID: sessionID, id: "attachment-1"))
                )
                matched = RemoteRouter.attachmentSessionID(forPath: built)
            case .attachmentThumbnail:
                built = try wirePath(
                    XCTUnwrap(link.attachmentThumbnailURL(sessionID: sessionID, id: "attachment-1"))
                )
                matched = RemoteRouter.attachmentThumbnailSessionID(forPath: built)
            case .attachmentUpload:
                built = try wirePath(link.attachmentUploadURL(sessionID: sessionID))
                matched = RemoteRouter.attachmentUploadSessionID(forPath: built)
            case .workspace:
                built = try wirePath(link.workspaceURL(sessionID: sessionID))
                matched = RemoteRouter.workspaceSessionID(forPath: built)
            case .browserPreview:
                built = try wirePath(
                    XCTUnwrap(link.browserPreviewURL(sessionID: sessionID, tabID: "tab-1"))
                )
                matched = RemoteRouter.browserPreviewSessionID(forPath: built)
            case .extensionPanel:
                built = try wirePath(XCTUnwrap(link.extensionPanelURL(
                    sessionID: sessionID,
                    extensionIdentifier: "com.example.extension",
                    panelID: "panel-1"
                )))
                matched = RemoteRouter.extensionPanelSessionID(forPath: built)
            case .extensionPanelResource:
                built = try wirePath(XCTUnwrap(link.extensionPanelResourceURL(
                    sessionID: sessionID,
                    extensionIdentifier: "com.example.extension",
                    panelID: "panel-1",
                    path: "index.html"
                )))
                matched = RemoteRouter.extensionPanelResourceSessionID(forPath: built)
            }

            XCTAssertTrue(
                built.hasPrefix(RemoteRoute.session.prefix),
                "the client built \(action.rawValue) outside \(RemoteRoute.session.prefix): \(built)"
            )
            XCTAssertEqual(
                matched,
                sessionID,
                "the host did not recognise the URL the client builds for "
                    + "`\(action.rawValue)` — it received \(built)"
            )
        }
    }

    // MARK: - Terminal actions

    func testEveryTerminalActionURLTheClientBuildsIsMatchedByTheHost() throws {
        for action in RemoteTerminalRouteAction.allCases {
            let built: String
            let matched: String?

            switch action {
            case .resume:
                built = try wirePath(link.resumeTerminalURL(terminalID: terminalID))
                matched = RemoteRouter.resumeTerminalID(forPath: built)
            case .share:
                built = try wirePath(link.terminalShareURL(terminalID: terminalID))
                matched = RemoteRouter.shareTerminalID(forPath: built)
            case .unshare:
                built = try wirePath(link.terminalUnshareURL(terminalID: terminalID))
                matched = RemoteRouter.unshareTerminalID(forPath: built)
            }

            XCTAssertTrue(
                built.hasPrefix(RemoteRoute.terminal.prefix),
                "the client built \(action.rawValue) outside \(RemoteRoute.terminal.prefix): \(built)"
            )
            XCTAssertEqual(
                matched,
                terminalID,
                "the host did not recognise the URL the client builds for "
                    + "terminal `\(action.rawValue)` — it received \(built)"
            )
        }
    }

    // MARK: - WebSocket routes

    func testEveryWebSocketRouteTheClientBuildsIsMatchedByTheHost() throws {
        for route in RemoteSocketRoute.allCases {
            switch route {
            case .events:
                let built = try wirePath(XCTUnwrap(link.eventsWebSocketURL))
                XCTAssertEqual(built, RemoteRouter.themeEventsPath)
            case .session:
                let built = try wirePath(XCTUnwrap(link.webSocketURL(sessionID: sessionID)))
                XCTAssertTrue(
                    built.hasPrefix(RemoteSocketRoute.session.prefix),
                    "the client built its session socket outside "
                        + "\(RemoteSocketRoute.session.prefix): \(built)"
                )
                XCTAssertEqual(
                    RemoteRouter.webSocketSessionID(forPath: built),
                    sessionID,
                    "the host did not recognise the session upgrade path the client opens: \(built)"
                )
            case .terminal:
                let built = try wirePath(XCTUnwrap(link.terminalWebSocketURL(terminalID: terminalID)))
                XCTAssertTrue(
                    built.hasPrefix(RemoteSocketRoute.terminal.prefix),
                    "the client built its terminal socket outside "
                        + "\(RemoteSocketRoute.terminal.prefix): \(built)"
                )
                XCTAssertEqual(
                    RemoteRouter.webSocketTerminalID(forPath: built),
                    terminalID,
                    "the host did not recognise the terminal upgrade path the client opens: \(built)"
                )
            }
        }
    }

    // MARK: - Git review modes

    func testEveryGitReviewModeTheClientBuildsIsMatchedByTheHost() throws {
        for mode in RemoteGitReviewMode.allCases {
            let built = try wirePath(link.gitReviewURL(sessionID: sessionID, mode: mode))
            XCTAssertEqual(
                RemoteRouter.gitReviewRoute(forPath: built),
                RemoteRouter.GitReviewRoute(sessionID: sessionID, mode: mode),
                "the host did not read back the git-review request the client builds for "
                    + "`\(mode.rawValue)` — it received \(built)"
            )
        }
    }

    // MARK: - Identifiers that need escaping

    /// What both ends do with an id that is not URL-safe, asserted as observed rather than as
    /// hoped for.
    ///
    /// `RemoteConnectionLink` appends every id as its own path component, so Foundation
    /// percent-escapes it; `RemoteRouter` does no decoding at all. The two are therefore
    /// *coherent* but not *identical*: the host reads back the escaped spelling, and a caller
    /// that wants the original has to decode it. Real ids are UUIDs and provider tokens, so this
    /// has never bitten — but writing it down means a future decode added on either side has to
    /// be added on both.
    func testAnIdentifierNeedingEscapingStaysCoherentAcrossTheBoundary() throws {
        let spacedID = "session with space"
        let escapedID = "session%20with%20space"

        let built = try wirePath(link.renameSessionURL(sessionID: spacedID))
        XCTAssertEqual(
            built,
            RemoteRoute.session.prefix + escapedID + "/" + RemoteSessionRouteAction.rename.rawValue
        )

        let matched = RemoteRouter.renameSessionID(forPath: built)
        XCTAssertEqual(
            matched,
            escapedID,
            "the host reads the wire spelling; it does not percent-decode a path component"
        )
        XCTAssertNotEqual(
            matched,
            spacedID,
            "so an id needing escaping does not round-trip byte for byte — that is the "
                + "behaviour, and a decode added to either end must be added to both"
        )
        XCTAssertEqual(
            matched?.removingPercentEncoding,
            spacedID,
            "coherent rather than lossy: the escaped id is still exactly one path segment"
        )
    }

    /// A slash is the one character `appendingPathComponent` leaves alone, so an id containing
    /// one becomes real path segments rather than an escaped component. Both ends stay safe
    /// because the host refuses a multi-segment id instead of silently accepting a truncated
    /// one — the failure is closed, which is the property worth pinning.
    ///
    /// Asserted on a REST matcher and on **both** socket matchers, because the guard has to be
    /// the same answer everywhere an id is read out of a path. `webSocketSessionID` was the one
    /// exception: it read `/ws/session/a/b` back as the id `"a/b"` and upgraded the connection
    /// with it. Nothing built that route and `SessionID(uuidString:)` rejected the result a step
    /// later, so it cost nothing — but "one matcher answers differently from its four neighbours"
    /// is the shape a real refusal gets lost in, so the asymmetry is pinned closed here.
    func testAnIdentifierCarryingASlashIsRefusedRatherThanTruncated() throws {
        let renamed = try wirePath(link.renameSessionURL(sessionID: "tenant/session"))
        XCTAssertEqual(
            renamed,
            "/api/session/tenant/session/rename",
            "Foundation does not escape a slash inside a path component"
        )
        XCTAssertNil(
            RemoteRouter.renameSessionID(forPath: renamed),
            "the host must refuse a multi-segment id rather than read back a truncated one"
        )

        let socket = try wirePath(XCTUnwrap(link.webSocketURL(sessionID: "tenant/session")))
        XCTAssertEqual(
            socket,
            "/ws/session/tenant/session",
            "the socket builder leaves a slash unescaped for the same reason"
        )
        XCTAssertNil(
            RemoteRouter.webSocketSessionID(forPath: socket),
            "a session upgrade must refuse a multi-segment id, not route the connection to `a/b`"
        )

        let terminal = try wirePath(
            XCTUnwrap(link.terminalWebSocketURL(terminalID: "tenant/terminal"))
        )
        XCTAssertEqual(terminal, "/ws/terminal/tenant/terminal")
        XCTAssertNil(
            RemoteRouter.webSocketTerminalID(forPath: terminal),
            "a terminal upgrade must refuse a multi-segment id"
        )
    }

    // MARK: - Header casing

    /// After Step 3 of this refactor the shipping client sends `RemoteHeader`'s lowercase
    /// spelling, while every iPhone already in the field sends title case. HTTP header names are
    /// case-insensitive and `MCPConnection` lowercases them as it parses, so the host has to keep
    /// reading both — and this is the assertion that says so in terms of the enum.
    ///
    /// The title-case fixtures in `RemoteServerIntegrationTests` are the other half of this and
    /// are deliberately left as literals; see the note above its `// MARK: - Probing` section.
    func testEveryProtocolHeaderReachesTheHostInEitherCasing() throws {
        for header in RemoteHeader.allCases {
            for spelling in [header.rawValue, header.rawValue.uppercased()] {
                let request = try parsedRequest(headerName: spelling, value: "value-1")
                XCTAssertEqual(
                    request.header(header.rawValue),
                    "value-1",
                    "the host stopped reading `\(header.rawValue)` when a client spells it "
                        + "`\(spelling)`"
                )
            }
        }
    }

    /// The client-kind header specifically, in the four combinations that are actually in the
    /// wild: the name in either casing, the value in either casing. The host's own comparison is
    /// `request.header(RemoteRouter.clientHeader)?.lowercased() == RemoteClientKind.iOS.rawValue`
    /// — spelled the same way here so this test moves if that comparison does.
    func testTheHostRecognisesEitherCasingOfTheClientKindHeader() throws {
        let nameSpellings = ["X-Threading-Client", RemoteHeader.client.rawValue]
        let valueSpellings = ["Threading-iOS", RemoteClientKind.iOS.rawValue]

        for name in nameSpellings {
            for value in valueSpellings {
                let request = try parsedRequest(headerName: name, value: value)
                XCTAssertEqual(
                    request.header(RemoteRouter.clientHeader)?.lowercased(),
                    RemoteClientKind.iOS.rawValue,
                    "a client sending `\(name): \(value)` must still classify as "
                        + "\(RemoteClientKind.iOS.rawValue)"
                )
            }
        }

        let web = try parsedRequest(headerName: "X-Threading-Client", value: "Threading-Web")
        XCTAssertEqual(
            web.header(RemoteRouter.clientHeader)?.lowercased(),
            RemoteClientKind.web.rawValue
        )
    }

    // MARK: - The bundled web client

    /// `Sources/Threading/Resources/RemoteClient/app.js` is a **fourth** spelling of this
    /// protocol — it cannot import a Swift enum, so nothing but a test keeps it in step. These
    /// assertions derive their expectations from the enums, so renaming a route turns them red
    /// and names the JavaScript as the file that has to change with it.
    private func clientScript() throws -> String {
        let bundle = Bundle.main
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "app.js",
                withExtension: nil,
                subdirectory: RemoteRouter.clientDirectory
            ),
            "the bundled web client is missing from \(bundle.bundlePath)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheBundledWebClientStillSpellsTheRoutesTheEnumsDefine() throws {
        let script = try clientScript()

        for route in RemoteRoute.allCases {
            let spelledWhole: Bool
            switch route {
            case .me, .diagnostics, .invitationAcceptance:
                spelledWhole = true
            case .session, .terminal:
                // Composed from segments rather than spelled whole — pinned by the test below.
                spelledWhole = false
            case .search, .usage, .usageLimit, .theme, .notifications, .localDiagnosticsCapture,
                 .hostedDeviceCredential, .settings:
                // Native-client surfaces the browser page does not offer. If one of these gains
                // a browser affordance, move it into the first arm rather than leaving it here.
                spelledWhole = false
            }
            guard spelledWhole else { continue }
            XCTAssertTrue(
                script.contains("\"\(route.absolutePath)\""),
                "Sources/Threading/Resources/RemoteClient/app.js no longer requests "
                    + "\(route.absolutePath) — a route renamed in ThreadingRemoteKit has to be "
                    + "renamed in that file too, it cannot import the enum"
            )
        }

        XCTAssertTrue(
            script.contains("\"\(RemoteSocketRoute.events.absolutePath)\""),
            "Sources/Threading/Resources/RemoteClient/app.js no longer opens "
                + "\(RemoteSocketRoute.events.absolutePath)"
        )
    }

    /// The browser client concatenates its session and terminal routes out of segments — one
    /// variable serves both the REST path and the socket path — so there is no whole string to
    /// match. Pin the pieces, and pin the fact that REST and socket agree on the segment names.
    func testTheBundledWebClientComposesTheSessionAndTerminalRoutesFromTheSameSegments() throws {
        let script = try clientScript()

        let restSession = RemoteRoute.session.rawValue.split(separator: "/").map(String.init)
        let restTerminal = RemoteRoute.terminal.rawValue.split(separator: "/").map(String.init)
        XCTAssertEqual(restSession.count, 2)
        XCTAssertEqual(restTerminal.count, 2)

        let restRoot = restSession[0]
        let sessionSegment = restSession[1]
        let terminalSegment = restTerminal[1]
        let socketRoot = RemoteSocketRoute.session.pathComponents[0]

        XCTAssertEqual(restTerminal[0], restRoot, "both REST routes live under one root")
        XCTAssertEqual(RemoteSocketRoute.terminal.pathComponents[0], socketRoot)
        XCTAssertEqual(
            RemoteSocketRoute.session.pathComponents[1],
            sessionSegment,
            "the browser client uses one variable for the REST target and the socket target, so "
                + "these two segments must stay equal"
        )
        XCTAssertEqual(RemoteSocketRoute.terminal.pathComponents[1], terminalSegment)

        XCTAssertTrue(
            script.contains("\"\(terminalSegment)\" ? \"\(terminalSegment)\" : \"\(sessionSegment)\""),
            "app.js picks its route segment with a ternary over "
                + "`\(terminalSegment)`/`\(sessionSegment)`"
        )
        XCTAssertTrue(
            script.contains(
                "fetch(\"/\(restRoot)/\" + targetPath + \"/\" + encodeURIComponent(session.id) "
                    + "+ \"/\(RemoteSessionRouteAction.resume.rawValue)\""
            ),
            "app.js composes its resume request from `/\(restRoot)/` and "
                + "`/\(RemoteSessionRouteAction.resume.rawValue)`"
        )
        XCTAssertTrue(
            script.contains("\"/\(socketRoot)/\" + socketTarget + \"/\""),
            "app.js composes its session socket from `/\(socketRoot)/`"
        )
    }

    /// Header names and the client-kind value, compared case-insensitively because that is how
    /// the host compares them: `MCPConnection` lowercases every name it parses and
    /// `RemoteAccessServer` lowercases the client-kind value before matching.
    func testTheBundledWebClientStillSendsTheHeadersTheEnumDefines() throws {
        let script = try clientScript().lowercased()

        for header in RemoteHeader.allCases {
            XCTAssertTrue(
                script.contains("\"\(header.rawValue)\""),
                "Sources/Threading/Resources/RemoteClient/app.js no longer sends "
                    + "`\(header.rawValue)`"
            )
        }

        XCTAssertTrue(
            script.contains("\"\(RemoteClientKind.web.rawValue)\""),
            "Sources/Threading/Resources/RemoteClient/app.js must keep introducing itself as "
                + "`\(RemoteClientKind.web.rawValue)`, which is what routes its diagnostics to "
                + "the browser source"
        )
    }
}
