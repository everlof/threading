import XCTest
@testable import Threading

/// The pure half of remote execution hosts: what a host says about itself, what preparing it has to
/// do, and the command line a remote launch hands its daemon. The `ssh` half is exercised against a
/// real host by `RemoteExecutionHostLiveTests`, which is opt-in.
@MainActor
final class RemoteExecutionHostTests: XCTestCase {

    // MARK: - Destination

    func testADestinationThatSSHWouldReadAsAnOptionIsRefused() {
        XCTAssertTrue(RemoteHostDestination(alias: "hetzner", configFile: nil).isValid)
        XCTAssertTrue(RemoteHostDestination(alias: "me@pi.local", configFile: "/Users/me/.lima/x/ssh.config").isValid)
        XCTAssertFalse(RemoteHostDestination(alias: "-oProxyCommand=touch /tmp/x", configFile: nil).isValid)
        XCTAssertFalse(RemoteHostDestination(alias: "host name", configFile: nil).isValid)
        XCTAssertFalse(RemoteHostDestination(alias: "host\nname", configFile: nil).isValid)
        XCTAssertFalse(RemoteHostDestination(alias: "", configFile: nil).isValid)
        XCTAssertFalse(RemoteHostDestination(alias: "pi", configFile: "relative/ssh.config").isValid)
    }

    func testSSHArgumentsEndOptionsBeforeTheDestination() {
        let destination = RemoteHostDestination(alias: "pi", configFile: "/tmp/ssh.config")
        let arguments = destination.sshArguments(extraOptions: ["-N"])
        XCTAssertEqual(Array(arguments.prefix(2)), ["-F", "/tmp/ssh.config"])
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["--", "pi"])
        XCTAssertLessThan(arguments.firstIndex(of: "-N")!, arguments.firstIndex(of: "--")!)
    }

    func testADestinationIdentifierIsStableShortAndDistinguishesConfigFiles() {
        let plain = RemoteHostDestination(alias: "pi", configFile: nil)
        let configured = RemoteHostDestination(alias: "pi", configFile: "/tmp/ssh.config")
        XCTAssertEqual(plain.identifier, RemoteHostDestination(alias: "pi", configFile: nil).identifier)
        XCTAssertNotEqual(plain.identifier, configured.identifier)
        XCTAssertEqual(plain.identifier.count, RemoteHostDefaults.identifierHexLength)
    }

    // MARK: - Facts

    private static let debianProbe = """
        Welcome to a login banner=that has an equals sign
        machine=aarch64
        home=/home/david.guest
        user=david
        shell=/bin/bash
        systemctl=/usr/bin/systemctl
        linger=no
        installed=0123456789abcdef
        installed=fedcba9876543210
        active=threading-ptyd@0123456789abcdef.service
        enabled=threading-ptyd@0123456789abcdef.service
        enabled=threading-ptyd@spike-gen2.service
        claude=/home/david.guest/.local/bin/claude
        bridge=00aa11bb22cc33dd
        curl=/usr/bin/curl
        """

    func testReadsAProbeAndIgnoresLinesThatAreNotFacts() throws {
        let facts = try RemoteHostFacts.parse(Self.debianProbe)
        XCTAssertEqual(facts.architecture, .arm64)
        XCTAssertEqual(facts.home, "/home/david.guest")
        XCTAssertEqual(facts.loginShell, "/bin/bash")
        XCTAssertTrue(facts.hasSystemd)
        XCTAssertEqual(facts.lingerEnabled, false)
        XCTAssertEqual(facts.installedBinaries, ["0123456789abcdef", "fedcba9876543210"])
        XCTAssertEqual(facts.activeInstances, ["0123456789abcdef"])
        XCTAssertEqual(facts.enabledInstances, ["0123456789abcdef", "spike-gen2"])
        XCTAssertEqual(facts.claudePath, "/home/david.guest/.local/bin/claude")
        XCTAssertEqual(facts.installedBridges, ["00aa11bb22cc33dd"])
        XCTAssertEqual(facts.curlPath, "/usr/bin/curl")
        XCTAssertTrue(facts.hasPOSIXLoginShell)
        XCTAssertEqual(facts.remoteSocketPath, "/home/david.guest/.local/state/threading/pty/ptyd.sock")
    }

    func testAMissingRequiredFactIsNamed() {
        let withoutHome = Self.debianProbe.replacingOccurrences(of: "home=/home/david.guest\n", with: "")
        XCTAssertThrowsError(try RemoteHostFacts.parse(withoutHome)) { error in
            XCTAssertEqual(error as? RemoteHostFactsError, .unreadable(missing: "home"))
        }
    }

    func testAHostWithoutSystemdOrAClaudeStillAnswers() throws {
        let probe = """
            machine=x86_64
            home=/root
            user=root
            shell=/usr/bin/fish
            systemctl=
            linger=
            claude=fish: Unknown command: claude
            """
        let facts = try RemoteHostFacts.parse(probe)
        XCTAssertEqual(facts.architecture, .amd64)
        XCTAssertFalse(facts.hasSystemd)
        XCTAssertNil(facts.lingerEnabled)
        XCTAssertNil(facts.claudePath, "only an absolute path is a resolved executable")
        XCTAssertFalse(facts.hasPOSIXLoginShell)
    }

    func testAnUnknownMachineHasNoArchitecture() {
        XCTAssertNil(RemoteHostArchitecture(unameMachine: "riscv64"))
        XCTAssertEqual(RemoteHostArchitecture(unameMachine: "x86_64"), .amd64)
    }

    // MARK: - Install plan

    private func binary(_ digestPrefix: String) -> RemoteHostBinary {
        RemoteHostBinary(
            url: URL(fileURLWithPath: "/tmp/threading-ptyd"),
            architecture: .arm64,
            sha256: digestPrefix + String(repeating: "0", count: 64 - digestPrefix.count)
        )
    }

    func testAFreshHostUploadsLingersAndStartsItsOwnInstance() throws {
        let facts = try RemoteHostFacts.parse(Self.debianProbe
            .replacingOccurrences(of: "installed=0123456789abcdef\ninstalled=fedcba9876543210\n", with: "")
            .replacingOccurrences(of: "active=threading-ptyd@0123456789abcdef.service\n", with: ""))
        let plan = RemoteHostInstallPlan.make(facts: facts, binary: binary("aaaaaaaaaaaaaaaa"))
        XCTAssertTrue(plan.uploadsBinary)
        XCTAssertTrue(plan.enablesLinger)
        XCTAssertEqual(plan.otherActiveInstances, [])
        XCTAssertFalse(plan.isRunning)
    }

    func testAHostAlreadyRunningThisBuildNeedsNothingButItsLinger() throws {
        let facts = try RemoteHostFacts.parse(Self.debianProbe)
        let plan = RemoteHostInstallPlan.make(facts: facts, binary: binary("0123456789abcdef"))
        XCTAssertFalse(plan.uploadsBinary)
        XCTAssertTrue(plan.isRunning)
        XCTAssertEqual(plan.otherActiveInstances, [])
        XCTAssertTrue(plan.enablesLinger)
    }

    func testAnotherBuildRunningIsNamedForTheZeroSessionUpgrade() throws {
        let facts = try RemoteHostFacts.parse(Self.debianProbe)
        let plan = RemoteHostInstallPlan.make(facts: facts, binary: binary("fedcba9876543210"))
        XCTAssertFalse(plan.uploadsBinary, "already installed, just not the running one")
        XCTAssertFalse(plan.isRunning)
        XCTAssertEqual(plan.otherActiveInstances, ["0123456789abcdef"])
    }

    /// The spike's VM, exactly: an old instance left enabled came back at boot on this build's
    /// paths. Once this build runs, every other enabled instance is disabled for boot — and only
    /// for boot, so an agent under a running one is not touched.
    func testOtherEnabledInstancesAreDisabledForBootButNeverStopped() throws {
        let facts = try RemoteHostFacts.parse(Self.debianProbe)
        let plan = RemoteHostInstallPlan.make(facts: facts, binary: binary("0123456789abcdef"))
        XCTAssertEqual(plan.otherEnabledInstances, ["spike-gen2"])

        let script = RemoteHostInstallScripts.disableAtBootScript(identifier: "spike-gen2")
        XCTAssertEqual(script, "systemctl --user disable threading-ptyd@spike-gen2.service")
        XCTAssertFalse(script.contains("--now"))
        XCTAssertFalse(script.contains("stop"))
    }

    func testTheUnitNeverRestartsARetiredDaemonAndNamesItsPaths() {
        let unit = RemoteHostInstallScripts.unitTemplate
        XCTAssertTrue(unit.contains("Restart=on-failure"), "a retire exits 0 and must stay stopped")
        XCTAssertFalse(unit.contains("Restart=always"))
        XCTAssertTrue(unit.contains("%h/.local/lib/threading/%i/threading-ptyd --socket %h/.local/state/threading/pty/ptyd.sock --state %h/.local/state/threading/pty"))
    }

    /// The bridge upgrades apart from the daemon, so it lives in its own content-named directory,
    /// and the probe's daemon glob can never mistake it for an installed daemon.
    func testTheBridgeInstallsBesideTheDaemonButNotAsOne() {
        var bridge = binary("00aa11bb22cc33dd")
        bridge.kind = .bridge
        XCTAssertEqual(bridge.remotePath, ".local/lib/threading/bridge/00aa11bb22cc33dd/threading-mcp-bridge")
        let command = RemoteHostInstallScripts.uploadCommand(for: bridge)
        XCTAssertTrue(command.hasPrefix("mkdir -p .local/lib/threading/bridge/00aa11bb22cc33dd && "))
        XCTAssertTrue(command.hasSuffix("sha256sum .local/lib/threading/bridge/00aa11bb22cc33dd/threading-mcp-bridge"))
        XCTAssertEqual(binary("0123456789abcdef").remotePath, ".local/lib/threading/0123456789abcdef/threading-ptyd")
    }

    /// The path back to Threading rides the daemon's tunnel, so the two live and die together, and
    /// the host end is cleared first because the server, not this client, decides whether a bind
    /// may replace a stale socket.
    func testTheTunnelForwardsTheRendezvousBackOverTheSameConnection() {
        XCTAssertEqual(
            RemoteHostTunnel.arguments(localSocketPath: "/l/pty.sock", remoteSocketPath: "/r/ptyd.sock", reverse: nil),
            ["-L", "/l/pty.sock:/r/ptyd.sock"]
        )
        XCTAssertEqual(
            RemoteHostTunnel.arguments(localSocketPath: "/l/pty.sock", remoteSocketPath: "/r/ptyd.sock",
                                       reverse: (remote: "/r/mcp.sock", local: "/mac/mcp.sock")),
            ["-L", "/l/pty.sock:/r/ptyd.sock", "-R", "/r/mcp.sock:/mac/mcp.sock"]
        )
        let script = RemoteHostInstallScripts.prepareBridgeRendezvousScript
        XCTAssertTrue(script.contains("chmod 700 \"$HOME/.local/state/threading/bridge\""))
        XCTAssertTrue(script.contains("rm -f \"$HOME/.local/state/threading/bridge/mcp.sock\""))
    }

    func testTheUploadCommandIsQuotingFreeAndVerifiesWhatArrived() {
        let command = RemoteHostInstallScripts.uploadCommand(for: binary("0123456789abcdef"))
        XCTAssertFalse(command.contains("'"))
        XCTAssertFalse(command.contains("\""))
        XCTAssertTrue(command.hasSuffix("sha256sum .local/lib/threading/0123456789abcdef/threading-ptyd"))
        let digest = String(repeating: "ab", count: 32)
        XCTAssertEqual(
            RemoteHostInstallScripts.reportedDigest(in: "\(digest)  .local/lib/threading/x/threading-ptyd\n"),
            digest
        )
        XCTAssertNil(RemoteHostInstallScripts.reportedDigest(in: "sha256sum: No such file"))
    }

    func testAnInstanceNameIsReadFromItsUnit() {
        XCTAssertEqual(RemoteHostFacts.instanceName(fromUnit: "threading-ptyd@abc.service"), "abc")
        XCTAssertNil(RemoteHostFacts.instanceName(fromUnit: "threading-ptyd@.service"))
        XCTAssertNil(RemoteHostFacts.instanceName(fromUnit: "sshd.service"))
        XCTAssertNil(RemoteHostFacts.instanceName(fromUnit: "threading-ptyd@a;rm -rf ~.service"),
                     "a name read off the host must not become shell syntax there")
    }

    // MARK: - Project host

    func testAHostThatSSHWouldMisreadIsAProblemNamedForThePerson() {
        let valid = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/app")
        XCTAssertNil(valid.problem)
        XCTAssertEqual(
            ProjectExecutionHost(destination: "  ", remoteDirectory: "/home/me/app").problem,
            .missingDestination
        )
        XCTAssertEqual(
            ProjectExecutionHost(destination: "-oProxyCommand=x", remoteDirectory: "/a").problem,
            .unsafeDestination
        )
        XCTAssertEqual(
            ProjectExecutionHost(destination: "pi", sshConfigFile: "cfg", remoteDirectory: "/a").problem,
            .relativeConfigFile
        )
        XCTAssertEqual(
            ProjectExecutionHost(destination: "pi", remoteDirectory: "app").problem,
            .relativeRemoteDirectory
        )
        XCTAssertEqual(
            ProjectExecutionHost.typed(destination: " pi ", sshConfigFile: "  ", remoteDirectory: "/a "),
            ProjectExecutionHost(destination: "pi", sshConfigFile: nil, remoteDirectory: "/a")
        )
    }

    /// The three answers, and above all the third: a host this build cannot honour refuses the
    /// launch instead of letting it run on this Mac.
    func testARouteIsLocalRemoteOrARefusalAndNeverASilentFallback() {
        let host = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/app")
        XCTAssertEqual(RemoteExecutionHostRoute.resolve(nil, buildSupportsRemoteHosts: true), .local)
        XCTAssertEqual(RemoteExecutionHostRoute.resolve(nil, buildSupportsRemoteHosts: false), .local)
        XCTAssertEqual(RemoteExecutionHostRoute.resolve(host, buildSupportsRemoteHosts: true), .remote(host))
        XCTAssertEqual(
            RemoteExecutionHostRoute.resolve(host, buildSupportsRemoteHosts: false),
            .refused(.unsupportedBuild)
        )
        let invalid = ProjectExecutionHost(destination: "pi", remoteDirectory: "relative")
        XCTAssertEqual(
            RemoteExecutionHostRoute.resolve(invalid, buildSupportsRemoteHosts: true),
            .refused(.invalid(.relativeRemoteDirectory))
        )
    }

    func testAProjectKeepsItsHostThroughPersistenceAndABrokenHostCostsOnlyTheHost() throws {
        var project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project"))
        let plain = try JSONEncoder().encode(project)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("executionHost"),
                       "no host writes no key")

        project.executionHost = ProjectExecutionHost(
            destination: "pi", sshConfigFile: "/Users/me/.lima/x/ssh.config", remoteDirectory: "/home/me/app"
        )
        let decoded = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(project))
        XCTAssertEqual(decoded.executionHost, project.executionHost)

        // A host with a field missing still decodes — as an invalid host, refused at launch —
        // rather than reading as "no host" and running locally.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(project)) as? [String: Any])
        object["executionHost"] = ["destination": "pi"]
        let partial = try JSONDecoder().decode(Project.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(partial.executionHost?.problem, .relativeRemoteDirectory)
        XCTAssertEqual(partial.name, "p")

        object["executionHost"] = "not an object"
        let broken = try JSONDecoder().decode(Project.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(broken.name, "p", "the checkout survives a host it cannot read")
    }

    func testTheStoreRefusesAnInvalidHostAndKeepsAValidOneAcrossReopening() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-host-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(stateManager: StateManager(appSupportDirectory: directory), refusesWrites: false)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let host = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/app")

        XCTAssertEqual(
            store.setExecutionHost(ProjectExecutionHost(destination: "pi", remoteDirectory: "rel"), forProjectID: project.id),
            .unsupportedValue
        )
        XCTAssertEqual(store.setExecutionHost(host, forProjectID: project.id), .applied)
        XCTAssertEqual(store.setExecutionHost(host, forProjectID: project.id), .unchanged)

        let reopened = ProjectStore(stateManager: StateManager(appSupportDirectory: directory), refusesWrites: false)
        XCTAssertEqual(reopened.project(withID: project.id)?.executionHost, host)

        XCTAssertEqual(reopened.setExecutionHost(nil, forProjectID: project.id), .applied)
        XCTAssertNil(reopened.project(withID: project.id)?.executionHost)
    }

    // MARK: - Launch

    private func context(
        shell: String = "/bin/sh",
        home: String,
        claude: String? = "/usr/bin/claude",
        curl: String? = nil,
        toolRoute: RemoteHostToolRoute? = nil
    ) -> RemoteHostLaunchContext {
        RemoteHostLaunchContext(
            destination: RemoteHostDestination(alias: "pi", configFile: nil),
            facts: RemoteHostFacts(
                machine: "aarch64", home: home, user: "me", loginShell: shell, hasSystemd: true,
                lingerEnabled: true, installedBinaries: [], activeInstances: [], claudePath: claude,
                curlPath: curl
            ),
            localSocketPath: "/tmp/x.sock",
            toolRoute: toolRoute
        )
    }

    private func route(home: String, bridge: Bool = true) -> RemoteHostToolRoute {
        RemoteHostToolRoute(
            socketPath: "\(home)/.local/state/threading/bridge/mcp.sock",
            bridgePath: bridge ? "\(home)/.local/lib/threading/bridge/00aa11bb22cc33dd/threading-mcp-bridge" : nil,
            cacheDirectory: "\(home)/.local/state/threading/bridge/catalogues"
        )
    }

    func testOnlyClaudeTerminalSessionsLaunchRemotely() {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project"))
        let host = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/project")
        let codex = AgentSession(kind: .codex, title: "c")
        XCTAssertThrowsError(try RemoteAgentLaunch.make(
            for: codex, in: project, host: host, context: context(home: "/home/me"), initialPrompt: nil
        )) { XCTAssertEqual($0 as? RemoteAgentLaunchError, .unsupportedAgent(.codex)) }

        let claude = AgentSession(kind: .claude, title: "c")
        XCTAssertThrowsError(try RemoteAgentLaunch.make(
            for: claude, in: project, host: host,
            context: context(shell: "/usr/bin/fish", home: "/home/me"), initialPrompt: nil
        )) { XCTAssertEqual($0 as? RemoteAgentLaunchError, .unsupportedLoginShell("/usr/bin/fish")) }

        XCTAssertThrowsError(try RemoteAgentLaunch.make(
            for: claude, in: project, host: host,
            context: context(home: "/home/me", claude: nil), initialPrompt: nil
        )) { XCTAssertEqual($0 as? RemoteAgentLaunchError, .agentNotInstalled(.claude)) }
    }

    func testTheEnvironmentIsTheHostsNeverThisMacs() throws {
        let launch = try RemoteAgentLaunch.make(
            for: AgentSession(kind: .claude, title: "c"),
            in: Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project")),
            host: ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/project"),
            context: context(shell: "/bin/bash", home: "/home/me"),
            initialPrompt: nil
        )
        XCTAssertEqual(launch.plan.executable, "/bin/bash")
        XCTAssertEqual(Array(launch.plan.arguments.prefix(2)), ["-l", "-c"])
        XCTAssertTrue(launch.environment.contains("HOME=/home/me"))
        XCTAssertTrue(launch.environment.contains("SHELL=/bin/bash"))
        let macHome = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(launch.environment.contains { $0.contains(macHome) })
        XCTAssertFalse(launch.plan.arguments.joined().contains("--settings"), "no Mac-side settings file crosses")
        XCTAssertFalse(launch.plan.arguments.joined().contains("--mcp-config"))
    }

    /// The host's shell chooses between resuming and starting, so the choice is asserted by running
    /// the script in a real shell against a fake `claude` that prints its arguments — once with no
    /// transcript, once with one — in a checkout whose name is hostile to quoting.
    func testTheHostsShellResumesExactlyWhenItsTranscriptExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let checkout = root.appendingPathComponent("it's $(a) checkout", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [home, checkout, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\npwd -P\nprintf '%s\\n' \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        var session = AgentSession(kind: .claude, title: "c")
        session.hasLaunched = true
        let host = ProjectExecutionHost(destination: "pi", remoteDirectory: checkout.path)
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project"))

        func run() throws -> [String] {
            let launch = try RemoteAgentLaunch.make(
                for: session, in: project, host: host,
                context: context(home: home.path), initialPrompt: nil
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // `-c` only: this Mac's `/etc/profile` is not the host's, and `-l` would read it.
            process.arguments = Array(launch.plan.arguments.dropFirst())
            process.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": home.path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: "\n").map(String.init)
        }

        let transcriptID = session.resumeState.transcriptID?.rawValue ?? session.id.uuidString.lowercased()
        let fresh = try run()
        // `pwd -P` spells the temporary directory through `/private`; the checkout's own hostile
        // name is the part that proves the `cd` was quoted.
        XCTAssertEqual(fresh.first.map { ($0 as NSString).lastPathComponent }, checkout.lastPathComponent)
        XCTAssertTrue(fresh.contains("--session-id"))
        XCTAssertTrue(fresh.contains(transcriptID))

        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeTranscript.projectSlug(forPath: checkout.path), isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data().write(to: projects.appendingPathComponent("\(transcriptID).jsonl"))
        let resumed = try run()
        XCTAssertTrue(resumed.contains("--resume"))
        XCTAssertFalse(resumed.contains("--session-id"))
    }

    // MARK: - Hooks and tools on the host

    /// A launch with a route back to this Mac carries the same hooks and bridge a local one does,
    /// pointed at the forwarded socket — and the token reaches the host only through the
    /// environment and owner-only files, never an argument a `ps` there could read.
    func testARoutedLaunchCarriesHooksAndTheBridgeWithoutPuttingTheTokenInArguments() throws {
        let session = AgentSession(kind: .claude, title: "c")
        let home = "/home/me"
        let launch = try RemoteAgentLaunch.make(
            for: session,
            in: Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project")),
            host: ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/project"),
            context: context(home: home, curl: "/usr/bin/curl", toolRoute: route(home: home)),
            initialPrompt: nil,
            reportsLifecycle: true,
            allowedTools: ["set_session_name", "display_chart"]
        ).encode()

        let token = MCPSessionRegistry.token(for: session.id)
        let arguments = launch.plan.arguments.joined(separator: " ")
        XCTAssertFalse(arguments.contains(token), "the token must not be readable in the host's process list")
        XCTAssertTrue(launch.environment.contains("THREADING_MCP_SOCKET=\(home)/.local/state/threading/bridge/mcp.sock"))
        XCTAssertTrue(launch.environment.contains("THREADING_SESSION_TOKEN=\(token)"))
        XCTAssertFalse(launch.environment.contains { $0.hasPrefix("THREADING_MCP_PORT=") }, "this Mac's port means nothing there")

        let settings = try payload(RemoteAgentLaunchDefaults.settingsVariable, in: launch)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertFalse(String(describing: hooks).contains(FileManager.default.homeDirectoryForCurrentUser.path))

        let configuration = try payload(RemoteAgentLaunchDefaults.mcpConfigVariable, in: launch)
        let server = try XCTUnwrap((configuration["mcpServers"] as? [String: Any])?["threading"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "stdio")
        XCTAssertEqual(server["command"] as? String, "\(home)/.local/lib/threading/bridge/00aa11bb22cc33dd/threading-mcp-bridge")
        XCTAssertEqual(server["args"] as? [String], [
            "--socket", "\(home)/.local/state/threading/bridge/mcp.sock",
            "--token", token,
            "--cache", "\(home)/.local/state/threading/bridge/catalogues/\(session.id.uuidString).json"
        ])
        XCTAssertTrue(arguments.contains("--allowedTools"))
        XCTAssertTrue(arguments.contains("mcp__threading__set_session_name"))
    }

    /// Each half degrades on its own: no `curl` means no lifecycle hooks, no bridge binary means no
    /// tools, and no route at all means neither — never a flag naming a file nobody wrote.
    func testEachHalfOfTheIntegrationDegradesOnItsOwn() throws {
        let session = AgentSession(kind: .claude, title: "c")
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project"))
        let host = ProjectExecutionHost(destination: "pi", remoteDirectory: "/home/me/project")
        func launch(_ context: RemoteHostLaunchContext) throws -> RemoteAgentLaunch {
            try RemoteAgentLaunch.make(for: session, in: project, host: host, context: context,
                                       initialPrompt: nil, reportsLifecycle: true,
                                       allowedTools: ["set_session_name"]).encode()
        }

        let noCurl = try launch(context(home: "/home/me", curl: nil, toolRoute: route(home: "/home/me")))
        let settings = try? payload(RemoteAgentLaunchDefaults.settingsVariable, in: noCurl)
        XCTAssertNil(settings?["hooks"], "a hook the host cannot run is not installed")
        XCTAssertTrue(noCurl.plan.arguments.joined().contains("--mcp-config"))

        let noBridge = try launch(context(home: "/home/me", curl: "/usr/bin/curl",
                                          toolRoute: route(home: "/home/me", bridge: false)))
        XCTAssertFalse(noBridge.plan.arguments.joined().contains("--mcp-config"))
        XCTAssertTrue(noBridge.plan.arguments.joined().contains("--settings"))

        let unrouted = try launch(context(home: "/home/me", curl: "/usr/bin/curl"))
        XCTAssertFalse(unrouted.plan.arguments.joined().contains("--settings"))
        XCTAssertFalse(unrouted.environment.contains { $0.hasPrefix("THREADING_") })
    }

    /// Run for real: the script writes both files owner-only under the host's home, unsets the
    /// variables that carried them, and starts `claude` with flags naming exactly those files.
    func testTheLaunchScriptWritesOwnerOnlyFilesAndHandsClaudeTheirPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/threading-rl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [home, checkout, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf 'LEFT=%s\\n' \"${THREADING_LAUNCH_SETTINGS-unset}\"\nprintf '%s\\n' \"$@\"\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let session = AgentSession(kind: .claude, title: "c")
        let launch = try RemoteAgentLaunch.make(
            for: session,
            in: Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/project")),
            host: ProjectExecutionHost(destination: "pi", remoteDirectory: checkout.path),
            context: context(home: home.path, curl: "/usr/bin/curl", toolRoute: route(home: home.path)),
            initialPrompt: nil,
            reportsLifecycle: true,
            allowedTools: ["set_session_name"]
        ).encode()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Array(launch.plan.arguments.dropFirst())
        var environment: [String: String] = [:]
        for entry in launch.environment {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        environment["PATH"] = bin.path + ":/usr/bin:/bin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(process.terminationStatus, 0, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.first, "LEFT=unset", "the variable carrying the token outlived the write")

        let sessions = home.appendingPathComponent(".local/state/threading/sessions", isDirectory: true)
        let settingsPath = sessions.appendingPathComponent("\(session.id.uuidString).settings.json").path
        let configPath = sessions.appendingPathComponent("\(session.id.uuidString).mcp.json").path
        XCTAssertEqual(lines.firstIndex(of: "--settings").map { lines[$0 + 1] }, settingsPath)
        XCTAssertEqual(lines.firstIndex(of: "--mcp-config").map { lines[$0 + 1] }, configPath)
        for path in [settingsPath, configPath] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, path)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".local/state/threading/bridge/catalogues").path
        ), "the bridge's cache directory exists before the bridge needs it")
    }

    private func payload(_ variable: String, in launch: RemoteAgentLaunch) throws -> [String: Any] {
        let prefix = variable + "="
        let entry = try XCTUnwrap(launch.environment.first { $0.hasPrefix(prefix) }, "no \(variable)")
        let json = Data(entry.dropFirst(prefix.count).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }
}
