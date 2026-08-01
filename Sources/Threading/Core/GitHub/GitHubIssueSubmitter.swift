import Foundation

enum GitHubIssueDefaults {
    /// The app's own repository. A ticket raised from inside Threading is about Threading, so
    /// this is a constant rather than a setting: a field pointing it elsewhere would let one
    /// user file this app's diagnostics into a stranger's tracker.
    static let repository = "everlof/threading"

    static let problemLabel = "bug"
    static let improvementLabel = "enhancement"

    /// A title is a line, not a paragraph. The rest of what was typed is already in the body,
    /// so truncation here loses nothing.
    static let titleLimit = 80

    /// Past this the web form's body is cut. A URL is not a transport for a long report, and
    /// browsers, proxies and GitHub itself each draw their own line somewhere above this.
    static let webFormBodyLimit = 6000

    /// The API can carry more than a URL, but a generated diagnostic report is still
    /// input-controlled data. Keep requests comfortably bounded and make truncation explicit.
    static let apiBodyLimit = 60_000
    static let labelCountLimit = 10
    static let labelCharacterLimit = 50

    static let apiVersionHeader = "X-GitHub-Api-Version"
}

/// What is being filed, which decides the label GitHub sees.
enum GitHubIssueKind: String, CaseIterable, Sendable {
    case problem
    case improvement

    var label: String {
        switch self {
        case .problem: return GitHubIssueDefaults.problemLabel
        case .improvement: return GitHubIssueDefaults.improvementLabel
        }
    }
}

/// One issue, before anyone has tried to file it.
struct GitHubIssueDraft: Equatable, Sendable {
    var title: String
    var body: String
    var labels: [String]

    init(title: String, body: String, labels: [String] = []) {
        self.title = title
        self.body = body
        self.labels = labels
    }
}

/// How the attempt ended. Three outcomes, because the user's next move differs in each.
enum GitHubIssueSubmission: Equatable, Sendable {
    /// GitHub created it. The URL is the issue itself.
    case created(url: URL, number: Int, tier: GitHubCredential.Tier)

    /// Nothing was created and nothing is wrong: no credential Threading holds may write here,
    /// so the prefilled web form — where the user's own browser session is the credential — is
    /// the way in. This is also the resting state for a public repository and a signed-out user.
    case webForm(url: URL, message: String)

    /// Nothing to fall back to. Whether GitHub received the request is unknown, which is
    /// exactly why retrying is the user's call and not ours.
    case failed(message: String)
}

/// Files an issue against the app's own repository using the credential chain.
///
/// Written as a POST beside `ExtensionNetworkBroker`'s GET rather than through it: the broker
/// exists to keep a *sandboxed extension* away from a token, and its contract is a read. Three
/// rules here are the write's own, and each one is load-bearing:
///
/// - **Anonymous never posts.** It cannot create an issue under any circumstance, so sending it
///   would buy a guaranteed 401 and a round trip. Its presence in the chain is instead the
///   signal that there is nobody to post *as* — which is what selects the web form.
/// - **A transport failure ends the attempt.** A GET that times out can be retried under the
///   next tier for free; a POST that times out may have created the issue already, and the one
///   thing worse than a failed report is two of them. The user retries deliberately or not at all.
/// - **401/403/404 walk to the next tier, 422 does not.** The first three are "this token may
///   not write here", which says nothing about the next token. 422 is GitHub reading the body
///   and objecting to it — the same objection waits under every credential.
struct GitHubIssueSubmitter: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Refusals that say something about the credential rather than about the issue.
    private static let tierWalkStatuses: Set<Int> = [401, 403, 404]

    let repository: String
    private let resolver: GitHubCredentialResolver?
    private let transport: Transport

    // MARK: - Initialization

    init(
        repository: String = GitHubIssueDefaults.repository,
        resolver: GitHubCredentialResolver?,
        transport: @escaping Transport = GitHubAppConnection.liveTransport
    ) {
        self.repository = repository
        self.resolver = resolver
        self.transport = transport
    }

    @MainActor
    static func live() -> GitHubIssueSubmitter {
        GitHubIssueSubmitter(resolver: .live())
    }

    // MARK: - Public Methods

    func submit(_ draft: GitHubIssueDraft) async -> GitHubIssueSubmission {
        guard let endpoint = URL(
            string: "https://\(GitHubDefaults.apiHost)/repos/\(repository)/issues"
        ) else {
            return .failed(message: L10n.string("Threading could not build the GitHub address."))
        }

        // Only credentials that can act as somebody; see the type's note on anonymous.
        let resolved: [GitHubCredential] = await resolver?.orderedCredentials() ?? [.anonymous]
        let credentials = resolved.filter { $0.token != nil }

        guard !credentials.isEmpty else {
            return webFormOutcome(
                for: draft,
                message: L10n.string("Threading has no GitHub sign-in, so this opens the form in your browser.")
            )
        }

        for credential in credentials {
            switch await attempt(draft, at: endpoint, as: credential) {
            case .created(let url, let number, let tier):
                return .created(url: url, number: number, tier: tier)

            case .transportFailed(let message):
                return .failed(message: message)

            case .refused(let status, let message):
                if status == 401 {
                    await resolver?.invalidate(credential.tier)
                }
                guard Self.tierWalkStatuses.contains(status) else {
                    // GitHub read the issue and objected to it. The next token would hear the
                    // same objection, and the form would carry the same body into it.
                    return .failed(message: message)
                }
            }
        }

        // Every credential was refused for a reason about the credential. The user's browser
        // session is a credential Threading does not have, so it is where this goes next.
        return webFormOutcome(
            for: draft,
            message: L10n.string("GitHub would not accept the report from this Mac's sign-in, so this opens the form in your browser.")
        )
    }

    /// The prefilled `issues/new` page: what a browser session can do that a token here cannot.
    func webFormURL(for draft: GitHubIssueDraft) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = GitHubDefaults.webHost
        components.path = "/\(repository)/issues/new"

        var items = [URLQueryItem(name: "title", value: draft.title)]
        items.append(URLQueryItem(
            name: "body",
            value: Self.truncate(draft.body, to: GitHubIssueDefaults.webFormBodyLimit)
        ))
        if !draft.labels.isEmpty {
            items.append(URLQueryItem(name: "labels", value: draft.labels.joined(separator: ",")))
        }
        components.queryItems = items

        return components.url
    }

    // MARK: - Private Methods

    private enum Attempt {
        case created(url: URL, number: Int, tier: GitHubCredential.Tier)
        case refused(status: Int, message: String)
        case transportFailed(message: String)
    }

    private func attempt(
        _ draft: GitHubIssueDraft,
        at endpoint: URL,
        as credential: GitHubCredential
    ) async -> Attempt {
        var request = URLRequest(url: endpoint, timeoutInterval: GitHubDefaults.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(GitHubDefaults.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(GitHubDefaults.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            GitHubDefaults.apiVersion,
            forHTTPHeaderField: GitHubIssueDefaults.apiVersionHeader
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = credential.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.requestBody(for: draft)

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            return .transportFailed(message: L10n.format(
                "Threading could not reach GitHub: %@",
                error.localizedDescription
            ))
        }

        guard (200..<300).contains(http.statusCode) else {
            return .refused(
                status: http.statusCode,
                message: Self.refusalMessage(status: http.statusCode, body: data)
            )
        }

        guard let created = Self.createdIssue(from: data) else {
            // GitHub accepted it, so the issue exists; only our reading of the answer failed.
            // Saying "failed" here would invite a duplicate.
            return .created(
                url: URL(string: "https://\(GitHubDefaults.webHost)/\(repository)/issues")
                    ?? endpoint,
                number: 0,
                tier: credential.tier
            )
        }
        return .created(url: created.url, number: created.number, tier: credential.tier)
    }

    private func webFormOutcome(
        for draft: GitHubIssueDraft,
        message: String
    ) -> GitHubIssueSubmission {
        guard let url = webFormURL(for: draft) else {
            return .failed(message: L10n.string("Threading could not build the GitHub address."))
        }
        return .webForm(url: url, message: message)
    }

    // MARK: - Wire Format

    private struct IssueRequest: Encodable {
        let title: String
        let body: String
        let labels: [String]?
    }

    private struct CreatedIssueResponse: Decodable {
        let number: Int
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case number
            case htmlURL = "html_url"
        }
    }

    private struct ErrorResponse: Decodable {
        let message: String
    }

    static func requestBody(for draft: GitHubIssueDraft) -> Data? {
        let labels = draft.labels.isEmpty ? nil : draft.labels
            .prefix(GitHubIssueDefaults.labelCountLimit)
            .map { String($0.prefix(GitHubIssueDefaults.labelCharacterLimit)) }
        let payload = IssueRequest(
            title: draft.title,
            body: truncate(draft.body, to: GitHubIssueDefaults.apiBodyLimit),
            labels: labels
        )
        return try? JSONEncoder().encode(payload)
    }

    static func createdIssue(from data: Data) -> (url: URL, number: Int)? {
        guard let response = try? JSONDecoder().decode(CreatedIssueResponse.self, from: data),
              let url = URL(string: response.htmlURL),
              url.scheme == "https",
              url.host != nil else { return nil }
        return (url, response.number)
    }

    /// GitHub's own words when it has them: `message` is the one field every error shares, and
    /// a validation refusal explains itself far better than a status code does.
    static func refusalMessage(status: Int, body: Data) -> String {
        let response = try? JSONDecoder().decode(ErrorResponse.self, from: body)
        guard let detail = response?.message, !detail.isEmpty else {
            return L10n.format("GitHub refused the report (%lld).", status)
        }
        return L10n.format("GitHub refused the report (%lld): %@", status, detail)
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n\n" + L10n.string("_Report truncated._")
        guard marker.count < limit else { return String(marker.prefix(limit)) }
        return String(text.prefix(limit - marker.count)) + marker
    }
}

// MARK: - Composition

/// Turns what the user typed and what the app measured into one issue.
///
/// Kept out of the sheets so both entry points compose the same ticket: an inspector capture and
/// a Help ▸ Report a Problem both arrive in the tracker with the note leading, the evidence
/// under it, and the environment last.
enum GitHubIssueComposer {

    /// The title, when the user was not asked for one: the first line of the note, which is how
    /// people write anyway. Falls back to the report's own name so a note-less capture is still
    /// filed under something a reader can scan.
    static func title(fromNote note: String, fallback: String) -> String {
        let firstLine = note
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !firstLine.isEmpty else { return fallback }
        guard firstLine.count > GitHubIssueDefaults.titleLimit else { return firstLine }
        return String(firstLine.prefix(GitHubIssueDefaults.titleLimit)) + "…"
    }

    /// The note leads, exactly as it does in `InspectorReportComposer` — a reader takes the
    /// instruction before the evidence — and the environment closes under a rule, where a
    /// reader looks for it and a skimmer does not have to.
    static func body(note: String, report: String, environment: String) -> String {
        var parts: [String] = []
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        let evidence = report.trimmingCharacters(in: .whitespacesAndNewlines)
        if !evidence.isEmpty { parts.append(evidence) }
        parts.append("---\n" + environment)
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Environment

/// The three lines every ticket carries about where it came from.
///
/// Deliberately the same three facts the support report opens with — version, build, macOS —
/// and deliberately nothing else. A ticket travels to a tracker that outlives the conversation,
/// so what rides along has to be safe by construction rather than by review, which is the rule
/// `MacRemoteDiagnostics` already states for the file it writes.
enum GitHubIssueEnvironment {
    static func markdown(
        info: [String: Any]? = Bundle.main.infoDictionary,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return L10n.format(
            "Threading %@ (%@) · %@",
            version,
            build,
            operatingSystem
        )
    }
}
