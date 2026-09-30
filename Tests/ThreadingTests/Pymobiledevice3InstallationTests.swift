import Foundation
import XCTest
@testable import Threading

final class Pymobiledevice3InstallationTests: XCTestCase {
    func testInstallBuildsValidatesAndAtomicallyActivatesVersionedEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = InstallerRunner(version: "11.19.4\n")
        let installation = fixture.installation(runner: runner, identifier: "new")

        let installed = try installation.installLatest()

        XCTAssertEqual(installed.version, "11.19.4")
        XCTAssertEqual(installed.executable, Pymobiledevice3ManagedTool.executable(in: fixture.root))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.executable.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: Pymobiledevice3ManagedTool.currentLink(in: fixture.root).path
            ),
            fixture.candidate("new").path
        )

        let commands = runner.recordedCommands()
        XCTAssertEqual(commands.map(\.step), [
            .createEnvironment,
            .installPackage,
            .validateVersion,
        ])
        XCTAssertEqual(commands.map(\.output), [
            .merged,
            .merged,
            .standardOutput,
        ])
        XCTAssertEqual(commands[0].arguments, ["-m", "venv", fixture.candidate("new").path])
        XCTAssertTrue(commands[1].arguments.contains("--isolated"))
        XCTAssertTrue(commands[1].arguments.contains("--upgrade"))
        XCTAssertEqual(commands[1].arguments.last, "pymobiledevice3")
        XCTAssertNil(commands[0].environment["PYTHONHOME"])
        XCTAssertNil(commands[0].environment["PYTHONPATH"])
    }

    func testVersionValidationIgnoresPythonWarningsOnStandardError() throws {
        let command = Pymobiledevice3InstallCommand(
            step: .validateVersion,
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf 'LibreSSL warning\\n' >&2; printf '11.19.4\\n'",
            ],
            environment: ProcessInfo.processInfo.environment,
            timeout: 2,
            maximumOutputBytes: 4096,
            output: .standardOutput
        )

        let result = try BoundedPymobiledevice3InstallCommandRunner().run(command)

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "11.19.4\n")
    }

    func testFailedUpdateKeepsPreviouslyActiveVersion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = fixture.candidate("old")
        try fixture.makeInstalledEnvironment(at: old)
        try FileManager.default.createSymbolicLink(
            atPath: Pymobiledevice3ManagedTool.currentLink(in: fixture.root).path,
            withDestinationPath: old.path
        )
        let runner = InstallerRunner(version: "11.19.4\n", failingStep: .installPackage)
        let installation = fixture.installation(runner: runner, identifier: "new")

        XCTAssertThrowsError(try installation.installLatest()) { error in
            XCTAssertEqual(
                error as? Pymobiledevice3InstallError,
                .commandFailed(.installPackage)
            )
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: Pymobiledevice3ManagedTool.currentLink(in: fixture.root).path
            ),
            old.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.candidate("new").path))
    }

    func testUnsupportedDownloadedVersionIsNeverActivated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installation = fixture.installation(
            runner: InstallerRunner(version: "3.0.1\n"),
            identifier: "old-version"
        )

        XCTAssertThrowsError(try installation.installLatest()) { error in
            XCTAssertEqual(error as? Pymobiledevice3InstallError, .unsupportedVersion)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: Pymobiledevice3ManagedTool.currentLink(in: fixture.root).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.candidate("old-version").path))
    }

    func testLaunchCleanupDeletesOnlyInactiveVersions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let active = fixture.candidate("active")
        let stale = fixture.candidate("stale")
        try fixture.makeInstalledEnvironment(at: active)
        try fixture.makeInstalledEnvironment(at: stale)
        try FileManager.default.createSymbolicLink(
            atPath: Pymobiledevice3ManagedTool.currentLink(in: fixture.root).path,
            withDestinationPath: active.path
        )

        fixture.installation(
            runner: InstallerRunner(version: "11.19.4\n"),
            identifier: "unused"
        ).cleanupStaleVersions()

        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testPhysicalDeviceResolverPrefersManagedToolAfterExplicitOverride() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let managed = fixture.root.appendingPathComponent("managed-pymobiledevice3")
        try fixture.makeExecutable(at: managed)

        XCTAssertEqual(
            PhysicalDeviceToolLocator.pymobiledevice3(
                environment: [:],
                managedExecutable: managed
            ),
            managed
        )
    }

    func testRuntimeEnvironmentUsesThreadingOwnedCacheWithoutReplacingHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.root.appendingPathComponent("runtime", isDirectory: true)

        let environment = try Pymobiledevice3RuntimeEnvironment.prepare(
            inherited: [
                "HOME": "/keep-user-home",
                "PYTHONPATH": "/ignore-user-python-path",
                "PYTHONNOUSERSITE": "0",
            ],
            root: runtime
        )

        let customization = runtime.appendingPathComponent("python", isDirectory: true)
        let cache = runtime.appendingPathComponent("data", isDirectory: true)
        let helper = customization.appendingPathComponent("sitecustomize.py")
        XCTAssertEqual(environment["HOME"], "/keep-user-home")
        XCTAssertEqual(environment["THREADING_PYMOBILEDEVICE3_CACHE"], cache.path)
        XCTAssertEqual(environment["PYTHONPATH"], customization.path)
        XCTAssertEqual(environment["PYTHONNOUSERSITE"], "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        let helperSource = try String(contentsOf: helper, encoding: .utf8)
        XCTAssertTrue(helperSource.contains("pymobiledevice3.common._HOMEFOLDER"))
        XCTAssertEqual(try posixPermissions(at: runtime), 0o700)
        XCTAssertEqual(try posixPermissions(at: customization), 0o700)
        XCTAssertEqual(try posixPermissions(at: cache), 0o700)
        XCTAssertEqual(try posixPermissions(at: helper), 0o600)
    }
}

private extension Pymobiledevice3InstallationTests {
    func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    struct Fixture {
        let root: URL
        let python: URL

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Pymobiledevice3InstallationTests-\(UUID().uuidString)",
                isDirectory: true
            )
            root = directory
            python = directory.appendingPathComponent("python3")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try makeExecutable(at: python)
        }

        func installation(
            runner: InstallerRunner,
            identifier: String
        ) -> Pymobiledevice3Installation {
            let pythonExecutable = python
            return Pymobiledevice3Installation(
                root: root,
                pythonExecutable: { pythonExecutable },
                runner: runner,
                environment: ["PYTHONHOME": "/wrong", "PYTHONPATH": "/also-wrong"],
                makeIdentifier: { identifier }
            )
        }

        func candidate(_ identifier: String) -> URL {
            Pymobiledevice3ManagedTool.versionsDirectory(in: root)
                .appendingPathComponent("install-\(identifier)", isDirectory: true)
        }

        func makeInstalledEnvironment(at directory: URL) throws {
            try makeExecutable(
                at: directory.appendingPathComponent(
                    Pymobiledevice3ManagedTool.executableRelativePath
                )
            )
        }

        func makeExecutable(at url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    final class InstallerRunner: Pymobiledevice3InstallCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [Pymobiledevice3InstallCommand] = []
        private let version: String
        private let failingStep: Pymobiledevice3InstallStep?

        init(version: String, failingStep: Pymobiledevice3InstallStep? = nil) {
            self.version = version
            self.failingStep = failingStep
        }

        func run(_ command: Pymobiledevice3InstallCommand) throws -> BoundedChildResult {
            lock.lock()
            commands.append(command)
            lock.unlock()

            if command.step == failingStep {
                return BoundedChildResult(
                    output: Data("failed".utf8),
                    outputWasTruncated: false,
                    termination: .exited(1)
                )
            }

            switch command.step {
            case .createEnvironment:
                let candidate = URL(fileURLWithPath: try XCTUnwrap(command.arguments.last))
                try makeExecutable(at: candidate.appendingPathComponent("bin/python"))
            case .installPackage:
                let bin = command.executable.deletingLastPathComponent()
                try makeExecutable(at: bin.appendingPathComponent("pymobiledevice3"))
            case .validateVersion:
                return BoundedChildResult(
                    output: Data(version.utf8),
                    outputWasTruncated: false,
                    termination: .exited(0)
                )
            }

            return BoundedChildResult(
                output: Data(),
                outputWasTruncated: false,
                termination: .exited(0)
            )
        }

        func recordedCommands() -> [Pymobiledevice3InstallCommand] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }

        private func makeExecutable(at url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
    }
}
