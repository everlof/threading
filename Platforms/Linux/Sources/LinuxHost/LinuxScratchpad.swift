import Foundation
@testable import CoreSlice
#if os(Linux)
import Glibc
#endif

/// The Linux host owns the scratchpad's durable identity. This is an explicit one-off command
/// running outside SDL's UI thread; it reads the project index once and writes only one row.
enum LinuxScratchpad {
    static func ensure(in database: ProjectDatabase) throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/"),
              home != "/", home.utf8.count <= 4096 else {
            throw HostFailure.refused("an absolute HOME is required for Scratchpad")
        }
        let requested = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Threading/Scratchpad", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory) {
            try check(isDirectory.boolValue, "something that is not a folder is at Scratchpad")
        } else {
            try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        }
        let folder = ProjectDirectory.canonicalURL(requested)
        let records = try database.projectRecords()
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

    /// Git is best effort like the Mac path. Existing prose and repository history are owned
    /// by the user: seed files only when absent, and attempt the first commit only with no HEAD.
    private static func provisionRepository(at folder: URL) {
        let gitEntry = folder.appendingPathComponent(".git")
        if !FileManager.default.fileExists(atPath: gitEntry.path),
           !git(["init"], in: folder) { return }
        seed("README.md", in: folder, text: "# Scratchpad\n\nThreading created this folder to hold chats that are not about any project. It is an ordinary git repository, so nothing you write here is lost — and nothing outside it belongs to Threading.\n")
        seed(".gitignore", in: folder, text: ".DS_Store\n")
        guard !git(["rev-parse", "--verify", "HEAD"], in: folder) else { return }
        guard git(["add", "--", "README.md", ".gitignore"], in: folder) else { return }
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
