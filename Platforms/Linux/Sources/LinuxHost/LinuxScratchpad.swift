import Foundation
@testable import CoreSlice
#if os(Linux)
import Glibc
#endif

/// The Linux host owns the scratchpad's durable identity. This is an explicit one-off command
/// running outside SDL's UI thread; it reads the project index once and writes only one row.
enum LinuxScratchpad {
    static func defaultFolderURL() throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/"),
              home != "/", home.utf8.count <= 4096 else {
            throw HostFailure.refused("an absolute HOME is required for Scratchpad")
        }
        return ScratchpadLocation.defaultFolderURL(home: URL(fileURLWithPath: home,
            isDirectory: true))
    }

    static func ensure(in database: ProjectDatabase, configuredPath: String? = nil) throws -> URL {
        let records = try database.projectRecords()
        let requested: URL
        if let record = records.first(where: { $0.project.isTheScratchpad }) {
            requested = URL(fileURLWithPath: record.project.folderPath, isDirectory: true)
        } else if let configured = ScratchpadLocation.configuredFolderURL(
            path: configuredPath ?? preferenceStore().string(forKey: ScratchpadDefaults.folderPathKey)) {
            requested = configured
        } else {
            requested = try defaultFolderURL()
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory) {
            try check(isDirectory.boolValue, "something that is not a folder is at Scratchpad")
        } else {
            try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        }
        let folder = ProjectDirectory.canonicalURL(requested)
        // The stored flag owns identity; a changed path must not turn an old scratchpad's
        // conversations into a second project. A manually added same-path row is adopted.
        if let record = records.first(where: { $0.project.isTheScratchpad }) {
            if record.project.folderPath != folder.path {
                try check(!records.contains(where: {
                    $0.project.id != record.project.id && $0.project.folderPath == folder.path
                }), "Scratchpad destination is already another project")
                var project = record.project
                project.folderPath = folder.path
                try database.saveProject(project, position: record.position)
            }
        } else if let record = records.first(where: { $0.project.folderPath == folder.path }) {
            var project = record.project
            project.isScratchpad = true
            try database.saveProject(project, position: record.position)
        } else {
            var project = Project(name: "Scratchpad", folderURL: folder)
            project.isScratchpad = true
            try database.addProject(project, position: records.count)
        }
        provisionRepository(at: folder)
        return folder
    }

    /// The host process updates the folder, database and WindowHarness preference together.
    /// Opening WindowHarness's domain explicitly avoids two executable-specific defaults
    /// domains disagreeing about where the user's notes live.
    static func relocate(in database: ProjectDatabase, from sourcePath: String,
                         to destinationPath: String) throws -> URL {
        let source = try checkedFolder(sourcePath)
        let target = try checkedFolder(destinationPath)
        let records = try database.projectRecords()
        let scratchpad = records.first(where: { $0.project.isTheScratchpad })
        if let scratchpad {
            try check(scratchpad.project.folderPath == source.path,
                      "Scratchpad changed while its folder was being moved")
        }
        try check(!records.contains(where: {
            $0.project.id != scratchpad?.project.id && $0.project.folderPath == target.path
        }), "Scratchpad destination is already another project")
        guard source != target else {
            try persistLocation(target)
            return target
        }

        var sourceIsDirectory: ObjCBool = false
        let sourceExists = FileManager.default.fileExists(atPath: source.path,
            isDirectory: &sourceIsDirectory)
        try check(!sourceExists || sourceIsDirectory.boolValue,
                  "something that is not a folder is at Scratchpad")
        try check(!FileManager.default.fileExists(atPath: target.path),
                  "Scratchpad destination already exists")
        if sourceExists {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
        }
        do {
            if let scratchpad {
                var project = scratchpad.project
                project.folderPath = target.path
                try database.saveProject(project, position: scratchpad.position)
            }
            try persistLocation(target)
        } catch {
            if let scratchpad { try? database.saveProject(scratchpad.project,
                position: scratchpad.position) }
            if sourceExists { try? FileManager.default.moveItem(at: target, to: source) }
            throw error
        }
        return target
    }

    /// `UserDefaults.standard` uses the executable name on Linux, so the database helper must
    /// open the window application's domain explicitly. A scenario suite keeps its isolation.
    private static func preferenceStore() -> UserDefaults {
        let environment = ProcessInfo.processInfo.environment
        let domain = PreferenceStore.scenarioSuiteName(environment: environment) ?? "WindowHarness"
        return UserDefaults(suiteName: domain)!
    }

    private static func persistLocation(_ folder: URL) throws {
        let preferences = preferenceStore()
        if folder == (try defaultFolderURL()) {
            preferences.removeObject(forKey: ScratchpadDefaults.folderPathKey)
        } else {
            preferences.set(folder.path, forKey: ScratchpadDefaults.folderPathKey)
        }
        try check(preferences.synchronize(), "Scratchpad location could not be saved")
    }

    private static func checkedFolder(_ path: String) throws -> URL {
        try check(path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096,
                  "Scratchpad path must be absolute and bounded")
        let folder = ScratchpadLocation.directoryURL(URL(fileURLWithPath: path,
            isDirectory: true))
        try check(folder.lastPathComponent == ScratchpadDefaults.folderName,
                  "Scratchpad path must end in Scratchpad")
        return folder
    }

    /// Git is best effort like the Mac path. Existing prose and repository history are owned
    /// by the user: seed files only when absent, and attempt the first commit only with no HEAD.
    private static func provisionRepository(at folder: URL) {
        let gitEntry = folder.appendingPathComponent(".git")
        if !FileManager.default.fileExists(atPath: gitEntry.path),
           !git(["init"], in: folder) { return }
        seed(ScratchpadDefaults.readmeName, in: folder,
             text: ScratchpadDefaults.readmeContents)
        seed(ScratchpadDefaults.gitignoreName, in: folder,
             text: ScratchpadDefaults.ignoredEntries.joined(separator: "\n") + "\n")
        guard !git(["rev-parse", "--verify", "HEAD"], in: folder) else { return }
        guard git(["add", "--", ScratchpadDefaults.readmeName,
                   ScratchpadDefaults.gitignoreName], in: folder) else { return }
        _ = git(["commit", "-m", "Create the scratchpad"], in: folder)
    }

    private static func seed(_ name: String, in folder: URL, text: String) {
        let file = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func git(_ arguments: [String], in folder: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { return false }
        // Git is optional for Scratchpad. User hooks in an already-present empty repository
        // must not hold the store lock or keep the GTK operation pending indefinitely.
        if finished.wait(timeout: .now() + 3) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                #if os(Linux)
                if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
                #endif
                _ = finished.wait(timeout: .now() + 1)
            }
            return false
        }
        return process.terminationStatus == 0
    }
}
