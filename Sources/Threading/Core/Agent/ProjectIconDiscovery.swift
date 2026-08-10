import Foundation

// MARK: - Project Icon Discovery

/// Finds a project's sidebar icon without an agent: the checkout's own favicon or app icon
/// first, then the repository's GitHub owner avatar, then the favicon of the homepage its
/// `package.json` declares.
///
/// The local search **probes known locations rather than walking the tree**: a recursive
/// scan would happily surface `node_modules/<lib>/favicon.ico` as the project's mark, when
/// the point is the project's own. Only the app-icon-set search enumerates, bounded in
/// depth and entry count and skipping `ProjectIconDefaults.excludedDirectories`.
///
/// Automatic discovery only ever fills an *empty* slot — a custom, agent-set, or previously
/// discovered icon is never replaced except by an explicit "Find Project Icon" request.
@MainActor
final class ProjectIconDiscovery {

    // MARK: - Singleton

    static let shared = ProjectIconDiscovery()
    private init() {}

    // MARK: - Properties

    /// Projects attempted this run, so a fruitless search is not repeated every time the
    /// store changes. A relaunch retries naturally.
    private var attempted: Set<ProjectID> = []

    private let queue = DispatchQueue(label: "codes.threading.icon-discovery", qos: .utility)
    private let appEvents = AppEventObservations()

    // MARK: - Public Methods

    /// Begins watching the store, and sweeps whatever it already holds. Called once at launch.
    @MainActor
    func start() {
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.projectsDidChange()
        }
        sweep()
    }

    /// Re-runs discovery for one project at the user's explicit request, replacing whatever
    /// icon it has if something is found. Reports whether anything was.
    @MainActor
    func rediscover(
        projectID: ProjectID,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard let project = ProjectStore.shared.project(withID: projectID) else {
            completion(false)
            return
        }

        attempted.insert(projectID)
        discover(project: project, replacesExisting: true, completion: completion)
    }

    /// Forgets this run's attempts and sweeps again — the settings toggle's path, so
    /// switching discovery on always acts, even for projects already tried this run.
    @MainActor
    func retryAll() {
        attempted.removeAll()
        sweep()
    }

    /// Sweeps every icon-less project not yet tried this run.
    @MainActor
    func sweep() {
        guard AppSettings.shared.discoversProjectIcons else { return }

        for project in ProjectStore.shared.projects
        where project.icon == nil && !attempted.contains(project.id) {
            attempted.insert(project.id)
            discover(project: project, replacesExisting: false, completion: nil)
        }
    }

    // MARK: - Private Methods

    @MainActor
    private func projectsDidChange() {
        // Catches newly added and imported projects. `attempted` keeps this from looping:
        // the sweep itself changes the store when it finds something.
        sweep()
    }

    @MainActor
    private func discover(
        project: Project,
        replacesExisting: Bool,
        completion: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        let folder = project.folderURL
        let projectID = project.id

        queue.async {
            let found = Self.findIcon(for: folder)

            DispatchQueue.main.async {
                // Re-checked on delivery: the user may have chosen an icon while the
                // search ran, and an automatic result must never displace a choice.
                let current = ProjectStore.shared.project(withID: projectID)?.icon
                guard replacesExisting || current == nil else {
                    completion?(false)
                    return
                }

                guard let found else {
                    completion?(false)
                    return
                }

                let result = ProjectStore.shared.setIcon(
                    imageData: found.data,
                    source: found.source,
                    for: projectID
                )
                guard case .success = result else {
                    completion?(false)
                    return
                }
                completion?(true)
            }
        }
    }

    // MARK: - Candidate Search

    nonisolated private static func findIcon(for folder: URL) -> (data: Data, source: ProjectIconSource)? {
        if let data = repoFileIcon(in: folder) {
            return (data, .repoFile)
        }
        if let data = gitHubAvatar(for: folder) {
            return (data, .remoteAvatar)
        }
        if let data = homepageIcon(in: folder) {
            return (data, .homepage)
        }
        return nil
    }

    /// Probes the conventional icon locations a project owns, then its Xcode app icon set.
    nonisolated private static func repoFileIcon(in folder: URL) -> Data? {
        let roots = [folder] + ProjectIconDefaults.candidateSubdirectories.map {
            folder.appendingPathComponent($0)
        }

        for name in ProjectIconDefaults.candidateFileNames {
            for root in roots {
                let url = root.appendingPathComponent(name)
                if let data = usableImageData(at: url) {
                    return data
                }
            }
        }

        return appIconSetImage(in: folder)
    }

    /// A bounded walk for `AppIcon.appiconset` — the one candidate without a fixed path.
    nonisolated private static func appIconSetImage(in folder: URL) -> Data? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > ProjectIconDefaults.maximumScannedEntries { return nil }

            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let name = url.lastPathComponent
            if ProjectIconDefaults.excludedDirectories.contains(name)
                || enumerator.level > ProjectIconDefaults.maximumScanDepth {
                enumerator.skipDescendants()
                continue
            }

            if name == ProjectIconDefaults.appIconSetName {
                return largestImage(in: url)
            }
        }

        return nil
    }

    /// The set's largest rendition, by file size — a faithful proxy for pixel size here,
    /// and far cheaper than decoding every entry.
    nonisolated private static func largestImage(in directory: URL) -> Data? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        let best = contents
            .filter { $0.pathExtension == ProjectIconDefaults.storedExtension }
            .max {
                fileSize($0) < fileSize($1)
            }

        return best.flatMap { usableImageData(at: $0) }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The avatar of the repository's GitHub owner — but **only when the owner is an
    /// organisation**. A person's avatar is deliberately refused: every repo a person owns
    /// shares the one face, which distinguishes nothing between their projects — and a face
    /// is a person's mark, not a project's. Person-owned repos fall through to the
    /// generated tile instead.
    nonisolated private static func gitHubAvatar(for folder: URL) -> Data? {
        guard let remote = GitInfo.remoteOriginURL(for: folder.path),
              let owner = gitHubOwner(fromRemote: remote),
              isOrganization(owner),
              let url = ProjectIconDefaults.gitHubAvatarURL(owner: owner) else { return nil }

        return fetchImage(url)
    }

    /// Asks the GitHub API what kind of account the owner is. Anything but a definite
    /// "Organization" — a person, an API error, a rate limit — refuses the avatar: the
    /// failure mode of guessing wrong is a face on every project.
    nonisolated private static func isOrganization(_ owner: String) -> Bool {
        guard let url = ProjectIconDefaults.gitHubAccountURL(owner: owner),
              let data = fetch(url),
              let account = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        return account[ProjectIconDefaults.gitHubAccountTypeKey] as? String
            == ProjectIconDefaults.gitHubOrganizationType
    }

    /// Extracts the owner from any of the forms a GitHub remote takes:
    /// `git@github.com:owner/repo.git`, `https://github.com/owner/repo`,
    /// `ssh://git@github.com/owner/repo`.
    nonisolated private static func gitHubOwner(fromRemote remote: String) -> String? {
        let host = ProjectIconDefaults.gitHubHost
        guard let range = remote.range(of: host + ":") ?? remote.range(of: host + "/")
        else { return nil }

        let owner = remote[range.upperBound...]
            .split(separator: "/")
            .first
            .map(String.init)

        return (owner?.isEmpty ?? true) ? nil : owner
    }

    /// The favicon of the homepage the project's `package.json` declares.
    nonisolated private static func homepageIcon(in folder: URL) -> Data? {
        let manifestURL = folder.appendingPathComponent(ProjectIconDefaults.packageManifestName)
        guard let manifestData = try? BoundedFileReader.read(
            manifestURL,
            maximumBytes: 1024 * 1024
        ),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let homepage = manifest[ProjectIconDefaults.homepageKey] as? String,
              let origin = origin(fromWebsite: homepage) else { return nil }

        return websiteIcon(atOrigin: origin)
    }

    /// The probe origin for a site named by a person or a manifest — `sonda.io` and
    /// `https://sonda.io/deep/path` both become `https://sonda.io`.
    nonisolated static func origin(fromWebsite input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let addressed = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: addressed),
              let scheme = url.scheme, scheme.hasPrefix("http"),
              let host = url.host, !host.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    /// A site's icon by convention — its touch icon, else its favicon. Shared by homepage
    /// discovery and the sidebar's explicit "Use Website Favicon…". Synchronous; call off
    /// the main thread.
    nonisolated static func websiteIcon(atOrigin origin: URL) -> Data? {
        for probe in ProjectIconDefaults.homepageProbes {
            if let data = fetchImage(origin.appendingPathComponent(probe)) {
                return data
            }
        }
        return nil
    }

    // MARK: - Data Loading

    /// Reads a local candidate, admitting it only when it decodes as an icon-sized image.
    nonisolated private static func usableImageData(at url: URL) -> Data? {
        ProjectIconStore.candidateData(at: url)
    }

    /// Fetches a remote candidate synchronously — callers are already off the main thread —
    /// with the decode gate on top, so an HTML error page served with 200 is not mistaken
    /// for an icon. Shared with icon research and the MCP tool, which admit images by the
    /// same rules.
    nonisolated static func fetchImage(_ url: URL) -> Data? {
        guard let data = fetch(url), ProjectIconStore.isUsableImage(data) else { return nil }
        return data
    }

    /// A bare synchronous GET, for callers that want JSON rather than pixels — the GitHub
    /// account-type gate here, and `AccountAvatarStore`'s email search.
    nonisolated static func fetch(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = ProjectIconDefaults.requestTimeout

        let result = ProjectIconFetchResult()
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let data, !data.isEmpty {
                result.store(data)
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + ProjectIconDefaults.requestTimeout + 1)
        return result.value
    }
}

private final class ProjectIconFetchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func store(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
}
