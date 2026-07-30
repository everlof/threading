import Foundation

// MARK: - Project Icon Research

/// Asks Codex — headless, read-only, on the default account — which image best represents
/// a project, and stores what it names as the project's icon.
///
/// **Codex-only** because a sandbox is the point: the run reads an unfamiliar project's files
/// to name its mark, and `--sandbox read-only` is one flag that guarantees it cannot do more.
/// Claude's headless mode is permitted (see `AgentKind.supportsNativeUI`) but would need its
/// tool surface constrained explicitly rather than by a single switch, which buys nothing here.
/// And deliberately **manual**: a run spends the user's own
/// usage, so it happens only from the explicit "Research Icon with Codex" menu action —
/// never automatically. The free `ProjectIconDiscovery` chain is what runs unattended.
///
/// **Every run leaves a record.** The child's combined stdout and stderr is written to
/// `IconResearch/<projectID>.jsonl` under Application Support (`recordURL(for:)`) whether
/// the run succeeds or not, and each stage logs through `ThreadingLogger.agent` — watch live
/// with `log stream --predicate 'subsystem == "codes.threading" AND category == "agent"'`.
/// A headless child is invisible by construction; the record is what makes "what did it
/// do?" answerable after the fact.
enum ProjectIconResearch {

    // MARK: - Errors

    enum ResearchError: Error {
        case alreadyRunning
        case launchFailed
        case exitedAbnormally(Int32)
        case timedOut
        case noAnswer
        case nothingFound
        case unusableResult(String)

        var message: String {
            switch self {
            case .alreadyRunning:
                return "A research run for this project is already in progress."
            case .launchFailed:
                return "Codex could not be launched. Check that the codex CLI is installed."
            case .exitedAbnormally(let status):
                return "Codex exited with status \(status) before answering."
            case .timedOut:
                return "Codex did not finish within \(Int(IconResearchDefaults.timeout)) seconds."
            case .noAnswer:
                return "Codex did not produce an answer."
            case .nothingFound:
                return "Codex found no suitable icon for this project."
            case .unusableResult(let detail):
                return "Codex suggested an icon that could not be used: \(detail)"
            }
        }
    }

    // MARK: - Properties

    /// Projects with a run in flight, read by the sidebar to show "Researching…" instead of
    /// offering a second run. Main-thread only, like the stores.
    @MainActor private(set) static var runningProjectIDs: Set<ProjectID> = []

    private static let queue = DispatchQueue(label: "codes.threading.icon-research", qos: .userInitiated)

    // MARK: - Public Methods

    /// Where a project's last run record lives — the child's combined output, kept for
    /// exactly the "what did it actually do?" question.
    static func recordURL(for projectID: ProjectID) -> URL {
        recordDirectory.appendingPathComponent(
            projectID.uuidString + "." + IconResearchDefaults.recordExtension
        )
    }

    /// Runs one research pass for a project. The completion arrives on the main queue with
    /// the stored icon, which has already been recorded on the project.
    @MainActor
    static func run(
        for project: Project,
        completion: @escaping @MainActor @Sendable (Result<ProjectIcon, ResearchError>) -> Void
    ) {
        guard !runningProjectIDs.contains(project.id) else {
            completion(.failure(.alreadyRunning))
            return
        }
        runningProjectIDs.insert(project.id)

        let plan = AgentLauncher.codexResearchPlan(
            in: project.folderPath,
            prompt: IconResearchDefaults.prompt
        )
        let projectID = project.id
        let folderURL = project.folderURL

        ThreadingLogger.agent.info(
            "Icon research started for \(project.name, privacy: .public) in \(project.folderPath, privacy: .public)"
        )

        queue.async {
            let outcome = performResearch(plan: plan, projectID: projectID, folderURL: folderURL)

            DispatchQueue.main.async {
                runningProjectIDs.remove(projectID)

                switch outcome {
                case .failure(let error):
                    ThreadingLogger.agent.error(
                        "Icon research failed for \(projectID, privacy: .public): \(error.message, privacy: .public)"
                    )
                    completion(.failure(error))

                case .success(let data):
                    guard let fileName = ProjectIconStore.store(imageData: data, for: projectID) else {
                        completion(.failure(.unusableResult("the image could not be decoded")))
                        return
                    }

                    ThreadingLogger.agent.info(
                        "Icon research succeeded for \(projectID, privacy: .public): stored \(fileName, privacy: .public)"
                    )
                    let icon = ProjectIcon(source: .agent, fileName: fileName)
                    ProjectStore.shared.setIcon(icon, for: projectID)
                    completion(.success(icon))
                }
            }
        }
    }

    // MARK: - Private Methods

    private static var recordDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(IconResearchDefaults.recordDirectoryName)
    }

    private static func performResearch(
        plan: AgentLaunchPlan,
        projectID: ProjectID,
        folderURL: URL
    ) -> Result<Data, ResearchError> {
        let run = execute(plan)

        // The record is written before any verdict, so a failed run is exactly the one
        // whose record survives to be read.
        writeRecord(run.output ?? "", for: projectID)

        if let failure = run.failure {
            return .failure(failure)
        }

        guard let output = run.output,
              let message = finalAgentMessage(fromJSONL: output) else {
            return .failure(.noAnswer)
        }

        ThreadingLogger.agent.info(
            "Icon research answer for \(projectID, privacy: .public): \(message, privacy: .public)"
        )

        guard let answer = answer(from: message) else {
            return .failure(.noAnswer)
        }

        if let path = answer.path {
            return imageData(atProjectPath: path, folderURL: folderURL)
        }
        if let address = answer.url {
            return imageData(atRemoteAddress: address)
        }
        return .failure(.nothingFound)
    }

    private static func writeRecord(_ output: String, for projectID: ProjectID) {
        do {
            try FileManager.default.createDirectory(
                at: recordDirectory,
                withIntermediateDirectories: true
            )
            try output.write(to: recordURL(for: projectID), atomically: true, encoding: .utf8)
        } catch {
            ThreadingLogger.agent.error(
                "Could not write icon research record: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Runs the plan to completion. stderr is merged into the same pipe as stdout — one
    /// reader can never deadlock on two pipes, the JSONL parser skips non-JSON lines
    /// anyway, and the record then holds the *whole* story, diagnostics included.
    private static func execute(_ plan: AgentLaunchPlan) -> (output: String?, failure: ResearchError?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = AgentEnvironment.launchEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            ThreadingLogger.agent.error(
                "Icon research launch failed: \(error.localizedDescription, privacy: .public)"
            )
            return (nil, .launchFailed)
        }

        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + IconResearchDefaults.timeout,
            execute: timeout
        )

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        let output = String(data: data, encoding: .utf8)
        ThreadingLogger.agent.info(
            "Icon research child exited: status \(process.terminationStatus), \(data.count) output bytes"
        )

        // `terminate()` surfaces as an uncaught SIGTERM, which distinguishes our timeout
        // from the child failing on its own.
        if process.terminationReason == .uncaughtSignal {
            return (output, .timedOut)
        }
        guard process.terminationStatus == 0 else {
            return (output, .exitedAbnormally(process.terminationStatus))
        }

        return (output, nil)
    }

    /// The last completed `agent_message` in the run's JSONL — the model's final say.
    private static func finalAgentMessage(fromJSONL output: String) -> String? {
        var message: String?

        for line in output.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == IconResearchDefaults.completedEventType,
                  let item = object["item"] as? [String: Any],
                  item["type"] as? String == IconResearchDefaults.agentMessageItemType,
                  let text = item["text"] as? String, !text.isEmpty else { continue }
            message = text
        }

        return message
    }

    /// The JSON object inside the answer. The prompt asks for bare JSON; the braces are
    /// located rather than the whole message parsed, since models still fence or preface it.
    private static func answer(from message: String) -> (path: String?, url: String?)? {
        guard let start = message.firstIndex(of: "{"),
              let end = message.lastIndex(of: "}"),
              start < end,
              let object = try? JSONSerialization.jsonObject(
                  with: Data(message[start...end].utf8)
              ) as? [String: Any] else { return nil }

        return (object["path"] as? String, object["url"] as? String)
    }

    /// Reads a file the agent named, admitted only from inside the project's own folder —
    /// the run is sandboxed read-only, but this read happens with the user's permissions.
    private static func imageData(
        atProjectPath path: String,
        folderURL: URL
    ) -> Result<Data, ResearchError> {
        let resolved = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : folderURL.appendingPathComponent(path)

        let standardized = resolved.standardizedFileURL.path
        let root = folderURL.standardizedFileURL.path
        guard standardized == root || standardized.hasPrefix(root + "/") else {
            return .failure(.unusableResult("\(path) is outside the project"))
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: standardized)),
              ProjectIconStore.isUsableImage(data) else {
            return .failure(.unusableResult("\(path) is not a usable image"))
        }

        return .success(data)
    }

    private static func imageData(atRemoteAddress address: String) -> Result<Data, ResearchError> {
        guard let url = URL(string: address), url.scheme == "https" else {
            return .failure(.unusableResult("\(address) is not an https URL"))
        }

        guard let data = ProjectIconDiscovery.fetchImage(url) else {
            return .failure(.unusableResult("\(address) did not serve a usable image"))
        }

        return .success(data)
    }
}

// MARK: - Icon Research Defaults

enum IconResearchDefaults {
    /// Generous: a cold `codex exec` includes login-shell startup and a model round trip.
    static let timeout: TimeInterval = 180

    static let recordDirectoryName = "IconResearch"
    static let recordExtension = "jsonl"

    static let completedEventType = "item.completed"
    static let agentMessageItemType = "agent_message"

    static let prompt = """
        Identify the single image that best represents this project, for use as a small \
        sidebar icon. Prefer the project's own mark: a favicon, app icon, or logo committed \
        in this repository — ignore anything under dependency directories such as \
        node_modules or vendor — or an image URL you are confident in, such as the \
        project's GitHub owner avatar or its website's favicon. Reply with ONLY a JSON \
        object, no prose and no code fence: {"path": "<image path relative to the project \
        root>"} or {"url": "<https image URL>"} or {"none": true} if nothing suitable exists.
        """
}
