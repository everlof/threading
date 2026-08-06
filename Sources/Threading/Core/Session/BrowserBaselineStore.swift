import CryptoKit
import Foundation
import ImageIO

// MARK: - Identity

/// A visual baseline's stable identity.
///
/// Names are a handle the user types and may change; this is what a comparison result quotes back
/// so a rename cannot make an earlier answer ambiguous.
struct BrowserBaselineID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One immutable capture inside a baseline's history.
struct BrowserBaselineRevisionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Provenance

/// Who made this capture, which is not the same question as who may read it.
///
/// The distinction is the reason the two are separate fields rather than one "trusted" bit. A
/// user's capture gesture and the name they typed are user-authored intent; the URL, the pixels
/// and the page state inside them stay untrusted page data either way.
enum BrowserBaselineProvenance: String, Codable, Sendable, CaseIterable {
    /// Captured or approved by the user through Threading's own UI.
    case userCaptured = "user_captured"
    /// Captured by an agent through `browser_baselines`.
    case agentCaptured = "agent_captured"
    /// A design image imported from outside the browser. It has no page of its own, so it never
    /// enters an ordinary pass/fail comparison — see `agent-browser.md`.
    case importedReference = "imported_reference"

    var isUserOwned: Bool { self == .userCaptured }
}

/// What part of the page one capture covers. The coordinate space each one implies is stated in
/// `docs/architecture/agent-browser.md`; nothing here scales one into another.
enum BrowserBaselineCaptureKind: String, Codable, Sendable, CaseIterable {
    case viewport
    case fullPage = "full_page"
    case element
}

// MARK: - Conditions

/// Everything about the browser that decided these pixels.
///
/// Stored beside the PNG rather than derived later: a baseline whose viewport, zoom, colour scheme
/// or user-agent override is unknown cannot be compared honestly, and by the time anyone asks, the
/// browser has moved on.
struct BrowserBaselineConditions: Codable, Equatable, Sendable {
    /// Fragment-stripped, so the same page reached by two anchors is one baseline.
    let url: String
    let origin: String
    let captureKind: BrowserBaselineCaptureKind
    let pixelWidth: Int
    let pixelHeight: Int
    let viewportWidth: Double
    let viewportHeight: Double
    let documentWidth: Double
    let documentHeight: Double
    let scrollX: Double
    let scrollY: Double
    let pageZoom: Double
    let colorScheme: String
    let mediaType: String
    /// Only an explicit override; the platform default is absent rather than copied.
    let userAgent: String?
    let browserContext: String
    /// Whether the capture had to stop at a frame or viewport edge.
    let clipped: Bool
    /// A rerender-safe description of an element capture's scope. Refs are document-local and are
    /// deliberately not what a durable record is keyed on.
    let elementScope: BrowserBaselineElementScope?

    /// The project checkout's commit at capture time, when it had one.
    ///
    /// Recorded rather than resolved later, and never acted on: a comparison says which commits the
    /// two captures came from and stops there. Checking out the baseline's commit to reproduce it
    /// would mean stashing and restoring a working tree behind the user, which is the one thing
    /// git-ref capture is explicitly not allowed to do.
    let commitSHA: String?

    private enum CodingKeys: String, CodingKey {
        case url, origin, clipped
        case captureKind = "capture_kind"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case viewportWidth = "viewport_width"
        case viewportHeight = "viewport_height"
        case documentWidth = "document_width"
        case documentHeight = "document_height"
        case scrollX = "scroll_x"
        case scrollY = "scroll_y"
        case pageZoom = "page_zoom"
        case colorScheme = "color_scheme"
        case mediaType = "media_type"
        case userAgent = "user_agent"
        case browserContext = "browser_context"
        case elementScope = "element_scope"
        case commitSHA = "commit_sha"
    }

    init(
        url: String,
        origin: String,
        captureKind: BrowserBaselineCaptureKind,
        pixelWidth: Int,
        pixelHeight: Int,
        viewportWidth: Double,
        viewportHeight: Double,
        documentWidth: Double,
        documentHeight: Double,
        scrollX: Double,
        scrollY: Double,
        pageZoom: Double,
        colorScheme: String,
        mediaType: String,
        userAgent: String?,
        browserContext: String,
        clipped: Bool,
        elementScope: BrowserBaselineElementScope?,
        commitSHA: String? = nil
    ) {
        self.url = url
        self.origin = origin
        self.captureKind = captureKind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.documentWidth = documentWidth
        self.documentHeight = documentHeight
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.pageZoom = pageZoom
        self.colorScheme = colorScheme
        self.mediaType = mediaType
        self.userAgent = userAgent
        self.browserContext = browserContext
        self.clipped = clipped
        self.elementScope = elementScope
        self.commitSHA = commitSHA
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        origin = try c.decode(String.self, forKey: .origin)
        captureKind = try c.decode(BrowserBaselineCaptureKind.self, forKey: .captureKind)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        viewportWidth = try c.decode(Double.self, forKey: .viewportWidth)
        viewportHeight = try c.decode(Double.self, forKey: .viewportHeight)
        documentWidth = try c.decode(Double.self, forKey: .documentWidth)
        documentHeight = try c.decode(Double.self, forKey: .documentHeight)
        scrollX = try c.decode(Double.self, forKey: .scrollX)
        scrollY = try c.decode(Double.self, forKey: .scrollY)
        pageZoom = try c.decode(Double.self, forKey: .pageZoom)
        colorScheme = try c.decode(String.self, forKey: .colorScheme)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        browserContext = try c.decode(String.self, forKey: .browserContext)
        clipped = try c.decode(Bool.self, forKey: .clipped)
        elementScope = try c.decodeIfPresent(BrowserBaselineElementScope.self, forKey: .elementScope)
        // Absent in every revision written before git-ref capture existed, which is an ordinary
        // older record rather than a damaged one.
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA)
    }
}

/// A durable handle on the element a scoped baseline covers.
///
/// A current `eN` ref may be what found it, and is kept only as a hint. What survives a rerender is
/// the evidence beside it: a test id when the page has one, the role and accessible name, and the
/// box it occupied at capture time.
struct BrowserBaselineElementScope: Codable, Equatable, Sendable {
    let testID: String?
    let role: String?
    let name: String?
    let selector: String?
    /// The ref this scope was captured through, for a reader comparing against the same document.
    let capturedRef: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    private enum CodingKeys: String, CodingKey {
        case role, name, selector, x, y, width, height
        case testID = "test_id"
        case capturedRef = "captured_ref"
    }
}

// MARK: - Records

/// One immutable capture. Nothing here is edited after it validates; approval adds a revision and
/// moves a pointer.
struct BrowserBaselineRevision: Codable, Equatable, Sendable, Identifiable {
    let id: BrowserBaselineRevisionID
    let capturedAt: Date
    let provenance: BrowserBaselineProvenance
    let conditions: BrowserBaselineConditions
    /// SHA-256 of the stored PNG, which is what validation re-proves before the directory moves
    /// into place.
    let contentHash: String
    let byteCount: Int
    /// Which session, tab and browser context produced it. Provenance, not routing: a baseline
    /// belongs to the project, and the session that made it may be long gone.
    let sourceSessionID: SessionID?
    let sourceTabID: UUID?
    let note: String?

    /// Whether `diagnostics.json` sits beside the PNG: the page's own report of itself at capture
    /// time. Separate from the visual state because it answers a different question and is read on
    /// a different request.
    let hasDiagnostics: Bool

    /// Whether `state.json` sits beside the PNG.
    ///
    /// A flag rather than an optional payload: the state is the largest thing in the bundle and is
    /// read only when a comparison actually asks for structure. A revision captured before
    /// attribution existed, or one whose capture could not read it, is simply false — and a
    /// structural comparison against it says so rather than inventing an empty tree.
    let hasAttribution: Bool

    private enum CodingKeys: String, CodingKey {
        case id, provenance, conditions, note
        case capturedAt = "captured_at"
        case contentHash = "content_hash"
        case byteCount = "byte_count"
        case sourceSessionID = "source_session_id"
        case sourceTabID = "source_tab_id"
        case hasAttribution = "has_attribution"
        case hasDiagnostics = "has_diagnostics"
    }

    init(
        id: BrowserBaselineRevisionID,
        capturedAt: Date,
        provenance: BrowserBaselineProvenance,
        conditions: BrowserBaselineConditions,
        contentHash: String,
        byteCount: Int,
        sourceSessionID: SessionID?,
        sourceTabID: UUID?,
        note: String?,
        hasAttribution: Bool = false,
        hasDiagnostics: Bool = false
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.provenance = provenance
        self.conditions = conditions
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.sourceSessionID = sourceSessionID
        self.sourceTabID = sourceTabID
        self.note = note
        self.hasAttribution = hasAttribution
        self.hasDiagnostics = hasDiagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BrowserBaselineRevisionID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        provenance = try container.decode(BrowserBaselineProvenance.self, forKey: .provenance)
        conditions = try container.decode(BrowserBaselineConditions.self, forKey: .conditions)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sourceSessionID = try container.decodeIfPresent(SessionID.self, forKey: .sourceSessionID)
        sourceTabID = try container.decodeIfPresent(UUID.self, forKey: .sourceTabID)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        hasAttribution = try container.decodeIfPresent(Bool.self, forKey: .hasAttribution) ?? false
        hasDiagnostics = try container.decodeIfPresent(Bool.self, forKey: .hasDiagnostics) ?? false
    }
}

/// A named baseline and its revision history.
struct BrowserBaseline: Equatable, Sendable, Identifiable {
    let id: BrowserBaselineID
    let projectID: ProjectID
    var name: String
    /// Who created the *record*. A user-captured baseline is never replaced or approved by an
    /// agent, whatever a later revision's own provenance says.
    let provenance: BrowserBaselineProvenance
    /// Whether `browser_baselines` may see this record at all. Private-context captures default to
    /// off: provenance alone is not permission to disclose authenticated pixels later.
    var isAgentReadable: Bool
    /// Oldest first.
    var revisions: [BrowserBaselineRevision]
    var activeRevisionID: BrowserBaselineRevisionID
    let createdAt: Date
    var updatedAt: Date

    var activeRevision: BrowserBaselineRevision? {
        revisions.first { $0.id == activeRevisionID } ?? revisions.last
    }

    var totalByteCount: Int {
        revisions.reduce(0) { $0 + $1.byteCount }
    }
}

// MARK: - Capture request

/// What a caller hands the store to make a capture durable.
///
/// One shape for both parties, so a user's Save as Baseline and an agent's `browser_baselines
/// capture` cannot drift into two different records of the same page.
struct BrowserBaselineCaptureRequest {
    var name: String
    var pngData: Data
    var conditions: BrowserBaselineConditions
    var provenance: BrowserBaselineProvenance
    var isAgentReadable: Bool
    var sourceSessionID: SessionID?
    var sourceTabID: UUID?
    var note: String?
    /// The bounded visual-attribution state captured beside the pixels, already encoded. Absent is
    /// ordinary: only a caller that asked for structure pays for it.
    var attributionJSON: Data?
    /// The page's own report of itself — timings, console, network, accessibility — already
    /// encoded. Absent is ordinary for the same reason.
    var diagnosticsJSON: Data?

    init(
        name: String,
        pngData: Data,
        conditions: BrowserBaselineConditions,
        provenance: BrowserBaselineProvenance,
        isAgentReadable: Bool,
        sourceSessionID: SessionID? = nil,
        sourceTabID: UUID? = nil,
        note: String? = nil,
        attributionJSON: Data? = nil,
        diagnosticsJSON: Data? = nil
    ) {
        self.name = name
        self.pngData = pngData
        self.conditions = conditions
        self.provenance = provenance
        self.isAgentReadable = isAgentReadable
        self.sourceSessionID = sourceSessionID
        self.sourceTabID = sourceTabID
        self.note = note
        self.attributionJSON = attributionJSON
        self.diagnosticsJSON = diagnosticsJSON
    }
}

// MARK: - Errors

/// Every refusal this store makes, as a value the MCP layer and the UI can both state plainly.
///
/// A quota is a *visible* refusal rather than a silent eviction: an approved baseline is the user's
/// claim about what correct looks like, and a ring that quietly drops the oldest one would make
/// that claim expire without anybody deciding it should.
enum BrowserBaselineStoreError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong(Int)
    case nameInUse(String)
    case notFound
    case revisionNotFound
    case userOwned
    case invalidImage
    case imageTooLarge(bytes: Int, limit: Int)
    case tooManyBaselines(limit: Int)
    case projectStorageExceeded(limit: Int)
    case writesBlocked
    case unsupportedSchema(version: Int)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return L10n.string("A baseline needs a name.")
        case .nameTooLong(let limit):
            return L10n.format("A baseline name can be at most %lld characters.", Int64(limit))
        case .nameInUse(let name):
            return L10n.format("This project already has a baseline named “%@”.", name)
        case .notFound:
            return L10n.string("That baseline is not in this project.")
        case .revisionNotFound:
            return L10n.string("That baseline revision is no longer stored.")
        case .userOwned:
            return L10n.string(
                "This baseline was captured by the user, so only the user can replace or remove it."
            )
        case .invalidImage:
            return L10n.string("The capture is not a decodable PNG.")
        case .imageTooLarge(let bytes, let limit):
            return L10n.format(
                "The capture is %lld bytes, over the %lld byte limit for one baseline.",
                Int64(bytes),
                Int64(limit)
            )
        case .tooManyBaselines(let limit):
            return L10n.format(
                "This project already holds %lld baselines. Remove one before adding another.",
                Int64(limit)
            )
        case .projectStorageExceeded(let limit):
            return L10n.format(
                "This project’s baselines already use the %lld bytes they are allowed.",
                Int64(limit)
            )
        case .writesBlocked:
            return L10n.string(
                "Baseline storage is read-only because damaged data could not be set aside."
            )
        case .unsupportedSchema(let version):
            return L10n.format(
                "That baseline was written by a newer version of Threading (format %lld).",
                Int64(version)
            )
        case .persistenceFailed(let detail):
            return L10n.format("The baseline could not be saved: %@", detail)
        }
    }
}

// MARK: - Store

/// The project's durable library of approved page pixels.
///
/// **Not the rolling artifact cache.** `DisplayPaneStore.cacheBrowserVisualArtifact` keeps the last
/// few captures and evicts by count, which is right for evidence and wrong for a claim: a baseline
/// the user approved on Monday must still be there on Friday, and a store that silently drops it
/// turns "this page regressed" into "there is nothing to compare with".
///
/// **Per project, not per session.** "The approved sign-in page" outlives the chat that captured it.
/// Every revision still records the session, tab and context that produced it, so provenance is not
/// lost — but deleting a session does not delete the project's baselines, and MCP routing stays
/// session-scoped by resolving the session's project first.
///
/// **One immutable directory per revision.** A revision holds its own `manifest.json` and
/// `baseline.png`, so the record and its bytes are one recoverable bundle. Writes land in a sibling
/// staging directory, are re-read and re-hashed there, and only then move into place — the active
/// pointer never advances onto a revision that has not proven itself, so a failed replacement
/// leaves the last approved image exactly where it was.
///
/// **Damage is set aside, never deleted.** A record that will not decode is moved under
/// `Quarantine/`, matching the posture `ProjectStore` takes with a database it cannot open. If even
/// that fails, writes are blocked rather than continuing over data nobody has looked at.
@MainActor
final class BrowserBaselineStore {

    // MARK: Properties

    /// Hosted tests run against the real type, under their own root: this store writes PNGs into
    /// Application Support, and the developer's own baselines are not a test's to grow.
    static let shared: BrowserBaselineStore = {
        guard NSClassFromString("XCTestCase") == nil else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ThreadingTestBaselines/\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            return BrowserBaselineStore(root: scratch)
        }
        return BrowserBaselineStore(root: BrowserBaselineStore.applicationRoot)
    }()

    static var applicationRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                ProjectIconDefaults.applicationDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                BrowserBaselineDefaults.rootDirectoryName,
                isDirectory: true
            )
    }

    let root: URL
    private let fileManager: FileManager
    private let now: () -> Date

    private var baselinesByProject: [ProjectID: [BrowserBaseline]] = [:]
    private var loadedProjects: Set<ProjectID> = []

    /// How many records in a project were written by a newer Threading and were therefore left
    /// alone. Distinct from corruption on purpose: downgrading and losing a colleague's baselines
    /// is not a recovery, and the honest answer is that this build cannot read them.
    private var unsupportedCountByProject: [ProjectID: Int] = [:]

    /// Set when damaged data could not be moved aside. Reads continue; every write refuses, because
    /// writing over something we failed to preserve is the one outcome that cannot be undone.
    private(set) var isWriteBlocked = false

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Initialization

    init(
        root: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: Reading

    /// The project's baselines, newest first. Records this build cannot read are not invented into
    /// the list; `unsupportedCount(for:)` says how many were left alone.
    func baselines(for projectID: ProjectID) -> [BrowserBaseline] {
        loadIfNeeded(projectID)
        return (baselinesByProject[projectID] ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// What an agent may see: the same list minus anything the user has not made readable.
    func agentReadableBaselines(for projectID: ProjectID) -> [BrowserBaseline] {
        baselines(for: projectID).filter(\.isAgentReadable)
    }

    func unsupportedCount(for projectID: ProjectID) -> Int {
        loadIfNeeded(projectID)
        return unsupportedCountByProject[projectID] ?? 0
    }

    func baseline(id: BrowserBaselineID, in projectID: ProjectID) -> BrowserBaseline? {
        loadIfNeeded(projectID)
        return baselinesByProject[projectID]?.first { $0.id == id }
    }

    /// Exact-name resolution, and only when the name is unique in the project.
    ///
    /// Names are a convenience handle, not identity: a caller that asks by name gets the resolved
    /// id back so a later rename cannot make its answer ambiguous in hindsight. Case and surrounding
    /// whitespace are normalized because the two spellings are the same claim to whoever typed it.
    func baseline(named name: String, in projectID: ProjectID) -> BrowserBaseline? {
        let key = Self.normalizedName(name)
        guard !key.isEmpty else { return nil }
        loadIfNeeded(projectID)
        let matches = (baselinesByProject[projectID] ?? []).filter {
            Self.normalizedName($0.name) == key
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func revision(
        _ revisionID: BrowserBaselineRevisionID,
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) -> BrowserBaselineRevision? {
        baseline(id: baselineID, in: projectID)?.revisions.first { $0.id == revisionID }
    }

    /// The PNG bytes of one revision, re-read from disk rather than cached: these are screenshots,
    /// and holding a project's worth of them in memory to save a file read is the wrong trade.
    func pngData(
        forRevision revisionID: BrowserBaselineRevisionID,
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) throws -> Data {
        let url = pngURL(forRevision: revisionID, of: baselineID, in: projectID)
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BrowserBaselineStoreError.revisionNotFound
        }
    }

    /// The bounded page state stored beside one revision's pixels, when it has any.
    ///
    /// Returned as bytes rather than as a decoded tree: the store has no business knowing the shape
    /// of a browser value, and the one caller that needs it decodes it against the type it owns.
    func attributionJSON(
        forRevision revisionID: BrowserBaselineRevisionID,
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) -> Data? {
        try? Data(
            contentsOf: revisionDirectory(revisionID, of: baselineID, in: projectID)
                .appendingPathComponent(BrowserBaselineDefaults.stateFileName),
            options: .mappedIfSafe
        )
    }

    /// The page's own report stored beside one revision's pixels, when it has one.
    func diagnosticsJSON(
        forRevision revisionID: BrowserBaselineRevisionID,
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) -> Data? {
        try? Data(
            contentsOf: revisionDirectory(revisionID, of: baselineID, in: projectID)
                .appendingPathComponent(BrowserBaselineDefaults.diagnosticsFileName),
            options: .mappedIfSafe
        )
    }

    func pngURL(
        forRevision revisionID: BrowserBaselineRevisionID,
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) -> URL {
        revisionDirectory(revisionID, of: baselineID, in: projectID)
            .appendingPathComponent(BrowserBaselineDefaults.imageFileName)
    }

    /// The bytes of whichever revision is active, with the revision that supplied them.
    func activePNG(
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) throws -> (revision: BrowserBaselineRevision, data: Data) {
        guard let baseline = baseline(id: baselineID, in: projectID),
              let revision = baseline.activeRevision else {
            throw BrowserBaselineStoreError.notFound
        }
        return (
            revision,
            try pngData(forRevision: revision.id, of: baselineID, in: projectID)
        )
    }

    func totalByteCount(for projectID: ProjectID) -> Int {
        baselines(for: projectID).reduce(0) { $0 + $1.totalByteCount }
    }

    // MARK: Writing

    /// Creates a new baseline from one capture.
    @discardableResult
    func createBaseline(
        _ request: BrowserBaselineCaptureRequest,
        in projectID: ProjectID
    ) throws -> BrowserBaseline {
        try requireWritable()
        let name = try validatedName(request.name, in: projectID, excluding: nil)
        loadIfNeeded(projectID)

        let existing = baselinesByProject[projectID] ?? []
        guard existing.count < BrowserBaselineDefaults.maximumBaselinesPerProject else {
            throw BrowserBaselineStoreError.tooManyBaselines(
                limit: BrowserBaselineDefaults.maximumBaselinesPerProject
            )
        }
        try requireProjectSpace(for: request.pngData.count, in: projectID, freeing: 0)

        let baselineID = BrowserBaselineID()
        let revision = try writeRevision(request, for: baselineID, in: projectID)
        let timestamp = now()
        let baseline = BrowserBaseline(
            id: baselineID,
            projectID: projectID,
            name: name,
            provenance: request.provenance,
            isAgentReadable: request.isAgentReadable,
            revisions: [revision],
            activeRevisionID: revision.id,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        do {
            try writeRecord(baseline)
        } catch {
            try? fileManager.removeItem(at: baselineDirectory(baselineID, in: projectID))
            throw error
        }
        baselinesByProject[projectID, default: []].append(baseline)
        announce(projectID)
        return baseline
    }

    /// Adds a revision and makes it the active one.
    ///
    /// The previous revision keeps its directory and stays recoverable, which is the whole point of
    /// approval being additive: the last image somebody approved is never the thing a replacement
    /// destroys. Only the oldest revisions past the per-baseline cap are removed, and never the
    /// active one.
    @discardableResult
    func addRevision(
        _ request: BrowserBaselineCaptureRequest,
        to baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) throws -> BrowserBaseline {
        try requireWritable()
        loadIfNeeded(projectID)
        guard let index = baselinesByProject[projectID]?.firstIndex(where: { $0.id == baselineID })
        else {
            throw BrowserBaselineStoreError.notFound
        }
        // No ownership guard here on purpose. Who may revise what is an MCP-surface question —
        // the agent path refuses a user-captured record, the user path refuses nothing — and a
        // flag here was both unreachable and, when read, backwards.
        var baseline = baselinesByProject[projectID]![index]
        try requireProjectSpace(for: request.pngData.count, in: projectID, freeing: 0)

        let revision = try writeRevision(request, for: baselineID, in: projectID)
        var revisions = baseline.revisions + [revision]
        let prunable = revisions
            .dropLast()
            .prefix(max(0, revisions.count - BrowserBaselineDefaults.maximumRevisionsPerBaseline))
        revisions.removeFirst(prunable.count)

        baseline.revisions = revisions
        baseline.activeRevisionID = revision.id
        baseline.updatedAt = now()
        do {
            try writeRecord(baseline)
        } catch {
            try? fileManager.removeItem(
                at: revisionDirectory(revision.id, of: baselineID, in: projectID)
            )
            throw error
        }
        // Only once the record naming the new active revision is on disk: a directory removed
        // before that leaves a manifest pointing at bytes that are gone.
        for stale in prunable {
            try? fileManager.removeItem(
                at: revisionDirectory(stale.id, of: baselineID, in: projectID)
            )
        }
        baselinesByProject[projectID]![index] = baseline
        announce(projectID)
        return baseline
    }

    /// Moves the active pointer to a revision that is already stored — the undo beside approval.
    @discardableResult
    func activateRevision(
        _ revisionID: BrowserBaselineRevisionID,
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) throws -> BrowserBaseline {
        try requireWritable()
        loadIfNeeded(projectID)
        guard let index = baselinesByProject[projectID]?.firstIndex(where: { $0.id == baselineID })
        else {
            throw BrowserBaselineStoreError.notFound
        }
        var baseline = baselinesByProject[projectID]![index]
        guard baseline.revisions.contains(where: { $0.id == revisionID }) else {
            throw BrowserBaselineStoreError.revisionNotFound
        }
        baseline.activeRevisionID = revisionID
        baseline.updatedAt = now()
        try writeRecord(baseline)
        baselinesByProject[projectID]![index] = baseline
        announce(projectID)
        return baseline
    }

    @discardableResult
    func rename(
        _ baselineID: BrowserBaselineID,
        in projectID: ProjectID,
        to name: String
    ) throws -> BrowserBaseline {
        try requireWritable()
        let validated = try validatedName(name, in: projectID, excluding: baselineID)
        guard let index = baselinesByProject[projectID]?.firstIndex(where: { $0.id == baselineID })
        else {
            throw BrowserBaselineStoreError.notFound
        }
        var baseline = baselinesByProject[projectID]![index]
        baseline.name = validated
        baseline.updatedAt = now()
        try writeRecord(baseline)
        baselinesByProject[projectID]![index] = baseline
        announce(projectID)
        return baseline
    }

    @discardableResult
    func setAgentReadable(
        _ isReadable: Bool,
        for baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) throws -> BrowserBaseline {
        try requireWritable()
        loadIfNeeded(projectID)
        guard let index = baselinesByProject[projectID]?.firstIndex(where: { $0.id == baselineID })
        else {
            throw BrowserBaselineStoreError.notFound
        }
        var baseline = baselinesByProject[projectID]![index]
        baseline.isAgentReadable = isReadable
        baseline.updatedAt = now()
        try writeRecord(baseline)
        baselinesByProject[projectID]![index] = baseline
        announce(projectID)
        return baseline
    }

    /// Removes a baseline and its bytes.
    ///
    /// `requiresAgentOwnership` is what the MCP surface passes: an agent may clean up what it
    /// captured and may not delete the user's claim about what correct looks like.
    func delete(
        _ baselineID: BrowserBaselineID,
        in projectID: ProjectID,
        requiresAgentOwnership: Bool = false
    ) throws {
        try requireWritable()
        loadIfNeeded(projectID)
        guard let index = baselinesByProject[projectID]?.firstIndex(where: { $0.id == baselineID })
        else {
            throw BrowserBaselineStoreError.notFound
        }
        let baseline = baselinesByProject[projectID]![index]
        if requiresAgentOwnership, baseline.provenance.isUserOwned {
            throw BrowserBaselineStoreError.userOwned
        }
        do {
            try removeIfPresent(baselineDirectory(baselineID, in: projectID))
        } catch {
            throw BrowserBaselineStoreError.persistenceFailed(error.localizedDescription)
        }
        baselinesByProject[projectID]!.remove(at: index)
        announce(projectID)
    }

    /// Drops the baselines of every project that is no longer in the sidebar.
    ///
    /// Removing a project takes its baselines with it, which is why the removal confirmation says
    /// so. A *session* leaving takes nothing: the library belongs to the project.
    func retainOnly(projectIDs: Set<ProjectID>) {
        baselinesByProject = baselinesByProject.filter { projectIDs.contains($0.key) }
        loadedProjects = loadedProjects.intersection(projectIDs)
        unsupportedCountByProject = unsupportedCountByProject.filter { projectIDs.contains($0.key) }

        let kept = Set(projectIDs.map(\.uuidString))
        let entries = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != BrowserBaselineDefaults.quarantineDirectoryName,
                  !kept.contains(name) else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: Private — validation

    private func requireWritable() throws {
        guard !isWriteBlocked else { throw BrowserBaselineStoreError.writesBlocked }
    }

    private func validatedName(
        _ name: String,
        in projectID: ProjectID,
        excluding baselineID: BrowserBaselineID?
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserBaselineStoreError.emptyName }
        guard trimmed.count <= BrowserBaselineDefaults.maximumNameLength else {
            throw BrowserBaselineStoreError.nameTooLong(BrowserBaselineDefaults.maximumNameLength)
        }
        loadIfNeeded(projectID)
        let key = Self.normalizedName(trimmed)
        let clash = (baselinesByProject[projectID] ?? []).contains {
            $0.id != baselineID && Self.normalizedName($0.name) == key
        }
        guard !clash else { throw BrowserBaselineStoreError.nameInUse(trimmed) }
        return trimmed
    }

    private func requireProjectSpace(
        for additionalBytes: Int,
        in projectID: ProjectID,
        freeing: Int
    ) throws {
        guard additionalBytes <= BrowserBaselineDefaults.maximumImageBytes else {
            throw BrowserBaselineStoreError.imageTooLarge(
                bytes: additionalBytes,
                limit: BrowserBaselineDefaults.maximumImageBytes
            )
        }
        let projected = totalByteCount(for: projectID) - freeing + additionalBytes
        guard projected <= BrowserBaselineDefaults.maximumProjectBytes else {
            throw BrowserBaselineStoreError.projectStorageExceeded(
                limit: BrowserBaselineDefaults.maximumProjectBytes
            )
        }
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Private — writing

    /// Writes one revision into a staging directory, re-proves it there, and only then moves it in.
    ///
    /// Validation re-reads what was written rather than trusting the bytes still in hand: a short
    /// write, a full disk and a truncated PNG all look fine from the caller's side, and the failure
    /// they cause arrives later, as a baseline that will not decode.
    private func writeRevision(
        _ request: BrowserBaselineCaptureRequest,
        for baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) throws -> BrowserBaselineRevision {
        guard let dimensions = BrowserBaselineImage.pixelSize(of: request.pngData) else {
            throw BrowserBaselineStoreError.invalidImage
        }
        guard request.pngData.count <= BrowserBaselineDefaults.maximumImageBytes else {
            throw BrowserBaselineStoreError.imageTooLarge(
                bytes: request.pngData.count,
                limit: BrowserBaselineDefaults.maximumImageBytes
            )
        }

        var conditions = request.conditions
        // The manifest states the pixels that are actually there, not the pixels the caller
        // believed it captured. Everything downstream compares against this.
        conditions = conditions.withPixelSize(
            width: dimensions.width,
            height: dimensions.height
        )

        // Bounded like the PNG beside it: a page whose attribution state is enormous is a page
        // whose state is not worth keeping, and the comparison degrades to pixels rather than
        // letting one capture own the project's byte budget.
        let attribution = request.attributionJSON.flatMap {
            $0.count <= BrowserBaselineDefaults.maximumAttributionBytes ? $0 : nil
        }
        let diagnostics = request.diagnosticsJSON.flatMap {
            $0.count <= BrowserDiagnosticsDefaults.maximumBytes ? $0 : nil
        }
        let revision = BrowserBaselineRevision(
            id: BrowserBaselineRevisionID(),
            capturedAt: now(),
            provenance: request.provenance,
            conditions: conditions,
            contentHash: BrowserBaselineImage.hash(request.pngData),
            byteCount: request.pngData.count + (attribution?.count ?? 0)
                + (diagnostics?.count ?? 0),
            sourceSessionID: request.sourceSessionID,
            sourceTabID: request.sourceTabID,
            note: request.note.map { String($0.prefix(BrowserBaselineDefaults.maximumNoteLength)) },
            hasAttribution: attribution != nil,
            hasDiagnostics: diagnostics != nil
        )

        let baselineDirectory = baselineDirectory(baselineID, in: projectID)
        let staging = baselineDirectory.appendingPathComponent(
            BrowserBaselineDefaults.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        let destination = baselineDirectory.appendingPathComponent(
            revision.id.uuidString,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try request.pngData.write(
                to: staging.appendingPathComponent(BrowserBaselineDefaults.imageFileName),
                options: .atomic
            )
            if let attribution {
                try attribution.write(
                    to: staging.appendingPathComponent(BrowserBaselineDefaults.stateFileName),
                    options: .atomic
                )
            }
            if let diagnostics {
                try diagnostics.write(
                    to: staging.appendingPathComponent(BrowserBaselineDefaults.diagnosticsFileName),
                    options: .atomic
                )
            }
            try Self.encoder
                .encode(StoredRevision(schemaVersion: BrowserBaselineDefaults.schemaVersion, revision: revision))
                .write(
                    to: staging.appendingPathComponent(BrowserBaselineDefaults.manifestFileName),
                    options: .atomic
                )
            try validateStaged(staging, against: revision)
            try removeIfPresent(destination)
            try fileManager.moveItem(at: staging, to: destination)
        } catch let error as BrowserBaselineStoreError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw BrowserBaselineStoreError.persistenceFailed(error.localizedDescription)
        }
        return revision
    }

    private func validateStaged(_ staging: URL, against revision: BrowserBaselineRevision) throws {
        let imageURL = staging.appendingPathComponent(BrowserBaselineDefaults.imageFileName)
        let stateURL = staging.appendingPathComponent(BrowserBaselineDefaults.stateFileName)
        let stateBytes = (try? Data(contentsOf: stateURL))?.count ?? 0
        let diagnosticsURL = staging.appendingPathComponent(
            BrowserBaselineDefaults.diagnosticsFileName
        )
        let diagnosticsBytes = (try? Data(contentsOf: diagnosticsURL))?.count ?? 0
        guard revision.hasDiagnostics == (diagnosticsBytes > 0) else {
            throw BrowserBaselineStoreError.persistenceFailed(
                L10n.string("the captured page state was not stored beside its image")
            )
        }
        guard revision.hasAttribution == (stateBytes > 0) else {
            throw BrowserBaselineStoreError.persistenceFailed(
                L10n.string("the captured page state was not stored beside its image")
            )
        }
        guard let written = try? Data(contentsOf: imageURL),
              written.count + stateBytes + diagnosticsBytes == revision.byteCount,
              BrowserBaselineImage.hash(written) == revision.contentHash,
              let size = BrowserBaselineImage.pixelSize(of: written),
              size.width == revision.conditions.pixelWidth,
              size.height == revision.conditions.pixelHeight else {
            throw BrowserBaselineStoreError.persistenceFailed(
                L10n.string("the stored image did not match what was captured")
            )
        }
        let manifestURL = staging.appendingPathComponent(BrowserBaselineDefaults.manifestFileName)
        guard let manifest = try? Data(contentsOf: manifestURL),
              let stored = try? Self.decoder.decode(StoredRevision.self, from: manifest),
              stored.revision.id == revision.id else {
            throw BrowserBaselineStoreError.persistenceFailed(
                L10n.string("the stored manifest could not be read back")
            )
        }
    }

    private func writeRecord(_ baseline: BrowserBaseline) throws {
        let directory = baselineDirectory(baseline.id, in: baseline.projectID)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stored = StoredBaseline(
                schemaVersion: BrowserBaselineDefaults.schemaVersion,
                id: baseline.id,
                name: baseline.name,
                provenance: baseline.provenance,
                isAgentReadable: baseline.isAgentReadable,
                activeRevisionID: baseline.activeRevisionID,
                revisionIDs: baseline.revisions.map(\.id),
                createdAt: baseline.createdAt,
                updatedAt: baseline.updatedAt
            )
            try Self.encoder.encode(stored).write(
                to: directory.appendingPathComponent(BrowserBaselineDefaults.recordFileName),
                options: .atomic
            )
        } catch {
            throw BrowserBaselineStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: Private — reading

    private func loadIfNeeded(_ projectID: ProjectID) {
        guard !loadedProjects.contains(projectID) else { return }
        loadedProjects.insert(projectID)

        var loaded: [BrowserBaseline] = []
        var unsupported = 0
        let directory = projectDirectory(projectID)
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  !entry.lastPathComponent.hasPrefix(BrowserBaselineDefaults.stagingPrefix) else {
                continue
            }
            switch readBaseline(at: entry, in: projectID) {
            case .loaded(let baseline):
                loaded.append(baseline)
            case .unsupported:
                unsupported += 1
            case .damaged:
                quarantine(entry, projectID: projectID)
            }
        }

        baselinesByProject[projectID] = loaded
        unsupportedCountByProject[projectID] = unsupported
    }

    private enum ReadOutcome {
        case loaded(BrowserBaseline)
        /// Written by a newer Threading. Left exactly as found.
        case unsupported
        case damaged
    }

    private func readBaseline(at directory: URL, in projectID: ProjectID) -> ReadOutcome {
        let recordURL = directory.appendingPathComponent(BrowserBaselineDefaults.recordFileName)
        guard let data = try? Data(contentsOf: recordURL) else { return .damaged }
        guard let version = try? Self.decoder.decode(SchemaProbe.self, from: data).schemaVersion
        else {
            return .damaged
        }
        guard version <= BrowserBaselineDefaults.schemaVersion else { return .unsupported }
        guard let stored = try? Self.decoder.decode(StoredBaseline.self, from: data) else {
            return .damaged
        }

        var revisions: [BrowserBaselineRevision] = []
        for revisionID in stored.revisionIDs {
            let revisionDirectory = directory.appendingPathComponent(
                revisionID.uuidString,
                isDirectory: true
            )
            let manifestURL = revisionDirectory.appendingPathComponent(
                BrowserBaselineDefaults.manifestFileName
            )
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? Self.decoder.decode(StoredRevision.self, from: manifestData),
                  manifest.schemaVersion <= BrowserBaselineDefaults.schemaVersion,
                  fileManager.fileExists(
                    atPath: revisionDirectory
                        .appendingPathComponent(BrowserBaselineDefaults.imageFileName).path
                  ) else {
                continue
            }
            revisions.append(manifest.revision)
        }
        // A record whose every revision has gone is not a baseline anyone can compare against, and
        // leaving it in the list offers a row that answers nothing.
        guard !revisions.isEmpty else { return .damaged }
        revisions.sort { $0.capturedAt < $1.capturedAt }

        let active = revisions.contains { $0.id == stored.activeRevisionID }
            ? stored.activeRevisionID
            : revisions[revisions.count - 1].id

        return .loaded(BrowserBaseline(
            id: stored.id,
            projectID: projectID,
            name: stored.name,
            provenance: stored.provenance,
            isAgentReadable: stored.isAgentReadable,
            revisions: revisions,
            activeRevisionID: active,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        ))
    }

    /// Moves damaged data out of the way, keeping it.
    ///
    /// A failure here blocks writes rather than being logged and forgotten: the next capture would
    /// otherwise write beside data nobody has looked at, in a directory this store has just proven
    /// it cannot manage.
    private func quarantine(_ directory: URL, projectID: ProjectID) {
        let destination = root
            .appendingPathComponent(
                BrowserBaselineDefaults.quarantineDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(
                "\(directory.lastPathComponent)-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: directory, to: destination)
            ThreadingLogger.session.error(
                "Quarantined an unreadable browser baseline at \(directory.lastPathComponent, privacy: .public)"
            )
        } catch {
            isWriteBlocked = true
            ThreadingLogger.session.error(
                "Could not quarantine an unreadable browser baseline: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Private — paths

    private func projectDirectory(_ projectID: ProjectID) -> URL {
        root.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private func baselineDirectory(_ id: BrowserBaselineID, in projectID: ProjectID) -> URL {
        projectDirectory(projectID).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func revisionDirectory(
        _ revisionID: BrowserBaselineRevisionID,
        of baselineID: BrowserBaselineID,
        in projectID: ProjectID
    ) -> URL {
        baselineDirectory(baselineID, in: projectID)
            .appendingPathComponent(revisionID.uuidString, isDirectory: true)
    }

    private func announce(_ projectID: ProjectID) {
        NotificationCenter.default.post(BrowserBaselinesDidChange(projectID: projectID))
    }
}

// MARK: - Change Event

struct BrowserBaselinesDidChange: AppEvent {
    static let name = Notification.Name("browserBaselinesDidChange")
    let projectID: ProjectID
}

// MARK: - Stored Shapes

/// Reads only the version, so a newer record can be recognised before its body is decoded against
/// this build's expectations.
private struct SchemaProbe: Decodable {
    let schemaVersion: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
    }
}

private struct StoredBaseline: Codable {
    let schemaVersion: Int
    let id: BrowserBaselineID
    let name: String
    let provenance: BrowserBaselineProvenance
    let isAgentReadable: Bool
    let activeRevisionID: BrowserBaselineRevisionID
    let revisionIDs: [BrowserBaselineRevisionID]
    let createdAt: Date
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, provenance
        case schemaVersion = "schema_version"
        case isAgentReadable = "agent_readable"
        case activeRevisionID = "active_revision_id"
        case revisionIDs = "revision_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct StoredRevision: Codable {
    let schemaVersion: Int
    let revision: BrowserBaselineRevision

    private enum CodingKeys: String, CodingKey {
        case revision
        case schemaVersion = "schema_version"
    }
}

// MARK: - Conditions Helpers

extension BrowserBaselineConditions {

    /// The same conditions with the pixel dimensions the stored file actually has.
    func withPixelSize(width: Int, height: Int) -> BrowserBaselineConditions {
        BrowserBaselineConditions(
            url: url,
            origin: origin,
            captureKind: captureKind,
            pixelWidth: width,
            pixelHeight: height,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            documentWidth: documentWidth,
            documentHeight: documentHeight,
            scrollX: scrollX,
            scrollY: scrollY,
            pageZoom: pageZoom,
            colorScheme: colorScheme,
            mediaType: mediaType,
            userAgent: userAgent,
            browserContext: browserContext,
            clipped: clipped,
            elementScope: elementScope,
            commitSHA: commitSHA
        )
    }

    /// Whether two captures were taken under conditions that make a pixel comparison meaningful.
    ///
    /// Deliberately not a pass/fail input — a comparison across conditions still runs and still
    /// reports. This is what lets the result *say* the two were not taken the same way, which is
    /// almost always the real explanation for a page-wide difference.
    func differences(from other: BrowserBaselineConditions) -> [String] {
        var differences: [String] = []
        if captureKind != other.captureKind {
            differences.append(
                L10n.format(
                    "capture kind %@ vs %@",
                    other.captureKind.rawValue,
                    captureKind.rawValue
                )
            )
        }
        if Int(viewportWidth) != Int(other.viewportWidth)
            || Int(viewportHeight) != Int(other.viewportHeight) {
            differences.append(
                L10n.format(
                    "viewport %lld×%lld vs %lld×%lld",
                    Int64(other.viewportWidth),
                    Int64(other.viewportHeight),
                    Int64(viewportWidth),
                    Int64(viewportHeight)
                )
            )
        }
        if colorScheme != other.colorScheme {
            differences.append(
                L10n.format("color scheme %@ vs %@", other.colorScheme, colorScheme)
            )
        }
        if mediaType != other.mediaType {
            differences.append(L10n.format("CSS media %@ vs %@", other.mediaType, mediaType))
        }
        if abs(pageZoom - other.pageZoom) > 0.001 {
            differences.append(
                L10n.format(
                    "page zoom %lld%% vs %lld%%",
                    Int64((other.pageZoom * 100).rounded()),
                    Int64((pageZoom * 100).rounded())
                )
            )
        }
        if userAgent != other.userAgent {
            differences.append(L10n.string("user-agent override"))
        }
        if commitSHA != other.commitSHA {
            differences.append(L10n.format(
                "commit %@ vs %@",
                other.commitSHA.map { String($0.prefix(7)) } ?? L10n.string("none"),
                commitSHA.map { String($0.prefix(7)) } ?? L10n.string("none")
            ))
        }
        if captureKind == .viewport,
           Int(scrollX) != Int(other.scrollX) || Int(scrollY) != Int(other.scrollY) {
            differences.append(
                L10n.format(
                    "scroll offset %lld,%lld vs %lld,%lld",
                    Int64(other.scrollX),
                    Int64(other.scrollY),
                    Int64(scrollX),
                    Int64(scrollY)
                )
            )
        }
        return differences
    }
}

// MARK: - Image Helpers

/// The two questions the store asks of a PNG, in one place so the staging validation and the
/// caller's own check cannot answer them differently.
enum BrowserBaselineImage {

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored pixel dimensions, without decoding the whole image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }
}

// MARK: - Defaults

/// Every bound this store is held to.
///
/// The numbers are provisional and say so: `docs/architecture/agent-browser.md` records which of
/// them are waiting on measured capture sizes across viewport, full-page and element captures.
/// What is *not* provisional is that each dimension has a bound and that exceeding a durable one is
/// a visible refusal rather than an eviction.
enum BrowserBaselineDefaults {
    static let rootDirectoryName = "BrowserBaselines"
    static let quarantineDirectoryName = "Quarantine"
    static let recordFileName = "record.json"
    static let manifestFileName = "manifest.json"
    static let imageFileName = "baseline.png"
    static let stateFileName = "state.json"
    static let diagnosticsFileName = "diagnostics.json"
    /// A directory being assembled. Prefixed rather than hidden so a reader can see what a failed
    /// write left behind, and skipped by the loader for the same reason it is not yet a revision.
    static let stagingPrefix = "staging-"

    /// Bumped when a stored shape changes in a way an older build must not guess at.
    static let schemaVersion = 1

    static let maximumNameLength = 120
    static let maximumNoteLength = 400

    /// One capture. Matches the comparison limit, so the store never accepts a baseline the
    /// comparator would refuse to read.
    static let maximumImageBytes = 50 * 1_024 * 1_024
    static let maximumBaselinesPerProject = 200
    static let maximumRevisionsPerBaseline = 20
    static let maximumProjectBytes = 512 * 1_024 * 1_024

    /// One capture's attribution state. Bounded separately from the image because the two grow for
    /// unrelated reasons: a tall screenshot is large in pixels, a component-heavy page in nodes.
    static let maximumAttributionBytes = 4 * 1_024 * 1_024

    /// What one `browser_baselines list` may return, so a project at its cap cannot answer with a
    /// wall of records.
    static let maximumListedBaselines = 50
}
